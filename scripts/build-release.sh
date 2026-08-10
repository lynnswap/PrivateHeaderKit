#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/build-release.sh --version <tag> --commit <sha> [--dist-root <dir>]

Builds and validates the macOS arm64 release cohort under:
  <dist-root>/arm64/bin/privateheaderkit-install
  <dist-root>/arm64/cohort/
EOF
}

version=""
commit=""
dist_root="dist"

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
commit="$(printf '%s' "$commit" | tr 'A-F' 'a-f')"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Release binaries must be built on macOS." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
stage_root="$dist_base/arm64"
expected_entries="$(printf '%s\n' \
  "bin" \
  "bin/privateheaderkit-install" \
  "cohort" \
  "cohort/privateheaderkit" \
  "cohort/privateheaderkit-raw-helper" \
  "cohort/privateheaderkit-sim-helper" \
  "cohort/release.json")"

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
  if [[ "$existing_entries" != "$expected_entries" \
     || ! -d "$stage_root/bin" || -L "$stage_root/bin" \
     || ! -d "$stage_root/cohort" || -L "$stage_root/cohort" ]]; then
    echo "Refusing to remove a release stage containing unknown entries: $stage_root" >&2
    exit 1
  fi
  local file
  for file in \
    "$stage_root/bin/privateheaderkit-install" \
    "$stage_root/cohort/privateheaderkit" \
    "$stage_root/cohort/privateheaderkit-raw-helper" \
    "$stage_root/cohort/privateheaderkit-sim-helper" \
    "$stage_root/cohort/release.json"
  do
    if [[ ! -f "$file" || -L "$file" ]]; then
      echo "Refusing to remove an unowned release-stage entry: $file" >&2
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
    pathspecs+=(
      ":(exclude)$dist_relative/arm64/**"
      ":(exclude)$dist_relative/.arm64.staging.*/**"
    )
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

validate_source_snapshot "before building"

for tool in swift xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required command: $tool" >&2
    exit 1
  fi
done
for tool in /usr/bin/codesign /usr/bin/lipo /usr/bin/vtool; do
  if [[ ! -x "$tool" ]]; then
    echo "Missing required command: $tool" >&2
    exit 1
  fi
done
validate_replaceable_stage

host_products=(
  "privateheaderkit"
  "privateheaderkit-install"
  "privateheaderkit-raw-helper"
)
simulator_product="privateheaderkit-sim-helper"
simulator_triple="arm64-apple-ios-simulator"
simulator_scratch_path="$repo_root/.build/privateheaderkit-simulator/$simulator_triple"

pushd "$repo_root" >/dev/null
for product in "${host_products[@]}"; do
  PRIVATEHEADERKIT_BUILD_VERSION="$version" \
  PRIVATEHEADERKIT_BUILD_COMMIT="$commit" \
    swift build -c release --arch arm64 --product "$product"
done

simulator_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PRIVATEHEADERKIT_BUILD_VERSION="$version" \
PRIVATEHEADERKIT_BUILD_COMMIT="$commit" \
  swift build -c release \
    --scratch-path "$simulator_scratch_path" \
    --sdk "$simulator_sdk" \
    --triple "$simulator_triple" \
    --product "$simulator_product"

host_bin="$(swift build -c release --arch arm64 --show-bin-path)"
simulator_bin="$(swift build -c release \
  --scratch-path "$simulator_scratch_path" \
  --sdk "$simulator_sdk" \
  --triple "$simulator_triple" \
  --show-bin-path)"
popd >/dev/null

validate_source_snapshot "after building"

for product in "${host_products[@]}"; do
  if [[ ! -f "$host_bin/$product" ]]; then
    echo "Built artifact is missing: $host_bin/$product" >&2
    exit 1
  fi
done
if [[ ! -f "$simulator_bin/$simulator_product" ]]; then
  echo "Built artifact is missing: $simulator_bin/$simulator_product" >&2
  exit 1
fi

stage_work="$(mktemp -d "$dist_base/.arm64.staging.XXXXXX")"
cleanup_stage() {
  if [[ -n "${stage_work:-}" ]]; then
    rm -rf "$stage_work"
  fi
}
trap cleanup_stage EXIT
stage_bin="$stage_work/bin"
stage_cohort="$stage_work/cohort"
mkdir -p "$stage_bin" "$stage_cohort"
cp "$host_bin/privateheaderkit-install" "$stage_bin/privateheaderkit-install"
cp "$host_bin/privateheaderkit" "$stage_cohort/privateheaderkit"
cp "$host_bin/privateheaderkit-raw-helper" "$stage_cohort/privateheaderkit-raw-helper"
cp "$simulator_bin/$simulator_product" "$stage_cohort/$simulator_product"
chmod 755 \
  "$stage_bin/privateheaderkit-install" \
  "$stage_cohort/privateheaderkit" \
  "$stage_cohort/privateheaderkit-raw-helper" \
  "$stage_cohort/privateheaderkit-sim-helper"

validate_binary() {
  local path="$1"
  local expected_platform="$2"
  local architectures
  local platforms

  /usr/bin/codesign --force --sign - "$path" >/dev/null
  /usr/bin/codesign --verify --strict "$path"

  architectures="$(/usr/bin/lipo -archs "$path")"
  if [[ "$architectures" != "arm64" ]]; then
    echo "Expected arm64 binary at $path, got: $architectures" >&2
    exit 1
  fi

  platforms="$(/usr/bin/vtool -show-build "$path" \
    | awk '$1 == "platform" { print $2 }' \
    | LC_ALL=C sort -u)"
  if [[ "$platforms" != "$expected_platform" ]]; then
    echo "Expected $expected_platform platform at $path, got: $platforms" >&2
    exit 1
  fi
}

validate_binary "$stage_bin/privateheaderkit-install" "MACOS"
validate_binary "$stage_cohort/privateheaderkit" "MACOS"
validate_binary "$stage_cohort/privateheaderkit-raw-helper" "MACOS"
validate_binary "$stage_cohort/privateheaderkit-sim-helper" "IOSSIMULATOR"

"$stage_bin/privateheaderkit-install" \
  --create-release-manifest \
  --artifact-dir "$stage_cohort" \
  --version "$version" \
  --commit "$commit" \
  --output "$stage_cohort/release.json"

actual_entries="$(cd "$stage_work" && find . -mindepth 1 -print \
  | sed 's|^[.]/||' \
  | LC_ALL=C sort)"
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "Staged release cohort is not exact." >&2
  printf 'Expected:\n%s\n' "$expected_entries" >&2
  printf 'Actual:\n%s\n' "$actual_entries" >&2
  exit 1
fi

for directory in "$stage_bin" "$stage_cohort"; do
  if [[ ! -d "$directory" || -L "$directory" ]]; then
    echo "Staged directory is not a real directory: $directory" >&2
    exit 1
  fi
done
for file in \
  "$stage_bin/privateheaderkit-install" \
  "$stage_cohort/privateheaderkit" \
  "$stage_cohort/privateheaderkit-raw-helper" \
  "$stage_cohort/privateheaderkit-sim-helper" \
  "$stage_cohort/release.json"
do
  if [[ ! -f "$file" || -L "$file" ]]; then
    echo "Staged entry is not a regular non-symlink file: $file" >&2
    exit 1
  fi
done

validate_replaceable_stage
if [[ -e "$stage_root" ]]; then
  rm -rf "$stage_root"
fi
mv "$stage_work" "$stage_root"
stage_work=""
trap - EXIT

echo "Staged PrivateHeaderKit $version release cohort at: $stage_root"
