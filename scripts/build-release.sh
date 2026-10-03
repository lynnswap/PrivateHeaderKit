#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-release.sh --version <version> [options]

  --output-dir <dir>      Stage binaries here (default: .build/distribution).
  --platform <platform>  Build macos, ios-simulator, watchos-simulator, or iphoneos only.
  --source-root <dir>    Source directory (default: this script's repo).
  --test                 Run macOS tests or compile platform test targets.

Builds all five executables by default. No Git checkout or installed runtime
is needed to build. The caller owns installation and version management.
USAGE
}

version=""
source_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir=""
platform="all"
run_tests=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="${2:?--version requires a value}"; shift 2 ;;
    --output-dir) output_dir="${2:?--output-dir requires a value}"; shift 2 ;;
    --source-root) source_root="${2:?--source-root requires a value}"; shift 2 ;;
    --platform) platform="${2:?--platform requires a value}"; shift 2 ;;
    --test) run_tests=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done
[[ -n "$version" ]] || { echo "--version is required." >&2; exit 1; }
case "$platform" in
  all|macos|ios-simulator|watchos-simulator|iphoneos) ;;
  *) echo "Unknown platform: $platform" >&2; exit 1 ;;
esac

cd "$source_root"
output_dir="${output_dir:-$PWD/.build/distribution}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
staging_dir="$(mktemp -d "$output_dir/.privateheaderkit.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
export PRIVATEHEADERKIT_BUILD_VERSION="$version"
# SwiftPM's plugin sandbox cannot nest inside Homebrew's build sandbox.
common=(-c release --disable-sandbox --force-resolved-versions)
toolchain_lib="$(dirname "$(dirname "$(xcrun --find swiftc)")")/lib"

stage() {
  local source="$1" name="$2" sdk="$3" library directory
  local runtime_dir="$staging_dir/privateheaderkit-runtime-$sdk"
  local library_sources=(--source-libraries "$toolchain_lib/swift/$sdk")
  install -m 755 "$source" "$staging_dir/$name"
  mkdir -p "$runtime_dir"
  # Compatibility libraries live in versioned Swift directories in the selected toolchain.
  for directory in "$toolchain_lib"/swift-*/"$sdk"; do
    [[ -d "$directory" ]] || continue
    library_sources+=(--source-libraries "$directory")
  done
  xcrun swift-stdlib-tool --copy --platform "$sdk" \
    "${library_sources[@]}" --scan-executable "$staging_dir/$name" --destination "$runtime_dir"
  for library in "$runtime_dir"/*.dylib; do
    [[ -f "$library" ]] || continue
    codesign --force --sign - "$library"
  done
  xcrun install_name_tool -add_rpath "@loader_path/privateheaderkit-runtime-$sdk" "$staging_dir/$name"
  local signing_arguments=(--force --sign -)
  if [[ "$sdk" == iphoneos ]]; then
    signing_arguments+=(--entitlements "$source_root/scripts/device-helper.entitlements")
  fi
  codesign "${signing_arguments[@]}" "$staging_dir/$name"
}

if [[ "$platform" == all || "$platform" == macos ]]; then
  host_arguments=("${common[@]}" --arch arm64)
  if [[ "$run_tests" == 1 ]]; then
    host_arguments+=(--build-system swiftbuild --sdk "$(xcrun --sdk macosx --show-sdk-path)")
    swift test "${host_arguments[@]}"
  else
    for product in privateheaderkit privateheaderkit-raw-helper; do
      swift build "${host_arguments[@]}" --product "$product"
    done
  fi
  host_bin="$(swift build "${host_arguments[@]}" --show-bin-path)"
  for product in privateheaderkit privateheaderkit-raw-helper; do
    stage "$host_bin/$product" "$product" macosx
  done
fi

for simulator in ios-simulator watchos-simulator iphoneos; do
  [[ "$platform" == all || "$platform" == "$simulator" ]] || continue
  product=privateheaderkit-sim-helper
  case "$simulator" in
    ios-simulator)
      sdk=iphonesimulator
      triple=arm64-apple-ios17.0-simulator
      name=privateheaderkit-sim-helper
      ;;
    iphoneos)
      sdk=iphoneos
      triple=arm64-apple-ios17.0
      name=privateheaderkit-device-helper
      product=privateheaderkit-device-helper
      ;;
    watchos-simulator)
      sdk=watchsimulator
      triple=arm64-apple-watchos10.0-simulator
      name=privateheaderkit-watch-sim-helper
      ;;
  esac
  arguments=("${common[@]}" --scratch-path "$PWD/.build/$simulator" \
    --sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" --triple "$triple")
  if [[ "$run_tests" == 1 ]]; then arguments+=(-Xswiftc -enable-testing); fi
  swift build "${arguments[@]}" --product "$product"
  if [[ "$run_tests" == 1 ]]; then
    swift build "${arguments[@]}" --target PrivateHeaderKitCoreTests
  fi
  simulator_bin="$(swift build "${arguments[@]}" --show-bin-path)"
  stage "$simulator_bin/$product" "$name" "$sdk"
done

if ! cp -Rp "$staging_dir/." "$output_dir/"; then
  echo "Could not publish all build products; $output_dir may contain partially replaced outputs." >&2
  exit 1
fi
