#!/usr/bin/env python3
"""Create an approved draft and dispatch CI, or verify/publish it from Actions."""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import quote


from package_release import asset_names

HOMEBREW_TAP = "lynnswap/homebrew-tap"


class ReleaseError(Exception):
    pass


class APIError(ReleaseError):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class GitHub:
    def __init__(self, repository):
        self.repository = repository

    def api(self, path, method="GET", data=None):
        command = ["gh", "api", "--include", "--method", method,
                   f"repos/{self.repository}/{path}".rstrip("/")]
        if data is not None:
            command += ["--input", "-"]
        result = subprocess.run(
            command, input=json.dumps(data) if data is not None else None,
            capture_output=True, text=True, check=False,
        )
        header, separator, body = result.stdout.partition("\n\n")
        if not separator or not header.startswith("HTTP/"):
            raise ReleaseError(result.stderr.strip() or "GitHub returned no HTTP response.")
        status = int(header.splitlines()[0].split()[1])
        payload = json.loads(body) if body.strip() else None
        if result.returncode or not 200 <= status < 300:
            message = payload.get("message", body) if isinstance(payload, dict) else body
            raise APIError(status, f"{method} {path}: {message}")
        return payload

    def upload(self, tag, paths):
        subprocess.run(
            ["gh", "release", "upload", tag, "--repo", self.repository,
             "--clobber", *map(str, paths)], check=True,
        )


def publication_fields(release):
    return {key: release[key] for key in
            ("tag_name", "target_commitish", "name", "body", "prerelease")}


def fingerprint(release):
    # Assets are produced by CI; approval covers only the publication content.
    content = dict(publication_fields(release), id=release["id"])
    return hashlib.sha256(json.dumps(content, sort_keys=True).encode()).hexdigest()


def check_sha(sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReleaseError("Use the full lowercase 40-character target commit SHA.")


def is_prerelease(tag):
    script = Path(__file__).with_name("release-version-is-prerelease.sh")
    return subprocess.check_output([str(script), tag], text=True).strip() == "true"


def tag_commit(github, tag):
    try:
        entry = github.api("git/ref/tags/" + quote(tag, safe=""))
    except APIError as error:
        if error.status == 404:
            return None
        raise
    obj = entry["object"]
    while obj["type"] == "tag":
        obj = github.api("git/tags/" + obj["sha"])["object"]
    if obj["type"] != "commit":
        raise ReleaseError(f"Tag {tag} does not point to a commit.")
    return obj["sha"]


def check_tag(github, tag, sha):
    actual = tag_commit(github, tag)
    if actual is not None and actual != sha:
        raise ReleaseError(f"Tag {tag} points to {actual}, not approved commit {sha}.")
    return actual


def ensure_tag(github, tag, sha):
    if check_tag(github, tag, sha) is None:
        try:
            github.api("git/refs", "POST", dict(ref="refs/tags/" + tag, sha=sha))
        except APIError as error:
            if error.status != 422 or check_tag(github, tag, sha) is None:
                raise ReleaseError(
                    f"{error}\nGITHUB_TOKEN could not create the tested tag. Inspect tag rules "
                    "and workflow-file differences from the default branch before retrying. "
                    "Publication stopped; do not change the approved target without a new approval."
                ) from error


def prepare_source(github, release_id, sha, digest):
    release = verify(github, release_id, sha, digest)
    if not release["draft"] and tag_commit(github, release["tag_name"]) != sha:
        raise ReleaseError("The published release no longer has its approved tag.")
    try:
        ensure_tag(github, release["tag_name"], sha)
        release = verify(github, release_id, sha, digest)
    except ReleaseError as error:
        raise ReleaseError(
            f"{error}\nSource tag {release['tag_name']} may remain. "
            "Inspect the tag and rerun the failed job with the same approved target."
        ) from error
    print(f"Public source tag: {release['tag_name']} at {sha}")
    return release


def matching_releases(github, tag):
    matches = []
    page = 1
    while True:
        releases = github.api(f"releases?per_page=100&page={page}")
        matches += [release for release in releases if release["tag_name"] == tag]
        if len(releases) < 100:
            return matches
        page += 1


def start(github, tag, sha, title, notes):
    check_sha(sha)
    prerelease = is_prerelease(tag)
    if not notes.strip():
        raise ReleaseError("Supply the approved release notes before starting publication.")
    if github.api("commits/" + sha)["sha"] != sha:
        raise ReleaseError("The target is not the requested commit.")
    branch = github.api("")["default_branch"]
    check_tag(github, tag, sha)
    matches = matching_releases(github, tag)
    if len(matches) > 1:
        raise ReleaseError(f"Multiple releases use {tag}; select the intended draft first.")
    requested = dict(tag_name=tag, target_commitish=sha, name=title,
                     body=notes, prerelease=prerelease)
    if matches:
        release = matches[0]
        if not release["draft"]:
            raise ReleaseError(f"{tag} is already published.")
        if any(release[key] != value for key, value in requested.items()):
            raise ReleaseError("The existing draft differs from the supplied target or content; it was not changed.")
    else:
        release = github.api("releases", "POST", dict(requested, draft=True))
    print(f"Draft: {release['html_url']}", flush=True)
    inputs = dict(release_id=str(release["id"]), target_sha=sha,
                  content_digest=fingerprint(release))
    try:
        github.api("actions/workflows/release.yml/dispatches", "POST",
                   dict(ref=branch, inputs=inputs))
    except ReleaseError as error:
        raise ReleaseError(
            f"{error}\nDraft {release['id']} remains. Dispatch acceptance may be uncertain; "
            "inspect Actions before retrying the same command."
        ) from error
    print(f"Target: {sha}")
    print("Release workflow dispatch accepted. Successful checks will publish this draft.")
    print(f"Actions: https://github.com/{github.repository}/actions/workflows/release.yml")


def verify(github, release_id, sha, digest):
    check_sha(sha)
    release = github.api(f"releases/{release_id}")
    if release["target_commitish"] != sha or fingerprint(release) != digest:
        raise ReleaseError("The release target or approved content changed; publication stopped.")
    if release["prerelease"] != is_prerelease(release["tag_name"]):
        raise ReleaseError("The prerelease state does not match the version tag.")
    check_tag(github, release["tag_name"], sha)
    return release


def verify_uploaded_assets(release, expected):
    assets = release["assets"]
    if sorted(asset["name"] for asset in assets) != sorted(expected):
        raise ReleaseError("The uploaded release asset set is not exact.")
    for asset in assets:
        if asset["state"] != "uploaded" or asset.get("digest") != expected[asset["name"]]:
            raise ReleaseError(f"Uploaded asset does not match the verified file: {asset['name']}")


def formula_string(formula, field, indent="  "):
    declarations = re.findall(rf"^{indent}{re.escape(field)} (.*)$", formula, re.MULTILINE)
    match = re.fullmatch(r'''(["'])([^"'\n]+)\1(?:\s+#.*)?''', declarations[0]) if len(declarations) == 1 else None
    if match is None:
        raise ReleaseError(f"Cannot verify Formula's literal {field} declaration.")
    return match[2]


def formula_number(formula, field, indent="  "):
    declarations = re.findall(rf"^{indent}{re.escape(field)} (.*)$", formula, re.MULTILINE)
    if not declarations:
        return 0
    match = re.fullmatch(r"([0-9]+)(?:\s+#.*)?", declarations[0]) if len(declarations) == 1 else None
    if match is None:
        raise ReleaseError(f"Cannot verify Formula's literal {field} declaration.")
    return int(match[1])


def verify_homebrew_ready(github, tag, release_dir):
    try:
        expected_formula = (release_dir / "privateheaderkit.rb").read_text()
        source_digest = hashlib.sha256((release_dir / asset_names(tag)[0]).read_bytes()).hexdigest()
        main_sha = github.api("commits/main")["sha"]
        entry = github.api(f"contents/Formula/privateheaderkit.rb?ref={main_sha}")
        formula = base64.b64decode(entry["content"]).decode("utf-8")
        if (formula_string(formula, "url") != formula_string(expected_formula, "url")
                or formula_string(formula, "sha256").lower() != source_digest):
            raise ReleaseError("The public Formula does not match the prepared source URL and SHA-256.")
        version = tag.removeprefix("v")
        if re.search(r"^  version\b", formula, re.MULTILINE) and formula_string(formula, "version") != version:
            raise ReleaseError("The public Formula declares a different version.")
        blocks = re.findall(r"^  bottle do\n(.*?)^  end$", formula, re.MULTILINE | re.DOTALL)
        if len(blocks) != 1:
            raise ReleaseError("The public Formula has no unique bottle specification.")
        bottle = blocks[0]
        root_url = formula_string(bottle, "root_url", "    ")
        revision = formula_number(formula, "revision")
        package_version = f"{version}_{revision}" if revision else version
        bottle_tag = f"privateheaderkit-{package_version}"
        if root_url != f"https://github.com/{github.repository}/releases/download/{bottle_tag}":
            raise ReleaseError("The bottle URL does not name this version in the approved tap.")
        digests = re.findall(r'''^    sha256 [^\n]*\barm64_tahoe: ["']([0-9a-fA-F]{64})["'](?:\s+#.*)?$''',
                             bottle, re.MULTILINE)
        if len(digests) != 1:
            raise ReleaseError("The public Formula has no unique macOS 26 Apple Silicon bottle checksum.")
        rebuild = formula_number(bottle, "rebuild", "    ")
        suffix = f".{rebuild}" if rebuild else ""
        bottle_name = f"{bottle_tag}.arm64_tahoe.bottle{suffix}.tar.gz"
        published = github.api("releases/tags/" + quote(bottle_tag, safe=""))
        assets = [asset for asset in published["assets"] if asset["name"] == bottle_name]
        if published["draft"] or len(assets) != 1:
            raise ReleaseError("The matching bottle release/asset is not public.")
        asset = assets[0]
        if (asset["state"] != "uploaded" or asset.get("digest") != "sha256:" + digests[0].lower()
                or asset["browser_download_url"] != root_url + "/" + bottle_name):
            raise ReleaseError("The public bottle asset does not match the Formula's SHA-256 and URL.")
        return dict(tap_sha=main_sha, source_sha256=source_digest,
                    bottle_sha256=digests[0].lower(), bottle_url=asset["browser_download_url"])
    except (ReleaseError, KeyError, ValueError, UnicodeError, OSError) as error:
        raise ReleaseError(
            f"Homebrew is not ready for stable publication: {error}\n"
            "Complete the matching tap PR checks and homebrew-publish approval, "
            "then re-run the failed Release jobs to reuse the prepared assets and completed builds."
        ) from error


def publish(github, release_id, sha, digest, release_dir):
    release = verify(github, release_id, sha, digest)
    tag = release["tag_name"]
    if not release["draft"]:
        if tag_commit(github, tag) != sha:
            raise ReleaseError("The published release no longer has its approved tag.")
        print(f"Already published: {release['html_url']}")
        return

    names = asset_names(tag)
    unexpected = [asset["name"] for asset in release["assets"] if asset["name"] not in names]
    if unexpected:
        raise ReleaseError(f"Remove unexpected draft assets before retrying: {', '.join(unexpected)}")
    paths = [release_dir / name for name in names]
    expected = {path.name: "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()
                for path in paths}
    try:
        github.upload(tag, paths)
        release = verify(github, release_id, sha, digest)
        verify_uploaded_assets(release, expected)
        ensure_tag(github, tag, sha)
        # Tag creation and asset uploads are separate from publication on GitHub.
        release = verify(github, release_id, sha, digest)
        verify_uploaded_assets(release, expected)
        if not release["prerelease"]:
            verify_homebrew_ready(GitHub(HOMEBREW_TAP), tag, release_dir)
        published = github.api(
            f"releases/{release_id}", "PATCH",
            dict(publication_fields(release), draft=False,
                 make_latest="false" if release["prerelease"] else "legacy"),
        )
    except (ReleaseError, subprocess.CalledProcessError) as error:
        raise ReleaseError(
            f"{error}\nDraft/assets or tag {tag} may remain; publication may be uncertain. "
            "Inspect the release and rerun the failed publish job to resume."
        ) from error
    if published["draft"] or fingerprint(published) != digest:
        raise ReleaseError("GitHub's publication response did not preserve the approved release.")
    verify_uploaded_assets(published, expected)
    print(f"Published: {published['html_url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    launch = commands.add_parser("start", help="Create/reuse a draft and start automatic publication")
    launch.add_argument("version")
    launch.add_argument("--target", required=True, help="Approved full commit SHA")
    launch.add_argument("--notes-file", required=True, type=Path)
    launch.add_argument("--title", help="Defaults to the version")
    launch.add_argument("--repo", required=True)
    homebrew = commands.add_parser("homebrew-ready", help="Verify public Formula and bottle delivery")
    homebrew.add_argument("--version", required=True)
    homebrew.add_argument("--release-dir", required=True, type=Path)
    homebrew.add_argument("--github-output", type=Path)
    for name in ("verify", "prepare-source", "publish"):
        command = commands.add_parser(name, help="Internal Actions entry point")
        command.add_argument("--repo", required=True)
        command.add_argument("--release-id", required=True, type=int)
        command.add_argument("--target", required=True)
        command.add_argument("--digest", required=True)
        if name != "publish":
            command.add_argument("--github-output", type=Path)
        else:
            command.add_argument("--release-dir", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        if arguments.command == "homebrew-ready":
            required = not is_prerelease(arguments.version)
            evidence = verify_homebrew_ready(GitHub(HOMEBREW_TAP), arguments.version,
                                            arguments.release_dir) if required else {}
            if arguments.github_output:
                with arguments.github_output.open("a", encoding="utf-8") as output:
                    output.write(f"required={'true' if required else 'false'}\n")
                    for key, value in evidence.items():
                        output.write(f"{key}={value}\n")
            print(json.dumps(evidence) if required else "Prereleases do not require stable tap publication.")
            return 0
        github = GitHub(arguments.repo)
        if arguments.command == "start":
            start(github, arguments.version, arguments.target,
                  arguments.title or arguments.version,
                  arguments.notes_file.read_text(encoding="utf-8"))
        elif arguments.command != "publish":
            operation = prepare_source if arguments.command == "prepare-source" else verify
            release = operation(github, arguments.release_id, arguments.target, arguments.digest)
            if arguments.github_output:
                with arguments.github_output.open("a", encoding="utf-8") as output:
                    output.write(f"version={release['tag_name']}\n")
                    output.write(f"release_url={release['html_url']}\n")
                    output.write(f"source_url=https://github.com/{github.repository}/archive/refs/tags/{release['tag_name']}.tar.gz\n")
            print(f"Verified: {release['html_url']} at {arguments.target}")
        else:
            publish(github, arguments.release_id, arguments.target, arguments.digest,
                    arguments.release_dir)
    except (ReleaseError, OSError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
