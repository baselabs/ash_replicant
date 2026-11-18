#!/usr/bin/env python3
# Require the archive to contain exactly the generated docs, without extracting it.

import sys
import tarfile
from pathlib import Path, PurePosixPath


def inspect(archive, directory):
    root = Path(directory)
    expected = {}
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError("unsupported generated docs entry")
        if path.is_file():
            expected[path.relative_to(root).as_posix()] = path.read_bytes()
    if not expected.get("index.html"):
        raise ValueError("generated docs have no index.html")

    seen = set()
    with tarfile.open(archive, "r:gz") as contents:
        for entry in contents:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or ".." in path.parts:
                raise ValueError("unsafe docs archive path")
            if entry.isdir():
                continue
            name = path.as_posix()
            if not entry.isfile() or name in seen or name not in expected:
                raise ValueError("unexpected docs archive entry")
            seen.add(name)
            with contents.extractfile(entry) as source:
                if source.read() != expected[name]:
                    raise ValueError("docs archive content differs from generated docs")
    if seen != expected.keys():
        raise ValueError("docs archive files differ from generated docs")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: inspect-release-docs.py ARCHIVE DOC_DIRECTORY")
        inspect(*sys.argv[1:])
    except (OSError, ValueError, tarfile.TarError) as error:
        sys.exit(f"inspect-release-docs: {error}")
    print("inspect-release-docs: archive matches generated docs")
