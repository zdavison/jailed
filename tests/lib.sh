#!/usr/bin/env bash
# Minimal test helpers. Source from test scripts.

set -u
FAIL_COUNT=0
PASS_COUNT=0
CURRENT_TEST=""

_red()   { printf '\033[31m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }

test_case() {
  CURRENT_TEST="$1"
  echo "• $CURRENT_TEST"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-}"
  if [[ "$expected" == "$actual" ]]; then
    PASS_COUNT=$((PASS_COUNT+1))
  else
    FAIL_COUNT=$((FAIL_COUNT+1))
    _red "  FAIL"; echo " $msg"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$((PASS_COUNT+1))
  else
    FAIL_COUNT=$((FAIL_COUNT+1))
    _red "  FAIL"; echo " $msg"
    echo "    needle:   $needle"
    echo "    haystack: $haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-}"
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$((PASS_COUNT+1))
  else
    FAIL_COUNT=$((FAIL_COUNT+1))
    _red "  FAIL"; echo " $msg"
    echo "    unexpected needle: $needle"
  fi
}

assert_exit() {
  local expected="$1" actual="$2" msg="${3:-}"
  assert_eq "$expected" "$actual" "$msg (exit code)"
}

summary() {
  echo
  if (( FAIL_COUNT == 0 )); then
    _green "PASS"; echo " $PASS_COUNT assertions"
    exit 0
  else
    _red "FAIL"; echo " $FAIL_COUNT failed, $PASS_COUNT passed"
    exit 1
  fi
}

make_tmp() {
  local dir
  dir=$(mktemp -d -t jailed-test.XXXXXX)
  echo "$dir"
}
