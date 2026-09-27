#!/usr/bin/env bash
# Run one test file in the foreground against the local Jac API.
# Usage: scripts/run_tests.sh tests/test_auth.py
set -a; . ./.env; set +a
export JAC_API_URL="${JAC_API_URL:-http://localhost:8001}"
start=$(date +%s)
.venv/bin/python -m pytest "$@" -q -p no:cacheprovider 2>&1 | grep -E "passed|failed|error|^FAILED|^E " | tail -15
echo "elapsed: $(( $(date +%s) - start ))s"
