#!/usr/bin/env bash
set -euo pipefail

# Run on an otherwise clean Homebrew installation; never replace a user's keg.
release_dir="${1:?Usage: scripts/test-homebrew.sh <release-dir> [--simulators]}"
release_dir="$(cd "$release_dir" && pwd)"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
formula=privateheaderkit/verification/privateheaderkit
if brew list --formula --versions privateheaderkit >/dev/null 2>&1; then
  echo "Uninstall the existing Homebrew privateheaderkit before running this test." >&2
  exit 1
fi
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_AUTOREMOVE=1
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
brew tap-new --no-git privateheaderkit/verification
cleanup() {
  local result=$?
  trap - EXIT
  if brew list --formula --versions privateheaderkit >/dev/null 2>&1; then
    brew uninstall --force "$formula" || result=1
  fi
  brew untap privateheaderkit/verification || result=1
  brew untrust --formula "$formula" || result=1
  if [[ "$result" == 0 ]]; then
    rm -rf "$work"
  else
    echo "Verification artifacts retained at: $work" >&2
  fi
  exit "$result"
}
trap cleanup EXIT
cp "$release_dir/privateheaderkit.rb" "$(brew --repository privateheaderkit/verification)/Formula/privateheaderkit.rb"
brew trust --formula "$formula"
# The approved draft is not public yet. Homebrew still validates this cached
# source against the same checksum and URL that the published Formula will use.
cache="$(brew --cache --build-from-source "$formula")"
mkdir -p "$(dirname "$cache")"
source_archive="$(awk '$2 ~ /^privateheaderkit-.*\.tar\.gz$/ { print $2 }' "$release_dir/SHA256SUMS.txt")"
cp "$release_dir/$source_archive" "$cache"
brew install --build-bottle "$formula"
brew test "$formula"
cd "$work"
brew bottle --json --root-url=https://example.invalid/privateheaderkit-verification "$formula"
brew bottle --merge --write --no-commit "$work"/*.bottle.json
bottle_cache="$(brew --cache --force-bottle "$formula")"
cp "$work"/*.bottle.tar.gz "$bottle_cache"
brew uninstall "$formula"
brew install --force-bottle "$formula"
brew info --json=v2 "$formula" | python3 -c '
import json, sys
installed = json.load(sys.stdin)["formulae"][0]["installed"][0]
if not installed["poured_from_bottle"]:
    sys.exit("Homebrew verification expected a bottle installation.")
'
brew test "$formula"
if [[ "${2:-}" == --simulators ]]; then
  python3 "$repo_root/scripts/smoke_release_binaries.py" \
    --cohort-dir "$(brew --prefix "$formula")/libexec"
fi
