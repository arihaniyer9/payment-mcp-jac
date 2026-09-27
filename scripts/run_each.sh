#!/usr/bin/env bash
# Run every test function in the given files ONE AT A TIME (pytest node ids),
# so a slow host can never lose a whole file's results. Prints one line per test
# and a total. Optional: PER_TEST_TIMEOUT (seconds, default 300).
# Usage: bash scripts/run_each.sh tests/test_phase4.py [more files...]
set -a; . ./.env; set +a
export JAC_API_URL="${JAC_API_URL:-http://localhost:8001}"
T="${PER_TEST_TIMEOUT:-300}"
pass=0; fail=0; failed=()
for id in $(.venv/bin/python -m pytest "$@" --collect-only -q -p no:cacheprovider 2>/dev/null | grep "::"); do
  start=$(date +%s)
  out=$(timeout "$T" .venv/bin/python -m pytest "$id" -q -p no:cacheprovider 2>&1 | tail -1)
  secs=$(( $(date +%s) - start ))
  if echo "$out" | grep -qE "^[0-9]+ passed"; then
    pass=$((pass+1)); echo "PASS ${secs}s $id"
  else
    fail=$((fail+1)); failed+=("$id"); echo "FAIL ${secs}s $id :: ${out:0:160}"
  fi
done
echo "TOTAL: $pass passed, $fail failed"
for f in "${failed[@]}"; do echo "  failed: $f"; done
