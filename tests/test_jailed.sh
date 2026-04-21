#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

WRAPPER="bin/jailed"

test_case "jailed claude: stub claude sees 'jailed' as a real ancestor"
# Real invocation (no exec-a trickery): a claude stub walks its own process
# ancestry via /bin/ps and records the basename of each comm. For the hook's
# activation check to work in production, 'jailed' must appear in that chain.
# Regression test for two issues the hook design requires:
#   1. bin/jailed must not exec the claude target (exec destroys the parent).
#   2. The jailed process must identify itself as comm="jailed" so ps sees it.
anc_dir=$(make_tmp)
out_file="$anc_dir/chain.txt"
cat > "$anc_dir/claude" <<STUB
#!/usr/bin/env bash
pid=\$\$
> "$out_file"
while [[ -n "\$pid" && "\$pid" != "1" ]]; do
  line=\$(ps -o ppid=,comm= -p "\$pid" 2>/dev/null) || break
  [[ -z "\$line" ]] && break
  ppid=\$(echo "\$line" | awk '{print \$1}')
  comm=\$(echo "\$line" | awk '{print \$2}')
  basename -- "\$comm" >> "$out_file"
  pid=\$ppid
done
STUB
chmod 755 "$anc_dir/claude"
PATH="$anc_dir:$PATH" bash bin/jailed claude >/dev/null
if grep -Fxq "jailed" "$out_file"; then
  PASS_COUNT=$((PASS_COUNT+1))
else
  FAIL_COUNT=$((FAIL_COUNT+1))
  _red "  FAIL"; echo " no 'jailed' comm found in claude's real ancestor chain"
  echo "    chain:"
  sed 's/^/      /' "$out_file"
fi
rm -rf "$anc_dir"

test_case "jailed claude: skips SRT and execs claude directly"
# Stub both `claude` (to print a success sentinel) and `srt` (to print a
# sentinel we'd rather NOT see). If the special-case fires, `claude` runs
# and `srt` is never invoked. If it doesn't fire, `srt` gets called and
# its sentinel appears.
stub_dir=$(make_tmp)
cat > "$stub_dir/claude" <<'STUB'
#!/usr/bin/env bash
echo "CLAUDE_RAN argv=$*"
STUB
chmod 755 "$stub_dir/claude"
cat > "$stub_dir/srt" <<'STUB'
#!/usr/bin/env bash
echo "SRT_INVOKED args=$*"
STUB
chmod 755 "$stub_dir/srt"
out=$(PATH="$stub_dir:$PATH" JAILED_SRT_SETTINGS=/dev/null bash bin/jailed claude --foo bar 2>&1)
assert_contains "$out" "CLAUDE_RAN argv=--foo bar" "jailed claude execs claude directly"
assert_not_contains "$out" "SRT_INVOKED" "srt must not be invoked for the claude target"
rm -rf "$stub_dir"

test_case "jailed passes stdin to the target command and prints stdout"
result=$(echo "hello" | bash "$WRAPPER" python3 -c 'import sys; print(sys.stdin.read().strip().upper())')
assert_eq "HELLO" "$result" "uppercase of stdin via jailed python3"

test_case "jailed blocks outbound network for its target command"
result=$(bash "$WRAPPER" python3 -c '
import socket
try:
    socket.socket().connect(("1.1.1.1", 80))
    print("UNEXPECTED_SUCCESS")
except (OSError, PermissionError):
    print("BLOCKED")
' 2>&1)
assert_contains "$result" "BLOCKED" "network must be blocked"
assert_not_contains "$result" "UNEXPECTED_SUCCESS" "connect must not succeed"

test_case "jailed target cannot write outside the sandbox"
marker="/tmp/jailed-generic-test-$$.marker"
rm -f "$marker"
bash "$WRAPPER" python3 -c "open('$marker', 'w').write('x')" 2>/dev/null || true
if [[ -e "$marker" ]]; then
  rm -f "$marker"
  assert_eq "absent" "present" "sandbox leaked: marker was written to real /tmp"
else
  assert_eq "absent" "absent" "real /tmp unaffected by sandboxed write"
fi

test_case "jailed works with non-python target (jq stdlib example)"
# jq exists on CI + our dev boxes; use a trivial transform.
result=$(echo '{"x":1}' | bash "$WRAPPER" jq -c '.x')
assert_eq "1" "$result" "jailed can run non-python targets"

test_case "jailed forwards exit code from the target"
bash "$WRAPPER" python3 -c 'import sys; sys.exit(7)' 2>/dev/null
rc=$?
assert_exit 7 "$rc" "exit code propagated"

summary
