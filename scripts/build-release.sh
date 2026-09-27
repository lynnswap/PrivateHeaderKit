#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> --commit <sha> [options]

Options:
  --dist-root <dir>        Output directory (default: dist).
  --platform <platform>    Build macos, ios-simulator, or watchos-simulator only.
  --artifacts-root <dir>   Assemble previously built platform directories.
  --test                   Build test targets and run macOS tests before staging.
  --source-root <dir>      Source checkout to build (default: this script's repo).

With no platform or artifacts root, builds all platforms locally.
Platform builds stage binaries under <dist-root>/<platform>/.
Assembly signs and validates the complete cohort under <dist-root>/arm64/,
then generates release.json. --platform and --artifacts-root are exclusive.
EOF
}

version=""
commit=""
dist_root="dist"
platform="all"
artifacts_root=""
run_tests=0
source_root=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      version="${2:-}"
      shift 2
      ;;
    --commit)
      commit="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --platform)
      platform="${2:-}"
      shift 2
      ;;
    --artifacts-root)
      artifacts_root="${2:-}"
      shift 2
      ;;
    --test)
      run_tests=1
      shift
      ;;
    --source-root)
      source_root="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi
if [[ ! "$commit" =~ ^[0-9A-Fa-f]{40}$ ]]; then
  echo "Release commit must be a full 40-character Git SHA." >&2
  exit 1
fi
case "$platform" in
  all|macos|ios-simulator|watchos-simulator) ;;
  *)
    echo "Unknown release platform: $platform" >&2
    exit 1
    ;;
esac
if [[ "$platform" != "all" && -n "$artifacts_root" ]]; then
  echo "--platform and --artifacts-root cannot be combined." >&2
  exit 1
fi
if [[ "$run_tests" == 1 && -n "$artifacts_root" ]]; then
  echo "--test belongs to the platform build; assembly does not rebuild test targets." >&2
  exit 1
fi
commit="$(printf '%s' "$commit" | tr 'A-F' 'a-f')"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release binaries must be built on macOS." >&2
  exit 1
fi

if [[ -z "$source_root" ]]; then
  source_root="$(dirname "${BASH_SOURCE[0]}")/.."
fi
repo_root="$(cd "$source_root" && pwd -P)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
mkdir -p "$dist_base"
dist_base="$(cd "$dist_base" && pwd -P)"
if [[ "$dist_base" == "$repo_root" ]]; then
  echo "Release dist root must not be the repository root." >&2
  exit 1
fi
stage_name="$platform"
if [[ "$platform" == "all" ]]; then
  stage_name="arm64"
fi
stage_root="$dist_base/$stage_name"
stage_files=()
stage_directories=("cohort")
if [[ "$platform" == "all" || "$platform" == "macos" ]]; then
  stage_directories+=("bin")
  stage_files+=(
    "bin/privateheaderkit-install"
    "cohort/privateheaderkit"
    "cohort/privateheaderkit-raw-helper"
  )
fi
if [[ "$platform" == "all" || "$platform" == "ios-simulator" ]]; then
  stage_files+=("cohort/privateheaderkit-sim-helper")
fi
if [[ "$platform" == "all" || "$platform" == "watchos-simulator" ]]; then
  stage_files+=("cohort/privateheaderkit-watch-sim-helper")
fi
if [[ "$platform" == "all" ]]; then
  stage_files+=("cohort/release.json")
else
  stage_files+=("build-info.txt")
fi
expected_entries="$(printf '%s\n' "${stage_directories[@]}" "${stage_files[@]}" | LC_ALL=C sort)"

validate_replaceable_stage() {
  if [[ ! -e "$stage_root" && ! -L "$stage_root" ]]; then
    return
  fi
  if [[ ! -d "$stage_root" || -L "$stage_root" ]]; then
    echo "Refusing to replace a non-directory release stage: $stage_root" >&2
    exit 1
  fi
  local existing_entries
  existing_entries="$(cd "$stage_root" && find . -mindepth 1 -print \
    | sed 's|^[.]/||' \
    | LC_ALL=C sort)"
  if [[ "$existing_entries" != "$expected_entries" ]]; then
    echo "Refusing to remove a release stage containing unknown entries: $stage_root" >&2
    exit 1
  fi
  local directory
  for directory in "${stage_directories[@]}"; do
    if [[ ! -d "$stage_root/$directory" || -L "$stage_root/$directory" ]]; then
      echo "Refusing to replace an unowned release-stage directory: $stage_root/$directory" >&2
      exit 1
    fi
  done
  local file
  for file in "${stage_files[@]}"; do
    if [[ ! -f "$stage_root/$file" || -L "$stage_root/$file" ]]; then
      echo "Refusing to remove an unowned release-stage entry: $stage_root/$file" >&2
      exit 1
    fi
  done
}

source_changes() {
  local pathspecs=(
    "."
    ":(exclude).build/**"
  )
  if [[ "$dist_base/" == "$repo_root/"* ]]; then
    local dist_relative="${dist_base#"$repo_root/"}"
    local output_name
    for output_name in arm64 macos ios-simulator watchos-simulator; do
      pathspecs+=(
        ":(exclude)$dist_relative/$output_name/**"
        ":(exclude)$dist_relative/.$output_name.staging.*/**"
      )
    done
  fi
  git -C "$repo_root" status --porcelain=v1 --untracked-files=all -- "${pathspecs[@]}"
}

validate_source_snapshot() {
  local phase="$1"
  local actual_head
  local changes
  actual_head="$(git -C "$repo_root" rev-parse HEAD)"
  if [[ "$actual_head" != "$commit" ]]; then
    echo "Release source HEAD changed $phase." >&2
    echo "Expected: $commit" >&2
    echo "Actual:   $actual_head" >&2
    exit 1
  fi
  changes="$(source_changes)"
  if [[ -n "$changes" ]]; then
    echo "Release source must be clean $phase." >&2
    printf '%s\n' "$changes" >&2
    exit 1
  fi
}

validate_replaceable_stage

source_files=()
if [[ -n "$artifacts_root" ]]; then
  if [[ "$artifacts_root" != /* ]]; then
    artifacts_root="$repo_root/$artifacts_root"
  fi
  for build_platform in macos ios-simulator watchos-simulator; do
    read -r artifact_version artifact_commit < "$artifacts_root/$build_platform/build-info.txt"
    if [[ "$artifact_version" != "$version" || "$artifact_commit" != "$commit" ]]; then
      echo "Release build identity mismatch for $build_platform: expected $version ($commit), got $artifact_version ($artifact_commit)." >&2
      exit 1
    fi
  done
  source_files=(
    "$artifacts_root/macos/bin/privateheaderkit-install"
    "$artifacts_root/macos/cohort/privateheaderkit"
    "$artifacts_root/macos/cohort/privateheaderkit-raw-helper"
    "$artifacts_root/ios-simulator/cohort/privateheaderkit-sim-helper"
    "$artifacts_root/watchos-simulator/cohort/privateheaderkit-watch-sim-helper"
  )
else
  validate_source_snapshot "before building"
  export PRIVATEHEADERKIT_BUILD_VERSION="$version"
  export PRIVATEHEADERKIT_BUILD_COMMIT="$commit"
  pushd "$repo_root" >/dev/null
  if [[ "$platform" == "all" || "$platform" == "macos" ]]; then
    host_arguments=(-c release --arch arm64)
    if [[ "$run_tests" == 1 ]]; then
      # Swift Build keeps async executable entry points separate in optimized test bundles.
      host_arguments+=(--build-system swiftbuild --sdk "$(xcrun --sdk macosx --show-sdk-path)")
      swift test "${host_arguments[@]}"
    else
      for product in privateheaderkit privateheaderkit-install privateheaderkit-raw-helper; do
        swift build "${host_arguments[@]}" --product "$product"
      done
    fi
    host_bin="$(swift build "${host_arguments[@]}" --show-bin-path)"
    source_files+=(
      "$host_bin/privateheaderkit-install"
      "$host_bin/privateheaderkit"
      "$host_bin/privateheaderkit-raw-helper"
    )
  fi
  for simulator in ios-simulator watchos-simulator; do
    if [[ "$platform" != "all" && "$platform" != "$simulator" ]]; then
      continue
    fi
    case "$simulator" in
      ios-simulator)
        simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
        simulator_triple="arm64-apple-ios-simulator"
        ;;
      watchos-simulator)
        simulator_sdk="$(xcrun --sdk watchsimulator --show-sdk-path)"
        simulator_triple="arm64-apple-watchos-simulator"
        ;;
    esac
    simulator_arguments=(
      -c release
      --scratch-path "$repo_root/.build/privateheaderkit-simulator/$simulator_triple"
      --sdk "$simulator_sdk"
      --triple "$simulator_triple"
    )
    if [[ "$run_tests" == 1 ]]; then
      simulator_arguments+=(-Xswiftc -enable-testing)
    fi
    swift build "${simulator_arguments[@]}" --product privateheaderkit-sim-helper
    if [[ "$run_tests" == 1 ]]; then
      swift build "${simulator_arguments[@]}" --target PrivateHeaderKitCoreTests
    fi
    simulator_bin="$(swift build "${simulator_arguments[@]}" --show-bin-path)"
    source_files+=("$simulator_bin/privateheaderkit-sim-helper")
  done
  popd >/dev/null
  validate_source_snapshot "after building"
fi

stage_work="$(mktemp -d "$dist_base/.$stage_name.staging.XXXXXX")"
cleanup_stage() {
  if [[ -n "${stage_work:-}" ]]; then
    rm -rf "$stage_work"
  fi
}
trap cleanup_stage EXIT
for directory in "${stage_directories[@]}"; do
  mkdir -p "$stage_work/$directory"
done
for index in "${!source_files[@]}"; do
  destination="$stage_work/${stage_files[$index]}"
  cp "${source_files[$index]}" "$destination"
  chmod 755 "$destination"
done

validate_binary() {
  local path="$1"
  local expected_platform="$2"
  local architectures
  local platforms

  codesign --force --sign - "$path" >/dev/null
  codesign --verify --strict "$path"

  architectures="$(lipo -archs "$path")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Expected arm64 binary at $path, got: $architectures" >&2
    exit 1
  fi

  platforms="$(vtool -show-build "$path" \
    | awk '$1 == "platform" { print $2 }' \
    | LC_ALL=C sort -u)"
  if [[ "$platforms" != "$expected_platform" ]]; then
    echo "Expected $expected_platform platform at $path, got: $platforms" >&2
    exit 1
  fi
}

if [[ "$platform" == "all" ]]; then
  validate_binary "$stage_work/bin/privateheaderkit-install" "MACOS"
  validate_binary "$stage_work/cohort/privateheaderkit" "MACOS"
  validate_binary "$stage_work/cohort/privateheaderkit-raw-helper" "MACOS"
  validate_binary "$stage_work/cohort/privateheaderkit-sim-helper" "IOSSIMULATOR"
  validate_binary "$stage_work/cohort/privateheaderkit-watch-sim-helper" "WATCHOSSIMULATOR"

  "$stage_work/bin/privateheaderkit-install" \
    --create-release-manifest \
    --artifact-dir "$stage_work/cohort" \
    --version "$version" \
    --commit "$commit" \
    --output "$stage_work/cohort/release.json"
else
  printf '%s %s\n' "$version" "$commit" > "$stage_work/build-info.txt"
fi

actual_entries="$(cd "$stage_work" && find . -mindepth 1 -print \
  | sed 's|^[.]/||' \
  | LC_ALL=C sort)"
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "Staged release cohort is not exact." >&2
  printf 'Expected:\n%s\n' "$expected_entries" >&2
  printf 'Actual:\n%s\n' "$actual_entries" >&2
  exit 1
fi

validate_replaceable_stage
if [[ -e "$stage_root" ]]; then
  rm -rf "$stage_root"
fi
mv "$stage_work" "$stage_root"
stage_work=""
trap - EXIT

echo "Staged PrivateHeaderKit $version ($platform) at: $stage_root"
