#!/usr/bin/env python3
"""Inspect rendered or served Hex docs and their release provenance."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import zlib


SEMVER = re.compile(
    r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def provenance(payload, package, version, commit, repository):
    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate release.json field.")
            result[key] = value
        return result

    try:
        release = json.loads(payload, object_pairs_hook=unique_fields)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ValueError("Invalid release.json JSON.") from error
    if (not isinstance(release, dict) or set(release) != {"package", "version", "commit"}
            or release["package"] != package or release["version"] != version
            or not isinstance(release["commit"], str)
            or not re.fullmatch(r"[0-9a-f]{40}", release["commit"])):
        raise ValueError("Invalid release.json identity.")
    published = release["commit"]
    if repository is None:
        if published != commit:
            raise ValueError("Built docs commit differs from the dispatched commit.")
    else:
        def git(*args):
            result = subprocess.run(["git", "-C", str(repository), *args],
                                    capture_output=True, check=False)
            if result.returncode:
                raise ValueError("Docs provenance is outside available default-branch history.")
            return result.stdout.strip()

        if git("rev-parse", "--is-shallow-repository") != b"false":
            raise ValueError("Complete default-branch history is required.")
        git("show-ref", "--verify", "refs/remotes/origin/main")
        git("merge-base", "--is-ancestor", commit, "refs/remotes/origin/main")
        git("merge-base", "--is-ancestor", published, commit)
    return published


def check(archive, directory=None, *, package="ash_replicant", version, commit, repository=None):
    if not SEMVER.fullmatch(version) or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected release identity is invalid.")
    source = None
    if directory is not None:
        if not directory.is_dir():
            raise ValueError("Documentation source directory is missing.")
        # Hex excludes dot-prefixed files and directories, including ExDoc's manifests.
        source = {}
        for path in directory.rglob("*"):
            if path.is_symlink() or not (path.is_file() or path.is_dir()):
                raise ValueError("Documentation contains a link or special entry.")
            relative = path.relative_to(directory)
            if path.is_file() and not any(part.startswith(".") for part in relative.parts):
                source[relative.as_posix()] = path
    names = set()
    # Hex emits a fixed gzip header: no original filename, timestamp, or OS.
    with archive.open("rb") as stream:
        if stream.read(10) != bytes((31, 139, 8, 0, 0, 0, 0, 0, 0, 0)):
            raise ValueError("Docs gzip header must have no name or mtime.")
    ordered = []
    release = None
    with tarfile.open(archive, "r:gz") as packed:
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or "\\" in member.name
                    or any(part in ("", ".", "..") for part in member.name.split("/"))):
                raise ValueError(f"Unsafe docs archive member: {member.name!r}")
            if SEMVER.fullmatch(path.parts[0]):
                raise ValueError("Top-level documentation filenames cannot be semantic versions.")
            if path.suffix == ".epub":
                raise ValueError("EPUB embeds build time by default; only HTML and Markdown ship.")
            if (member.uid != 0 or member.gid != 0 or member.uname or member.gname
                    or member.mtime != 946684800):
                raise ValueError("Docs tar metadata must use fixed times and empty ownership.")
            if member.name in names:
                raise ValueError(f"Duplicate docs archive member: {member.name!r}")
            names.add(member.name)
            ordered.append(member.name)
            payload = packed.extractfile(member).read()
            if len(payload) != member.size:
                raise ValueError("Truncated docs archive member.")
            if member.name == "release.json":
                release = payload
            if source is not None:
                if member.name not in source:
                    raise ValueError(f"Docs archive member has no source: {member.name!r}")
                if payload != source[member.name].read_bytes():
                    raise ValueError(f"Docs archive bytes differ from source: {member.name!r}")
    if not {"index.html", "readme.html"} <= names:
        raise ValueError("Docs archive requires top-level index.html and readme.html.")
    if release is None:
        raise ValueError("Docs archive requires top-level release.json.")
    published = provenance(release, package, version, commit, repository)
    if source is not None and names != source.keys():
        raise ValueError(f"Docs archive omits source files: {sorted(source.keys() - names)!r}")
    if ordered != sorted(ordered):
        raise ValueError("Docs archive entries must be sorted.")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    print(f"DOCS OK: {len(names)} regular files; contents and release provenance inspected")
    print(f"SHA256: {digest}")
    print(f"Published commit: {published}")
    return published


def retain_assets(archive, package_archive, assets, version, published):
    # The caller passes the downloaded docs, never the local rendering.
    assets.mkdir()
    try:
        paths = [assets / f"ash_replicant-{version}.tar", assets / f"ash_replicant-{version}-docs.tar.gz"]
        shutil.copyfile(package_archive, paths[0])
        shutil.copyfile(archive, paths[1])
        sums = ""
        for path in paths:
            with path.open("rb") as stream:
                digest = hashlib.file_digest(stream, "sha256").hexdigest()
            sums += f"{digest}  {path.name}\n"
        (assets / "SHA256SUMS").write_text(sums)
        (assets / "published-commit.txt").write_text(published + "\n")
    except BaseException:
        shutil.rmtree(assets)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("directory", type=Path, nargs="?")
    parser.add_argument("--package", default="ash_replicant")
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repository", type=Path)
    parser.add_argument("--commit-output", type=Path)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--package-archive", type=Path)
    args = parser.parse_args()
    try:
        published = check(args.archive, args.directory, package=args.package, version=args.version,
                          commit=args.commit, repository=args.repository)
        if args.assets:
            if args.repository is None or args.package_archive is None:
                raise ValueError("Release assets require served docs and default-branch history.")
            retain_assets(args.archive, args.package_archive, args.assets, args.version, published)
        if args.commit_output:
            args.commit_output.write_text(published + "\n")
    except (OSError, ValueError, tarfile.TarError, EOFError, zlib.error) as error:
        print(f"Docs archive refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
