#!/usr/bin/env bash
set -euo pipefail
# One reader for declarations, workflow matrices and the qualification inventory.
mode="${1:-}"
[[ "$mode" == '' || "$mode" == --json ]] || exit 2
[[ "$#" -le 2 ]] || exit 2
root="${2:-$(cd "$(dirname "$0")/../.." && pwd)}"
result="$(python3 - "$root" "$(dirname "$0")/../dependency-requirements.exs" <<'PYTHON'
import json
from pathlib import Path
import re
import sys
import subprocess


def refuse():
    raise ValueError('invalid PostgreSQL lane declaration')


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            refuse()
        result[key] = value
    return result


try:
    root = Path(sys.argv[1])
    reference = (root / '.github/postgres.ref').read_text()
    engine = re.fullmatch(
        r'ghcr\.io/baselabs/postgres:([1-9][0-9]*)\.[0-9]+-inputs-[0-9a-f]{64}@sha256:[0-9a-f]{64}\n',
        reference,
    )
    if not engine:
        refuse()
    engine_major = engine[1]
    lanes = json.loads((root / '.github/postgres-lanes.json').read_text(), object_pairs_hook=unique_object)
    if not isinstance(lanes, list) or not lanes:
        refuse()
    seen = set()
    for lane in lanes:
        if not isinstance(lane, dict) or set(lane) != {'major', 'image', 'roles'}:
            refuse()
        major, image, roles = lane['major'], lane['image'], lane['roles']
        if not isinstance(major, str) or not re.fullmatch(r'(?:9\.[0-9]+|[1-9][0-9]+)', major):
            refuse()
        if major == engine_major or major in seen:
            refuse()
        seen.add(major)
        if not isinstance(image, str) or not re.fullmatch(
            r'postgres:' + re.escape(major) + r'(?:\.[0-9]+)?(?:-[a-z0-9.-]+)?@sha256:[0-9a-f]{64}', image
        ):
            refuse()
        if not isinstance(roles, list) or not roles or any(
            role not in ('compatibility', 'decoder-source') for role in roles
        ) or len(set(roles)) != len(roles):
            refuse()
    generated = subprocess.run(
        ['elixir', sys.argv[2], '--lanes', str(root / 'mix.exs')],
        check=True, capture_output=True, text=True, timeout=30,
    )
    dependencies = json.loads(generated.stdout, object_pairs_hook=unique_object)
    keys = {'label', 'lockfile', 'ash_selector', 'ash_requirement', 'replicant_selector',
            'replicant_requirement', 'onetime_selector', 'onetime_requirement'}
    if not isinstance(dependencies, list) or len(dependencies) != 3:
        refuse()
    for row in dependencies:
        if not isinstance(row, dict) or set(row) != keys or any(not isinstance(value, str) for value in row.values()):
            refuse()
    if [row['label'] for row in dependencies] != ['exact-floors', 'current-lock', 'latest-compatible']:
        refuse()
    current = dependencies[1]
    compatibility = [dict(row, pg_major=engine_major, pg_image='') for row in dependencies] + [
        dict(current, label='current-lock-pg' + lane['major'], pg_major=lane['major'], pg_image=lane['image'])
        for lane in lanes if 'compatibility' in lane['roles']
    ]
    decoder = [dict(pg_major=lane['major'], base=lane['image'])
               for lane in lanes if 'decoder-source' in lane['roles']]
    if len(compatibility) == 3 or not decoder:
        refuse()
    checks = json.loads((root / 'scripts/qualification-jobs.json').read_text())
    if not isinstance(checks, list) or not checks or any(not isinstance(name, str) for name in checks):
        refuse()
    checks += ['qualification / Dependencies ' + row['label'] + ' / PostgreSQL ' + row['pg_major']
               for row in compatibility]
    checks += ['qualification / Plugin decoders / PostgreSQL ' + row['pg_major'] for row in decoder]
    if len(set(checks)) != len(checks):
        refuse()
    result = dict(engine_major=engine_major, compatibility=compatibility, decoder=decoder, checks=sorted(checks))
    print(json.dumps(result, separators=(',', ':')))
except (OSError, ValueError, TypeError, KeyError, subprocess.SubprocessError):
    sys.exit('PostgreSQL declarations are invalid')
PYTHON
)"
if [[ "$mode" == --json ]]; then
  printf '%s\n' "$result"
else
  for key in engine_major compatibility decoder; do
    value="$(jq -c --arg key "$key" '.[$key]' <<< "$result")"
    if [[ "$key" == engine_major ]]; then value="$(jq -r '.engine_major' <<< "$result")"; fi
    printf '%s=%s\n' "$key" "$value" >> "${GITHUB_OUTPUT:?}"
  done
fi
