#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-assets.sh --version <tag> --commit <sha> --repo <owner/repo> [--release-dir <dir>] [--archive-sha256 <sha256>] [--skip-install-smoke]
EOF
}

version=""
commit=""
release_repo=""
release_dir="release"
archive_sha256=""
skip_install_smoke=0

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
    --release-dir)
      release_dir="${2:-}"
      shift 2
      ;;
    --archive-sha256)
      archive_sha256="${2:-}"
      shift 2
      ;;
    --skip-install-smoke)
      skip_install_smoke=1
      shift
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
if [[ -n "$archive_sha256" && ! "$archive_sha256" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  echo "Archive SHA-256 must be a 64-character hex digest." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$release_dir" = /* ]]; then
  release_base="$release_dir"
else
  release_base="$repo_root/$release_dir"
fi
if [[ ! -d "$release_base" || -L "$release_base" ]]; then
  echo "Missing release directory: $release_base" >&2
  exit 1
fi

archive_asset="privateheaderkit-darwin-arm64.tar.gz"
installer_asset="install.sh"
checksum_asset="SHA256SUMS.txt"
expected_assets="$(printf '%s\n' \
  "$checksum_asset" \
  "$installer_asset" \
  "$archive_asset")"
actual_assets="$(find "$release_base" -mindepth 1 -maxdepth 1 -print \
  | sed 's|.*/||' \
  | LC_ALL=C sort)"
if [[ "$actual_assets" != "$expected_assets" ]]; then
  echo "Release asset set is not exact." >&2
  printf 'Expected:\n%s\n' "$expected_assets" >&2
  printf 'Actual:\n%s\n' "$actual_assets" >&2
  exit 1
fi
for asset in "$archive_asset" "$installer_asset" "$checksum_asset"; do
  if [[ ! -f "$release_base/$asset" || -L "$release_base/$asset" ]]; then
    echo "Release asset must be a regular non-symlink file: $asset" >&2
    exit 1
  fi
done

sha256_file() {
  local path="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{ print $1 }'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{ print $1 }'
  else
    echo "Neither shasum nor sha256sum is available." >&2
    return 1
  fi
}

temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
expected_checksum_file="$temporary_directory/SHA256SUMS.expected.txt"
printf '%s  %s\n' \
  "$(sha256_file "$release_base/$archive_asset")" \
  "$archive_asset" > "$expected_checksum_file"
printf '%s  %s\n' \
  "$(sha256_file "$release_base/$installer_asset")" \
  "$installer_asset" >> "$expected_checksum_file"
if ! cmp -s "$expected_checksum_file" "$release_base/$checksum_asset"; then
  echo "SHA256SUMS.txt does not exactly match the archive and installer." >&2
  diff -u "$expected_checksum_file" "$release_base/$checksum_asset" || true
  exit 1
fi

actual_archive_sha256="$(sha256_file "$release_base/$archive_asset")"
if [[ -n "$archive_sha256" ]]; then
  expected_archive_sha256="$(printf '%s' "$archive_sha256" | tr 'A-F' 'a-f')"
  if [[ "$actual_archive_sha256" != "$expected_archive_sha256" ]]; then
    echo "Archive SHA-256 does not match the trusted build output." >&2
    echo "Expected: $expected_archive_sha256" >&2
    echo "Actual:   $actual_archive_sha256" >&2
    exit 1
  fi
fi

sh -n "$release_base/$installer_asset"
"$repo_root/scripts/render-install-script.sh" \
  --version "$version" \
  --commit "$commit" \
  --repo "$release_repo" \
  --output "$temporary_directory/install.expected.sh"
if ! cmp -s "$temporary_directory/install.expected.sh" "$release_base/$installer_asset"; then
  echo "install.sh is not the version-baked installer for $version." >&2
  diff -u "$temporary_directory/install.expected.sh" "$release_base/$installer_asset" || true
  exit 1
fi

expected_entries="$(printf '%s\n' \
  "bin/privateheaderkit-install" \
  "cohort/privateheaderkit" \
  "cohort/privateheaderkit-raw-helper" \
  "cohort/privateheaderkit-sim-helper" \
  "cohort/release.json")"
actual_entries="$(tar -tzf "$release_base/$archive_asset" | LC_ALL=C sort)"
if [[ "$actual_entries" != "$expected_entries" ]]; then
  echo "Release archive path set is not exact." >&2
  printf 'Expected:\n%s\n' "$expected_entries" >&2
  printf 'Actual:\n%s\n' "$actual_entries" >&2
  exit 1
fi
if printf '%s\n' "$actual_entries" | grep -Eq '(^/|(^|/)[.][.](/|$))'; then
  echo "Release archive contains an unsafe path." >&2
  exit 1
fi
expected_entry_types="$(printf '%s\n' - - - - -)"
actual_entry_types="$(tar -tvzf "$release_base/$archive_asset" \
  | awk '{ print substr($1, 1, 1) }')"
if [[ "$actual_entry_types" != "$expected_entry_types" ]]; then
  echo "Release archive entries must all be regular files." >&2
  exit 1
fi

extract_root="$temporary_directory/extracted"
mkdir -p "$extract_root"
tar -C "$extract_root" -xzf "$release_base/$archive_asset"
for directory in "$extract_root/bin" "$extract_root/cohort"; do
  if [[ ! -d "$directory" || -L "$directory" ]]; then
    echo "Extracted path is not a real directory: $directory" >&2
    exit 1
  fi
done
for file in \
  "$extract_root/bin/privateheaderkit-install" \
  "$extract_root/cohort/privateheaderkit" \
  "$extract_root/cohort/privateheaderkit-raw-helper" \
  "$extract_root/cohort/privateheaderkit-sim-helper" \
  "$extract_root/cohort/release.json"
do
  if [[ ! -f "$file" || -L "$file" ]]; then
    echo "Extracted path is not a regular non-symlink file: $file" >&2
    exit 1
  fi
done

if [[ "$skip_install_smoke" -eq 1 ]]; then
  echo "Verified exact release assets (install smoke skipped)."
  exit 0
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Install smoke requires macOS; pass --skip-install-smoke only in the non-macOS draft gate." >&2
  exit 1
fi

expected_manifest="$temporary_directory/release.expected.json"
"$extract_root/bin/privateheaderkit-install" \
  --create-release-manifest \
  --artifact-dir "$extract_root/cohort" \
  --version "$version" \
  --commit "$commit" \
  --output "$expected_manifest"
if ! cmp -s "$expected_manifest" "$extract_root/cohort/release.json"; then
  echo "Archive release.json does not match version, commit, or artifact contents." >&2
  exit 1
fi

binding_prefix="$temporary_directory/binding-mismatch-prefix"
if "$extract_root/bin/privateheaderkit-install" \
  --release-dir "$extract_root/cohort" \
  --expected-version "v999999.0.0" \
  --expected-commit "$commit" \
  --prefix "$binding_prefix" >/dev/null 2>&1
then
  echo "Release cohort with a mismatched baked version was unexpectedly accepted." >&2
  exit 1
fi
if [[ -e "$binding_prefix/libexec/privateheaderkit/current" \
   || -L "$binding_prefix/libexec/privateheaderkit/current" ]]; then
  echo "Release binding mismatch changed the active pointer." >&2
  exit 1
fi
wrong_commit="0000000000000000000000000000000000000000"
if [[ "$wrong_commit" == "$commit" ]]; then
  wrong_commit="1111111111111111111111111111111111111111"
fi
commit_binding_prefix="$temporary_directory/commit-binding-mismatch-prefix"
if "$extract_root/bin/privateheaderkit-install" \
  --release-dir "$extract_root/cohort" \
  --expected-version "$version" \
  --expected-commit "$wrong_commit" \
  --prefix "$commit_binding_prefix" >/dev/null 2>&1
then
  echo "Release cohort with a mismatched baked commit was unexpectedly accepted." >&2
  exit 1
fi
if [[ -e "$commit_binding_prefix/libexec/privateheaderkit/current" \
   || -L "$commit_binding_prefix/libexec/privateheaderkit/current" ]]; then
  echo "Release commit binding mismatch changed the active pointer." >&2
  exit 1
fi

cohort_identifier="$(sed -n \
  's/^[[:space:]]*"cohort"[[:space:]]*:[[:space:]]*"\([^"]*\)"[,]*[[:space:]]*$/\1/p' \
  "$extract_root/cohort/release.json")"
if [[ ! "$cohort_identifier" =~ ^v[0-9]+[.][0-9]+[.][0-9A-Za-z.+_-]*[+][0-9a-f]{64}$ ]]; then
  echo "release.json has an invalid content cohort identifier: $cohort_identifier" >&2
  exit 1
fi

smoke_prefix="$temporary_directory/smoke-prefix"
PRIVATEHEADERKIT_BASE_URL="file://$release_base" \
PREFIX="$smoke_prefix" \
  "$release_base/install.sh"

expected_current="versions/$cohort_identifier"
actual_current="$(readlink "$smoke_prefix/libexec/privateheaderkit/current")"
if [[ "$actual_current" != "$expected_current" ]]; then
  echo "Smoke install current pointer mismatch: $actual_current" >&2
  exit 1
fi
actual_public="$(readlink "$smoke_prefix/bin/privateheaderkit")"
if [[ "$actual_public" != "../libexec/privateheaderkit/current/privateheaderkit" ]]; then
  echo "Smoke install public pointer mismatch: $actual_public" >&2
  exit 1
fi
installed_cohort="$smoke_prefix/libexec/privateheaderkit/versions/$cohort_identifier"
expected_cohort_entries="$(printf '%s\n' \
  "privateheaderkit" \
  "privateheaderkit-raw-helper" \
  "privateheaderkit-sim-helper" \
  "release.json")"
actual_cohort_entries="$(find "$installed_cohort" -mindepth 1 -maxdepth 1 -print \
  | sed 's|.*/||' \
  | LC_ALL=C sort)"
if [[ "$actual_cohort_entries" != "$expected_cohort_entries" ]]; then
  echo "Smoke install cohort is not exact." >&2
  exit 1
fi
if ! cmp -s "$extract_root/cohort/release.json" "$installed_cohort/release.json"; then
  echo "Smoke install manifest changed during installation." >&2
  exit 1
fi

tamper_root="$temporary_directory/tampered"
mkdir -p "$tamper_root"
tar -C "$tamper_root" -xzf "$release_base/$archive_asset"
printf 'tamper' >> "$tamper_root/cohort/privateheaderkit-raw-helper"
tamper_prefix="$temporary_directory/tamper-prefix"
if "$tamper_root/bin/privateheaderkit-install" \
  --release-dir "$tamper_root/cohort" \
  --expected-version "$version" \
  --expected-commit "$commit" \
  --prefix "$tamper_prefix" >/dev/null 2>&1
then
  echo "Tampered release cohort was unexpectedly accepted." >&2
  exit 1
fi
if [[ -e "$tamper_prefix/libexec/privateheaderkit/current" \
   || -L "$tamper_prefix/libexec/privateheaderkit/current" ]]; then
  echo "Tampered release cohort changed the active pointer." >&2
  exit 1
fi

echo "Verified release assets, temp-prefix install, and tamper rejection."
