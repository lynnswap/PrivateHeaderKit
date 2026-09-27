#!/usr/bin/env python3
"""Package approved source and a Homebrew formula; verify transferred release assets."""

import argparse
import gzip
import hashlib
from pathlib import Path
import re
import subprocess
import sys


def asset_names(tag):
    return (f"privateheaderkit-{tag.removeprefix('v')}.tar.gz", "privateheaderkit.rb", "SHA256SUMS.txt")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render_formula(tag, repository, source_digest):
    template = Path(__file__).resolve().parent.parent / "Homebrew/privateheaderkit.rb.in"
    return (template.read_text().replace("__VERSION__", tag.removeprefix("v"))
            .replace("__REPOSITORY__", repository).replace("__SHA256__", source_digest))


def package(source, commit, tag, repository, output):
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Use the full lowercase 40-character source commit SHA.")
    if not re.fullmatch(r"[\w.-]+/[\w.-]+", repository):
        raise ValueError("Use an owner/repository name.")
    output.mkdir(parents=True, exist_ok=True)
    archive_name, formula_name, checksums_name = asset_names(tag)
    prefix = f"privateheaderkit-{tag.removeprefix('v')}/"
    source_tar = subprocess.check_output([
        "git", "-C", str(source), "archive", "--format=tar", f"--prefix={prefix}", commit,
    ])
    archive = output / archive_name
    archive.write_bytes(gzip.compress(source_tar, mtime=0))
    (output / formula_name).write_text(render_formula(tag, repository, sha256(archive)))
    (output / checksums_name).write_text("".join(
        f"{sha256(output / name)}  {name}\n" for name in (archive_name, formula_name)
    ))


def verify(directory, tag, checksums_digest=None):
    archive, formula, checksums_name = asset_names(tag)
    checksums = directory / checksums_name
    if checksums_digest is not None and sha256(checksums) != checksums_digest:
        raise ValueError("Transferred checksums differ from the verified release job.")
    expected = {}
    for line in checksums.read_text().splitlines():
        digest, name = line.split("  ", 1)
        if name in expected or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("Invalid release checksums.")
        expected[name] = digest
    if set(expected) != {archive, formula}:
        raise ValueError("Checksums must cover the source archive and Formula.")
    for name, digest in expected.items():
        if sha256(directory / name) != digest:
            raise ValueError(f"Release checksum mismatch: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("create")
    create.add_argument("--source-root", type=Path, required=True)
    create.add_argument("--commit", required=True)
    create.add_argument("--repo", required=True)
    create.add_argument("--output-dir", type=Path, required=True)
    check = commands.add_parser("verify")
    check.add_argument("--release-dir", type=Path, required=True)
    check.add_argument("--checksums-sha256")
    for command in (create, check):
        command.add_argument("--version", required=True)
    args = parser.parse_args()
    try:
        subprocess.run([str(Path(__file__).with_name("release-version-is-prerelease.sh")),
                        args.version], check=True, stdout=subprocess.DEVNULL)
        if args.command == "create":
            package(args.source_root, args.commit, args.version, args.repo, args.output_dir)
        else:
            verify(args.release_dir, args.version, args.checksums_sha256)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
