#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

HOOK="hooks/python-nudge.sh"

run_hook() {
  local cmd="$1"
  printf '%s' "{\"tool_input\":{\"command\":$(jq -Rn --arg c "$cmd" '$c')}}" \
    | bash "$HOOK"
}

test_case "fires on 'python3 -c'"
out=$(run_hook "python3 -c 'print(1)'")
assert_contains "$out" '"permissionDecision": "ask"' "must ask"
assert_contains "$out" "safe-python" "reason must mention safe-python"

test_case "fires on 'python -c' at start"
out=$(run_hook "python -c 'print(1)'")
assert_contains "$out" '"permissionDecision": "ask"' "must ask"

test_case "fires on python3 after a pipe"
out=$(run_hook "echo foo | python3 -c 'import sys; print(sys.stdin.read())'")
assert_contains "$out" '"permissionDecision": "ask"' "must ask for pipeline"

test_case "silent on safe-python"
out=$(run_hook "safe-python -c 'print(1)'")
assert_eq "" "$out" "must produce no output for safe-python"

test_case "silent on safe-python3"
out=$(run_hook "safe-python3 -c 'print(1)'")
assert_eq "" "$out" "must produce no output for safe-python3"

test_case "silent on pytest"
out=$(run_hook "pytest tests/")
assert_eq "" "$out" "must produce no output for pytest"

test_case "silent on python3.11 (version-suffixed binary)"
out=$(run_hook "python3.11 -c 'print(1)'")
assert_eq "" "$out" "should not fire on versioned binary (out of scope for v1)"

summary
