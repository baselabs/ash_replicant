#!/usr/bin/env python3
# Exercise the inspector against actual ExDoc output and mutated archive bytes.

import importlib.util
import io
import sys
import tarfile
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "release_docs", Path(__file__).with_name("inspect-release-docs.py")
)
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)
archive, directory = sys.argv[1:]
inspector.inspect(archive, directory)

with tempfile.TemporaryDirectory(prefix="ash-replicant-docs-check-") as work:
    for mutation in ["missing", "changed", "extra", "duplicate", "traversal", "symlink"]:
        candidate = Path(work) / "docs.tar.gz"
        with tarfile.open(archive, "r:gz") as original, tarfile.open(candidate, "w:gz") as output:
            for entry in original:
                if entry.isfile():
                    payload = original.extractfile(entry).read()
                    if entry.name.removeprefix("./") == "index.html":
                        if mutation == "missing":
                            continue
                        if mutation == "changed":
                            payload += b"changed"
                            entry.size = len(payload)
                    output.addfile(entry, io.BytesIO(payload))
                else:
                    output.addfile(entry)
            if mutation in ["extra", "duplicate", "traversal", "symlink"]:
                name = {
                    "extra": "unexpected.html",
                    "duplicate": "index.html",
                    "traversal": "../outside.html",
                    "symlink": "linked.html",
                }[mutation]
                entry = tarfile.TarInfo(name)
                if mutation == "symlink":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "index.html"
                output.addfile(entry, io.BytesIO(b""))
        try:
            inspector.inspect(candidate, directory)
        except ValueError:
            pass
        else:
            raise AssertionError(f"docs inspector accepted {mutation}")

print("docs archive inspection: real docs and six negative archives PASS")
