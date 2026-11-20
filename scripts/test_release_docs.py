#!/usr/bin/env python3
# Exercise the inspector against actual ExDoc output and mutated archive bytes.

import gzip
import importlib.util
import io
import hashlib
import json
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "release_docs", Path(__file__).with_name("check-docs-archive.py")
)
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)
archive, directory = sys.argv[1:]
identity = json.loads((Path(directory) / "release.json").read_text())
version, commit = identity["version"], identity["commit"]


def check(candidate, tree=None, **kwargs):
    return inspector.check(Path(candidate), tree, version=version, commit=commit, **kwargs)


check(archive, Path(directory))

with tempfile.TemporaryDirectory(prefix="ash-replicant-docs-check-") as work:
    reasons = {
        "missing": "requires top-level",
        "changed": "bytes differ from source",
        "extra": "has no source",
        "duplicate": "Duplicate docs archive member",
        "traversal": "Unsafe docs archive member",
        "symlink": "Unsafe docs archive member",
    }
    for mutation in ["clean", *reasons]:
        candidate = Path(work) / "docs.tar.gz"
        packed = io.BytesIO()
        with tarfile.open(archive, "r:gz") as original, tarfile.open(fileobj=packed, mode="w") as output:
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
                entry.mtime = 946684800
                if mutation == "symlink":
                    entry.type = tarfile.SYMTYPE
                    entry.linkname = "index.html"
                output.addfile(entry, io.BytesIO(b""))
        # Preserve the fixed gzip header so each negative reaches its intended guard.
        compressed = gzip.compress(packed.getvalue(), mtime=0)
        candidate.write_bytes(bytes((31, 139, 8, 0, 0, 0, 0, 0, 0, 0)) + compressed[10:])
        if mutation == "clean":
            check(candidate, Path(directory))
            continue
        try:
            check(candidate, Path(directory))
        except ValueError as error:
            if reasons[mutation] not in str(error):
                raise AssertionError(f"wrong rejection for {mutation}: {error}") from error
        else:
            raise AssertionError(f"docs inspector accepted {mutation}")

# Build real archive variants from rendered output, and exercise actual Git ancestry.
with tempfile.TemporaryDirectory(prefix="ash-replicant-docs-provenance-") as scratch:
    work = Path(scratch)
    repo = work / "repo"
    repo.mkdir()

    def git(*args):
        return subprocess.run(["git", "-C", str(repo), *args], check=True,
                              capture_output=True).stdout.decode().strip()

    git("init", "--initial-branch=main")
    git("config", "user.name", "Docs provenance test")
    git("config", "user.email", "docs@example.invalid")
    git("commit", "--allow-empty", "-m", "Ancestor")
    ancestor = git("rev-parse", "HEAD")
    git("commit", "--allow-empty", "-m", "Dispatch")
    dispatched = git("rev-parse", "HEAD")
    git("commit", "--allow-empty", "-m", "Descendant")
    descendant = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/main", dispatched)
    git("checkout", "--orphan", "unrelated")
    git("commit", "--allow-empty", "-m", "Outside default history")
    unrelated = git("rev-parse", "HEAD")

    def variant(release, *, omit=False):
        candidate = work / "served.tar.gz"
        packed = io.BytesIO()
        with tarfile.open(archive, "r:gz") as original, tarfile.open(fileobj=packed, mode="w") as output:
            for entry in original:
                payload = original.extractfile(entry).read()
                if entry.name == "release.json":
                    if omit:
                        continue
                    payload = release if isinstance(release, bytes) else json.dumps(release).encode()
                    entry.size = len(payload)
                output.addfile(entry, io.BytesIO(payload))
        compressed = gzip.compress(packed.getvalue(), mtime=0)
        candidate.write_bytes(bytes((31, 139, 8, 0, 0, 0, 0, 0, 0, 0)) + compressed[10:])
        return candidate

    def served(candidate, **kwargs):
        return inspector.check(candidate, version=version, commit=dispatched, repository=repo, **kwargs)

    for accepted in [ancestor, dispatched]:
        assert served(variant({**identity, "commit": accepted})) == accepted

    negatives = [
        ({**identity, "package": "other"}, "identity"),
        ({**identity, "version": "0.0.0"}, "identity"),
        ({**identity, "commit": 1}, "identity"),
        ({**identity, "commit": "bad"}, "identity"),
        ({**identity, "extra": True}, "identity"),
        ({"package": "ash_replicant", "version": version}, "identity"),
        ({**identity, "commit": descendant}, "outside available"),
        ({**identity, "commit": unrelated}, "outside available"),
        ({**identity, "commit": "0" * 40}, "outside available"),
        (b"not JSON", "JSON"),
        (b'{"package": "ash_replicant", "package": "other"}', "Duplicate"),
        ([], "identity"),
    ]
    for release, reason in negatives:
        try:
            served(variant(release))
        except ValueError as error:
            assert reason in str(error), (reason, error)
        else:
            raise AssertionError("served docs accepted invalid release provenance")

    for mode, reason in [("missing", "requires top-level release.json"),
                         ("history", "outside available"), ("shallow", "Complete default-branch")]:
        candidate = variant({**identity, "commit": ancestor}, omit=mode == "missing")
        if mode == "history":
            git("update-ref", "-d", "refs/remotes/origin/main")
        if mode == "shallow":
            git("update-ref", "refs/remotes/origin/main", dispatched)
            (repo / ".git/shallow").write_text(ancestor + "\n")
        try:
            served(candidate)
        except ValueError as error:
            assert reason in str(error), (reason, error)
        else:
            raise AssertionError("served docs accepted missing provenance or history")
    (repo / ".git/shallow").unlink()

    # The ancestor archive differs from this job's rendering. Retention uses its bytes.
    candidate = variant({**identity, "commit": ancestor})
    published = served(candidate)
    package = work / "package.tar"
    package.write_bytes(b"inspected package")
    assets = work / "release-assets"
    inspector.retain_assets(candidate, package, assets, version, published)
    retained = assets / f"ash_replicant-{version}-docs.tar.gz"
    assert retained.read_bytes() == candidate.read_bytes()
    assert retained.read_bytes() != Path(archive).read_bytes()
    sums = (assets / "SHA256SUMS").read_text()
    assert hashlib.sha256(candidate.read_bytes()).hexdigest() + "  " + retained.name in sums
    assert (assets / "published-commit.txt").read_text().strip() == ancestor

print("docs inspection: real renders, negative archives, provenance, ancestry and served assets PASS")
