#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: inspect-draft-release.sh --version <tag> --commit <sha> --repo <owner/name>
EOF
}

version=""
commit=""
repo=""

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
      repo="${2:-}"
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

if [[ -z "$version" || -z "$commit" || -z "$repo" ]]; then
  usage >&2
  exit 1
fi
if [[ ! "$commit" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "Release commit must be a full 40-character commit SHA." >&2
  exit 1
fi
commit="$(printf '%s' "$commit" | tr 'A-F' 'a-f')"

remote_tag_target="$(
  git ls-remote --tags origin "refs/tags/${version}" "refs/tags/${version}^{}" |
    awk '$2 ~ /\^\{\}$/ { peeled = $1 } $2 !~ /\^\{\}$/ { direct = $1 } END { if (peeled != "") print peeled; else if (direct != "") print direct }'
)"
if [[ -n "$remote_tag_target" && "$remote_tag_target" != "$commit" ]]; then
  echo "Release tag targets a different commit: ${version}" >&2
  echo "Tag target: ${remote_tag_target}" >&2
  echo "Release commit: ${commit}" >&2
  exit 1
fi

temporary_base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
release_error="$(mktemp "${temporary_base%/}/privateheaderkit-release-view.XXXXXX")"
cleanup() {
  rm -f "$release_error"
}
trap cleanup EXIT HUP INT TERM

if release_state="$(
  gh release view "$version" \
    --repo "$repo" \
    --json isDraft,isPrerelease,targetCommitish \
    --jq '[.isDraft, .isPrerelease, .targetCommitish] | @tsv' \
    2>"$release_error"
)"; then
  IFS=$'\t' read -r is_draft is_prerelease target_commitish <<< "$release_state"
  if [[ "$is_draft" != "true" ]]; then
    echo "GitHub Release exists and is not a draft: ${version}" >&2
    exit 1
  fi
  if [[ "$target_commitish" != "$commit" ]]; then
    echo "Draft release targets a different commit: ${version}" >&2
    echo "Draft target: ${target_commitish:-<missing>}" >&2
    echo "Release commit: ${commit}" >&2
    exit 1
  fi
  printf 'draft\t%s\n' "$is_prerelease"
elif grep -Eiq '(not found|HTTP 404|no release found)' "$release_error"; then
  printf 'missing\n'
else
  cat "$release_error" >&2
  exit 1
fi
