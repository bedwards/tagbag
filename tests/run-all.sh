#!/usr/bin/env bash
# tests/run-all.sh — Run all E2E tests in sequence
# Usage: ./tests/run-all.sh
# Requires: GITEA_TOKEN, PLANE_TOKEN env vars (or services will fail loudly)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0
TESTS_RUN=0
FAILED_TESTS=()

echo "========================================="
echo "  TagBag E2E Test Suite"
echo "========================================="
echo ""

# Collect all e2e test scripts
TESTS=("$SCRIPT_DIR"/e2e-*.sh)

if [[ ! -e "${TESTS[0]}" ]]; then
  echo "No E2E tests found in ${SCRIPT_DIR}"
  exit 1
fi

echo "Found ${#TESTS[@]} test(s):"
for t in "${TESTS[@]}"; do
  echo "  - $(basename "$t")"
done
echo ""

for test_script in "${TESTS[@]}"; do
  test_name="$(basename "$test_script")"
  TESTS_RUN=$((TESTS_RUN + 1))

  echo "========================================="
  echo "  Running: ${test_name}"
  echo "========================================="
  echo ""

  if bash "$test_script"; then
    TOTAL_PASS=$((TOTAL_PASS + 1))
    echo ""
    echo "  >> ${test_name}: PASSED"
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    FAILED_TESTS+=("$test_name")
    echo ""
    echo "  >> ${test_name}: FAILED"
  fi
  echo ""
done

echo "========================================="
echo "  Suite Summary"
echo "========================================="
echo "  Tests run:    ${TESTS_RUN}"
echo "  Tests passed: ${TOTAL_PASS}"
echo "  Tests failed: ${TOTAL_FAIL}"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
  echo ""
  echo "  Failed tests:"
  for ft in "${FAILED_TESTS[@]}"; do
    echo "    - ${ft}"
  done
fi
echo "========================================="
echo ""

if [ "$TOTAL_FAIL" -gt 0 ]; then
  exit 1
fi
