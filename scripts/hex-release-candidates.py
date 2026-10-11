#!/usr/bin/env python3
"""Validate a Hex HTTP receipt before admitting its non-retired versions."""

import json
import re
import sys
from pathlib import Path


def candidates(body, transport_exit, http_status):
    if transport_exit != "0":
        raise ValueError("network error")
    if http_status != "200":
        raise ValueError("non-200 response")
    response = json.loads(body)
    if not isinstance(response, dict):
        raise ValueError("malformed body")
    releases = response.get("releases")
    retirements = response.get("retirements")
    if not isinstance(releases, list) or not releases or not isinstance(retirements, dict):
        raise ValueError("malformed body")
    versions = []
    for release in releases:
        if not isinstance(release, dict):
            raise ValueError("malformed release")
        version = release.get("version")
        if not isinstance(version, str) or not re.fullmatch(
            r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version
        ):
            raise ValueError("malformed release version")
        if version not in retirements:
            versions.append(version)
    return versions


if __name__ == "__main__":
    try:
        body_path, transport, status = sys.argv[1:]
        versions = candidates(Path(body_path).read_text(), transport, status)
    except (ValueError, OSError) as error:
        # Never include the response body, path, or transport diagnostic.
        reason = str(error) if type(error) is ValueError else "unreadable body"
        if isinstance(error, json.JSONDecodeError):
            reason = "empty or malformed body"
        print(f"Hex response rejected: {reason}", file=sys.stderr)
        sys.exit(1)
    print("\n".join(versions))
