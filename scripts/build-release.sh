#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/build-release.sh --version <version> [options]

  --output-dir <dir>      Stage binaries here (default: .build/distribution).
  --platform <platform>  Build macos, ios-simulator, or watchos-simulator only.
  --source-root <dir>    Source directory (default: this script's repo).
  --test                 Run macOS tests or compile Simulator test targets.

Builds all four executables by default. No Git checkout or installed runtime
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
  all|macos|ios-simulator|watchos-simulator) ;;
  *) echo "Unknown platform: $platform" >&2; exit 1 ;;
esac

cd "$source_root"
output_dir="${output_dir:-$PWD/.build/distribution}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
export PRIVATEHEADERKIT_BUILD_VERSION="$version"
# SwiftPM's plugin sandbox cannot nest inside Homebrew's build sandbox.
common=(-c release --disable-sandbox --force-resolved-versions)

stage() {
  local source="$1" name="$2"
  install -m 755 "$source" "$output_dir/$name"
  codesign --force --sign - "$output_dir/$name"
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
    stage "$host_bin/$product" "$product"
  done
fi

for simulator in ios-simulator watchos-simulator; do
  [[ "$platform" == all || "$platform" == "$simulator" ]] || continue
  case "$simulator" in
    ios-simulator)
      sdk=iphonesimulator
      triple=arm64-apple-ios17.0-simulator
      name=privateheaderkit-sim-helper
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
  swift build "${arguments[@]}" --product privateheaderkit-sim-helper
  if [[ "$run_tests" == 1 ]]; then
    swift build "${arguments[@]}" --target PrivateHeaderKitCoreTests
  fi
  simulator_bin="$(swift build "${arguments[@]}" --show-bin-path)"
  stage "$simulator_bin/privateheaderkit-sim-helper" "$name"
done
