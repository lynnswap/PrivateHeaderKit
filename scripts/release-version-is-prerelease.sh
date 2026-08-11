#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: scripts/release-version-is-prerelease.sh <tag>" >&2
  exit 1
fi

version="$1"
if [[ "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
  printf 'false\n'
elif [[ "$version" =~ ^v[0-9]+[.][0-9]+[.][0-9]+[-.][0-9A-Za-z.-]+$ ]]; then
  printf 'true\n'
else
  echo "Release tag must look like v1.2.3." >&2
  exit 1
fi
