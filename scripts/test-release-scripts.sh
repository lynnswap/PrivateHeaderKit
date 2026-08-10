#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

fail() {
  echo "test-release-scripts: $*" >&2
  exit 1
}

expect_failure() {
  local expected_message="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "expected command to fail: $*"
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    fail "failure output did not contain '$expected_message': $output"
  fi
}

assert_file_set() {
  local directory="$1"
  local expected
  local actual
  expected="$(printf '%s\n' SHA256SUMS.txt install.sh privateheaderkit-darwin-arm64.tar.gz | LC_ALL=C sort)"
  actual="$(find "$directory" -mindepth 1 -maxdepth 1 -print | sed 's|.*/||' | LC_ALL=C sort)"
  [[ "$actual" == "$expected" ]] || fail "unexpected release assets in $directory: $actual"
}

assert_prerelease_classification() {
  local tag="$1"
  local expected="$2"
  local actual
  actual="$("$repo_root/scripts/release-version-is-prerelease.sh" "$tag")"
  [[ "$actual" == "$expected" ]] || fail "expected $tag to classify as $expected, got $actual"
}

assert_prerelease_classification "v1.2.3" false
assert_prerelease_classification "v1.2.3-rc.1" true
assert_prerelease_classification "v1.2.3.4" true
expect_failure "Release tag must look like v1.2.3." \
  "$repo_root/scripts/release-version-is-prerelease.sh" "v1.2"

installer="$temporary_directory/install.sh"
"$repo_root/scripts/render-install-script.sh" \
  --version v1.2.3 \
  --commit 0000000000000000000000000000000000000000 \
  --repo lynnswap/PrivateHeaderKit \
  --output "$installer"
stub_bin="$temporary_directory/stubs"
mkdir -p "$stub_bin"
cat > "$stub_bin/uname" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-m" ]; then
  printf 'arm64\n'
else
  printf 'Darwin\n'
fi
EOF
cat > "$stub_bin/sw_vers" <<'EOF'
#!/bin/sh
printf '13.6.3\n'
EOF
chmod 755 "$stub_bin/uname" "$stub_bin/sw_vers"
expect_failure "require macOS 14 or newer" \
  env PATH="$stub_bin:/usr/bin:/bin" sh "$installer"

build_fixture="$temporary_directory/build-fixture"
mkdir -p "$build_fixture/scripts"
cp "$repo_root/scripts/build-release.sh" "$build_fixture/scripts/build-release.sh"
git -C "$build_fixture" init --quiet
git -C "$build_fixture" config user.email tests@example.invalid
git -C "$build_fixture" config user.name release-script-tests
git -C "$build_fixture" add scripts/build-release.sh
git -C "$build_fixture" commit --quiet -m fixture
fixture_commit="$(git -C "$build_fixture" rev-parse HEAD)"
printf 'untracked source\n' > "$build_fixture/dirty-source"
expect_failure "Release source must be clean before building." \
  "$build_fixture/scripts/build-release.sh" \
  --version v1.2.3 \
  --commit "$fixture_commit" \
  --dist-root "$temporary_directory/build-dist"

package_fixture="$temporary_directory/package-fixture"
mkdir -p "$package_fixture/scripts" "$package_fixture/dist/arm64/bin" "$package_fixture/dist/arm64/cohort"
cp "$repo_root/scripts/package-release.sh" "$package_fixture/scripts/package-release.sh"
cp "$repo_root/scripts/render-install-script.sh" "$package_fixture/scripts/render-install-script.sh"
cp "$repo_root/scripts/install-release.sh.in" "$package_fixture/scripts/install-release.sh.in"
for file in privateheaderkit privateheaderkit-raw-helper privateheaderkit-sim-helper; do
  printf '%s\n' "$file" > "$package_fixture/dist/arm64/cohort/$file"
done
printf '{}\n' > "$package_fixture/dist/arm64/cohort/release.json"
cat > "$package_fixture/dist/arm64/bin/privateheaderkit-install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
cp "$(dirname "$0")/../cohort/release.json" "$output"
EOF
chmod 755 "$package_fixture/dist/arm64/bin/privateheaderkit-install"
mkdir -p "$package_fixture/release"
printf 'partial asset\n' > "$package_fixture/release/install.sh"
"$package_fixture/scripts/package-release.sh" \
  --version v1.2.3 \
  --commit 0000000000000000000000000000000000000000 \
  --repo lynnswap/PrivateHeaderKit \
  --dist-root dist \
  --output-dir release
assert_file_set "$package_fixture/release"
if find "$package_fixture" -maxdepth 1 \( -name '.release.staging.*' -o -name '.release.backup.*' \) -print -quit | grep -q .; then
  fail "package retry left a staging or backup directory"
fi
printf 'unknown asset\n' > "$package_fixture/release/unknown.txt"
expect_failure "Unknown entry: unknown.txt" \
  "$package_fixture/scripts/package-release.sh" \
  --version v1.2.3 \
  --commit 0000000000000000000000000000000000000000 \
  --repo lynnswap/PrivateHeaderKit \
  --dist-root dist \
  --output-dir release

echo "release script tests passed"
