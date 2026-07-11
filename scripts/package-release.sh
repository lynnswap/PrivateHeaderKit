#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/package-release.sh --version <tag> --commit <sha> [--repo <owner/repo>] [--dist-root <dir>] [--output-dir <dir>]

Consumes the exact staged cohort from scripts/build-release.sh and creates:
  privateheaderkit-darwin-arm64.tar.gz
  install.sh
  SHA256SUMS.txt
EOF
}

version=""
commit=""
release_repo="lynnswap/PrivateHeaderKit"
dist_root="dist"
output_dir="release"

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
    --repo)
      release_repo="${2:-}"
      shift 2
      ;;
    --dist-root)
      dist_root="${2:-}"
      shift 2
      ;;
    --output-dir)
      output_dir="${2:-}"
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
if [[ ! "$release_repo" =~ ^[0-9A-Za-z_.-]+/[0-9A-Za-z_.-]+$ ]]; then
  echo "Release repo must look like owner/repo." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$dist_root" = /* ]]; then
  dist_base="$dist_root"
else
  dist_base="$repo_root/$dist_root"
fi
if [[ "$output_dir" = /* ]]; then
  output_base="$output_dir"
else
  output_base="$repo_root/$output_dir"
fi
stage_root="$dist_base/arm64"

expected_stage_entries="$(printf '%s\n' \
  "bin" \
  "bin/privateheaderkit-install" \
  "cohort" \
  "cohort/privateheaderkit" \
  "cohort/privateheaderkit-raw-helper" \
  "cohort/privateheaderkit-sim-helper" \
  "cohort/release.json")"
if [[ ! -d "$stage_root" || -L "$stage_root" ]]; then
  echo "Missing staged release cohort: $stage_root" >&2
  exit 1
fi
actual_stage_entries="$(cd "$stage_root" && find . -mindepth 1 -print \
  | sed 's|^[.]/||' \
  | LC_ALL=C sort)"
if [[ "$actual_stage_entries" != "$expected_stage_entries" ]]; then
  echo "Staged release cohort is not exact." >&2
  printf 'Expected:\n%s\n' "$expected_stage_entries" >&2
  printf 'Actual:\n%s\n' "$actual_stage_entries" >&2
  exit 1
fi
for directory in "$stage_root/bin" "$stage_root/cohort"; do
  if [[ ! -d "$directory" || -L "$directory" ]]; then
    echo "Staged path must be a real directory: $directory" >&2
    exit 1
  fi
done
for file in \
  "$stage_root/bin/privateheaderkit-install" \
  "$stage_root/cohort/privateheaderkit" \
  "$stage_root/cohort/privateheaderkit-raw-helper" \
  "$stage_root/cohort/privateheaderkit-sim-helper" \
  "$stage_root/cohort/release.json"
do
  if [[ ! -f "$file" || -L "$file" ]]; then
    echo "Staged path must be a regular non-symlink file: $file" >&2
    exit 1
  fi
done
if [[ ! -x "$stage_root/bin/privateheaderkit-install" ]]; then
  echo "Staged release installer is not executable." >&2
  exit 1
fi

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
"$stage_root/bin/privateheaderkit-install" \
  --create-release-manifest \
  --artifact-dir "$stage_root/cohort" \
  --version "$version" \
  --commit "$commit" \
  --output "$temporary_directory/release.json"
if ! cmp -s "$temporary_directory/release.json" "$stage_root/cohort/release.json"; then
  echo "Staged release.json does not match version, commit, or artifact contents." >&2
  exit 1
fi

if [[ -e "$output_base" || -L "$output_base" ]]; then
  if [[ ! -d "$output_base" || -L "$output_base" ]]; then
    echo "Release output must be a real directory: $output_base" >&2
    exit 1
  fi
else
  mkdir -p "$output_base"
fi
expected_assets="$(printf '%s\n' \
  "SHA256SUMS.txt" \
  "install.sh" \
  "privateheaderkit-darwin-arm64.tar.gz")"
existing_assets="$(find "$output_base" -mindepth 1 -maxdepth 1 -print \
  | sed 's|.*/||' \
  | LC_ALL=C sort)"
if [[ -n "$existing_assets" && "$existing_assets" != "$expected_assets" ]]; then
  echo "Refusing to replace an output directory containing unknown entries: $output_base" >&2
  printf 'Actual:\n%s\n' "$existing_assets" >&2
  exit 1
fi
if [[ -n "$existing_assets" ]]; then
  for asset in \
    "$output_base/SHA256SUMS.txt" \
    "$output_base/install.sh" \
    "$output_base/privateheaderkit-darwin-arm64.tar.gz"
  do
    if [[ ! -f "$asset" || -L "$asset" ]]; then
      echo "Refusing to replace an unowned release asset: $asset" >&2
      exit 1
    fi
  done
fi

archive="$output_base/privateheaderkit-darwin-arm64.tar.gz"
install_script="$output_base/install.sh"
checksum_file="$output_base/SHA256SUMS.txt"
rm -f "$archive" "$install_script" "$checksum_file"

COPYFILE_DISABLE=1 tar -C "$stage_root" -czf "$archive" \
  "bin/privateheaderkit-install" \
  "cohort/privateheaderkit" \
  "cohort/privateheaderkit-raw-helper" \
  "cohort/privateheaderkit-sim-helper" \
  "cohort/release.json"

"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --commit "$commit" \
  --repo "$release_repo" \
  --output "$install_script"

(
  cd "$output_base"
  shasum -a 256 \
    "privateheaderkit-darwin-arm64.tar.gz" \
    "install.sh" > "SHA256SUMS.txt"
)

actual_assets="$(find "$output_base" -mindepth 1 -maxdepth 1 -print \
  | sed 's|.*/||' \
  | LC_ALL=C sort)"
if [[ "$actual_assets" != "$expected_assets" ]]; then
  echo "Release asset set is not exact." >&2
  exit 1
fi

echo "Created exact release assets at: $output_base"
