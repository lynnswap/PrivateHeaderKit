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
export HOMEBREW_NO_AUTO_UPDATE=1
brew tap-new --no-git privateheaderkit/verification
work="$(mktemp -d)"
cleanup() {
  local result=$?
  trap - EXIT
  if brew list --formula --versions privateheaderkit >/dev/null 2>&1; then
    brew uninstall --force "$formula" || result=1
  fi
  brew untap privateheaderkit/verification || result=1
  rm -rf "$work"
  exit "$result"
}
trap cleanup EXIT
cp "$release_dir/privateheaderkit.rb" "$(brew --repository privateheaderkit/verification)/Formula/privateheaderkit.rb"
brew trust --formula "$formula"
# The approved draft is not public yet. Homebrew still validates this cached
# source against the same checksum and URL that the published Formula will use.
cache="$(brew --cache --build-from-source "$formula")"
mkdir -p "$(dirname "$cache")"
cp "$release_dir"/privateheaderkit-*.tar.gz "$cache"
brew install --build-bottle "$formula"
brew test "$formula"
cd "$work"
brew bottle --json "$formula"
brew uninstall "$formula"
brew install "$work"/*.bottle.tar.gz
brew test "$formula"
if [[ "${2:-}" == --simulators ]]; then
  python3 "$repo_root/scripts/smoke_release_binaries.py" \
    --cohort-dir "$(brew --prefix "$formula")/libexec"
fi
