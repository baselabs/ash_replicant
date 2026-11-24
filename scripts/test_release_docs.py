#!/usr/bin/env python3
# Exercise the inspector against actual ExDoc output and mutated archive bytes.

import gzip
import importlib.util
import io
import hashlib
import json
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from textwrap import dedent

spec = importlib.util.spec_from_file_location(
    "release_docs", Path(__file__).with_name("check-docs-archive.py")
)
inspector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inspector)
archive, directory, package_archive = sys.argv[1:]
identity = json.loads((Path(directory) / "release.json").read_text())
version, commit = identity["version"], identity["commit"]

publish = Path(__file__).resolve().parents[1] / ".github/workflows/publish.yml"
stamp_step = re.search(
    r"^      - name: Refuse a package whose changelog is not stamped for its version\n"
    r".*?^        run: \|\n(.*?)(?=^      - )",
    publish.read_text(encoding="utf-8"),
    flags=re.M | re.S,
)
assert stamp_step is not None, "publish workflow is missing the package changelog stamp check"


def check_changelog_stamp(package):
    package = Path(package)
    assert package.name == "package.tar"
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c",
         'export RUNNER_TEMP="$1" VERSION="$2"\n' + dedent(stamp_step[1]),
         "changelog-stamp", str(package.resolve().parent), version],
        capture_output=True,
        text=True,
        check=False,
    )


stamped = check_changelog_stamp(package_archive)
assert stamped.returncode == 0, stamped.stderr
print(stamped.stdout, end="")


def check(candidate, tree=None, **kwargs):
    return inspector.check(Path(candidate), tree, version=version, commit=commit, **kwargs)


# The same parser admits the checkout preflight and the changelog inside served packages.
notes = inspector.release_notes
valid_section = f"## [{version}] - 2026-11-22\n\n### Fixed\n\n- Packaged release note."
assert notes.section(version, valid_section + "\n\n## [0.0.0]\n\n- Older.\n") == valid_section

for changelog in [
    "## [Unreleased]\n\n- A different release.\n",
    valid_section + "\n\n" + valid_section,
    f"## [{version}]",
    f"## [{version}]\n\n### Fixed\n\n",
]:
    try:
        notes.section(version, changelog)
    except ValueError as error:
        assert "missing, duplicated or empty" in str(error)
    else:
        raise AssertionError("release notes accepted an invalid changelog section")

with tempfile.TemporaryDirectory(prefix="ash-replicant-changelog-") as scratch:
    work = Path(scratch)
    mixfile, changelog = work / "mix.exs", work / "CHANGELOG.md"
    mixfile.write_text(f'  @version "{version}"\n')
    changelog.write_text(valid_section)
    notes.verify_changelog(mixfile, changelog)
    command = [sys.executable, "-I", str(Path(notes.__file__)),
               "--mixfile", str(mixfile), "--changelog", str(changelog)]
    subprocess.run(command, check=True, capture_output=True)
    for invalid in ["", valid_section + "\n\n" + valid_section,
                    f"## [{version}]\n\n### Fixed\n"]:
        changelog.write_text(invalid)
        result = subprocess.run(command, check=False, capture_output=True)
        assert result.returncode == 1 and b"missing, duplicated or empty" in result.stderr
    changelog.write_text(valid_section)
    for invalid in ["", f'  @version "{version}"\n  @version "{version}"\n']:
        mixfile.write_text(invalid)
        result = subprocess.run(command, check=False, capture_output=True)
        assert result.returncode == 1 and b"exactly one Mix project version" in result.stderr


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
    package.write_bytes(Path(package_archive).read_bytes())
    assets = work / "release-assets"
    inspector.retain_assets(candidate, package, assets, version, published)
    retained = assets / f"ash_replicant-{version}-docs.tar.gz"
    assert retained.read_bytes() == candidate.read_bytes()
    assert retained.read_bytes() != Path(archive).read_bytes()
    sums = (assets / "SHA256SUMS").read_text()
    assert hashlib.sha256(candidate.read_bytes()).hexdigest() + "  " + retained.name in sums
    assert (assets / "published-commit.txt").read_text().strip() == ancestor
    package_digest = hashlib.sha256(package.read_bytes()).hexdigest()
    docs_digest = hashlib.sha256(candidate.read_bytes()).hexdigest()
    release_text = (assets / "RELEASE-NOTES.md").read_text()
    assert release_text == (
        notes.package_section(package, version) + f"\n\nCommit: {ancestor}\n\n"
        f"Package SHA-256: {package_digest}\n\nDocs SHA-256: {docs_digest}\n"
    )
    assert f"Commit: {dispatched}" not in release_text
    assert package_digest + "  " + f"ash_replicant-{version}.tar" in sums

    for invalid_commit in ["", ancestor[:7], "g" * 40]:
        destination = work / "assets-invalid-commit"
        try:
            inspector.retain_assets(candidate, package, destination, version, invalid_commit)
        except ValueError as error:
            assert "full published commit" in str(error) and not destination.exists()
        else:
            raise AssertionError("release notes accepted an incomplete published commit")

    # Mutate the actual built package in memory; never extract archive paths to disk.
    with tarfile.open(package_archive, "r:") as original:
        original_entries = [(entry, original.extractfile(entry).read()) for entry in original]
    contents = next(payload for entry, payload in original_entries if entry.name == "contents.tar.gz")
    for mutation in ["changed", "missing", "duplicate", "empty", "linked", "duplicate_member", "unstamped"]:
        packed = io.BytesIO()
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as original, \
                tarfile.open(fileobj=packed, mode="w:gz") as output:
            for entry in original:
                payload = original.extractfile(entry).read()
                if entry.name == "CHANGELOG.md":
                    if mutation == "missing":
                        continue
                    payload = valid_section.encode()
                    if mutation == "duplicate":
                        payload += b"\n\n" + payload
                    if mutation == "empty":
                        payload = f"## [{version}]\n\n### Fixed\n".encode()
                    if mutation == "unstamped":
                        payload = b"## [Unreleased]\n\n- An unstamped entry.\n\n" + payload
                    entry.size = len(payload)
                    if mutation == "linked":
                        entry.type, entry.linkname, entry.size = tarfile.SYMTYPE, "README.md", 0
                output.addfile(entry, io.BytesIO(payload))
                if mutation == "duplicate_member" and entry.name == "CHANGELOG.md":
                    output.addfile(entry, io.BytesIO(payload))
        altered = work / "package.tar"
        with tarfile.open(altered, "w:") as output:
            for entry, payload in original_entries:
                if entry.name == "contents.tar.gz":
                    payload = packed.getvalue()
                    entry.size = len(payload)
                output.addfile(entry, io.BytesIO(payload))
        if mutation == "unstamped":
            result = check_changelog_stamp(altered)
            assert result.returncode == 1, result.stdout
            assert f"entries above {version}" in result.stderr, result.stderr
            continue
        destination = work / f"assets-{mutation}"
        if mutation == "changed":
            inspector.retain_assets(candidate, altered, destination, version, ancestor)
            retained_notes = (destination / "RELEASE-NOTES.md").read_text()
            assert retained_notes.startswith(valid_section + "\n\nCommit: " + ancestor)
            assert hashlib.sha256(altered.read_bytes()).hexdigest() in retained_notes
        else:
            try:
                inspector.retain_assets(candidate, altered, destination, version, ancestor)
            except ValueError:
                assert not destination.exists()
            else:
                raise AssertionError("release assets accepted invalid packaged release notes")

print("docs inspection: real renders, negative archives, provenance, ancestry and served assets PASS")
