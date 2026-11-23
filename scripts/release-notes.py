#!/usr/bin/env python3
"""Validate the release changelog before publication and read it from a served package."""

import argparse
import io
from pathlib import Path
import re
import sys
import tarfile


def section(version, changelog):
    sections = re.findall(
        rf"^## \[{re.escape(version)}\][^\n]*(?:\n|\Z).*?(?=^## |\Z)", changelog,
        re.M | re.S,
    )
    body = sections[0].partition("\n")[2] if len(sections) == 1 else ""
    if not re.sub(r"^\s*#+[^\n]*$", "", body, flags=re.M).strip():
        raise ValueError("The release changelog section is missing, duplicated or empty.")
    return sections[0].strip()


def verify_changelog(mixfile, changelog):
    versions = re.findall(r'^  @version "([^"]+)"$', mixfile.read_text(encoding="utf-8"), re.M)
    if len(versions) != 1:
        raise ValueError("Expected exactly one Mix project version.")
    section(versions[0], changelog.read_text(encoding="utf-8"))


def member(packed, name):
    matches = [entry for entry in packed if entry.name == name]
    if len(matches) != 1 or not matches[0].isfile():
        raise ValueError("Hex package changelog is missing, duplicated or malformed.")
    return packed.extractfile(matches[0]).read()


def package_section(archive, version):
    with tarfile.open(archive, "r:") as package:
        contents = member(package, "contents.tar.gz")
    with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as contents:
        changelog = member(contents, "CHANGELOG.md").decode("utf-8")
    return section(version, changelog)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mixfile", type=Path, default=Path("mix.exs"))
    parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    args = parser.parse_args()
    try:
        verify_changelog(args.mixfile, args.changelog)
    except (OSError, UnicodeError, ValueError) as error:
        print(f"Release notes refused: {error}", file=sys.stderr)
        return 1
    print("CHANGELOG OK: exactly one nonempty release section")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
