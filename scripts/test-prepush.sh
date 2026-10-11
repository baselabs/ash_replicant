#!/usr/bin/env bash
# Exercise the collector with real shell commands and their exit statuses.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status=0
bash -euo pipefail -c '
  source scripts/prepush.sh
  step "missing file" test -e "$1/missing"
  step "child failure" bash -e -c '\''false; touch "$1/unreachable"'\'' -- "$1"
  step "later check" touch "$1/later"
  skip "dependent check"
  report
' -- "$work" >"$work/failure.log" 2>&1 || status=$?
[[ "$status" -eq 1 ]]
[[ -f "$work/later" && ! -e "$work/unreachable" ]]
grep -Eq '^missing file +FAIL +1$' "$work/failure.log"
grep -Eq '^child failure +FAIL +1$' "$work/failure.log"
grep -Eq '^later check +PASS +0$' "$work/failure.log"
grep -Eq '^dependent check +SKIP +-$' "$work/failure.log"
grep -Fxq 'prepush: FAIL (2 failed checks)' "$work/failure.log"

bash -euo pipefail -c '
  source scripts/prepush.sh
  step "existing file" test -e "$1/later"
  report
' -- "$work" >"$work/success.log" 2>&1
grep -Eq '^existing file +PASS +0$' "$work/success.log"
grep -Fxq 'prepush: PASS' "$work/success.log"
echo 'prepush collector self-tests: PASS (failure, continuation, child failure, skip, success)'
