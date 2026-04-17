#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

WRAPPER="bin/safe-python"

test_case "wrapper passes stdin to python and prints stdout"
result=$(echo "hello" | bash "$WRAPPER" -c 'import sys; print(sys.stdin.read().strip().upper())')
assert_eq "HELLO" "$result" "uppercase of stdin"

test_case "wrapper blocks outbound network (socket.connect fails)"
result=$(bash "$WRAPPER" -c '
import socket
try:
    socket.socket().connect(("1.1.1.1", 80))
    print("UNEXPECTED_SUCCESS")
except (OSError, PermissionError) as e:
    print("BLOCKED")
' 2>&1)
assert_contains "$result" "BLOCKED" "network must be blocked"
assert_not_contains "$result" "UNEXPECTED_SUCCESS" "connect must not succeed"

test_case "wrapper cannot write outside the sandbox"
marker="/tmp/pupbox-wrapper-test-$$.marker"
rm -f "$marker"
bash "$WRAPPER" -c "open('$marker', 'w').write('x')" 2>/dev/null || true
if [[ -e "$marker" ]]; then
  rm -f "$marker"
  assert_eq "absent" "present" "sandbox leaked: marker was written to real /tmp"
else
  assert_eq "absent" "absent" "real /tmp unaffected by sandboxed write"
fi

test_case "wrapper can import stdlib (json)"
result=$(bash "$WRAPPER" -c 'import json; print(json.dumps({"ok": 1}))')
assert_eq '{"ok": 1}' "$result" "json stdlib import works"

summary
