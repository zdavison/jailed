#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

HOOK="hooks/jailed-hook.sh"
CFG_DIR=$(make_tmp)
CFG="$CFG_DIR/commands"
cat > "$CFG" <<'EOF'
# Test config — keep this list minimal so we don't accidentally match
# unrelated words in command strings.
python3
python
jq
EOF

STAGED_PS_DIR=$(make_tmp)
cat > "$STAGED_PS_DIR/ps" <<'PS_EOF'
#!/usr/bin/env bash
# Fake ps: always report the caller's pid as claude-under-jailed so the
# hook activates. This isolates test_hook.sh to rewriter behavior.
pid=""
while (( $# )); do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# Synthetic chain: pid=claude, ppid=9999=jailed, pppid=1.
case "$pid" in
  9999) echo "1 jailed" ;;
  *)    echo "9999 claude" ;;
esac
PS_EOF
chmod 755 "$STAGED_PS_DIR/ps"

run_hook() {
  local cmd="$1"
  # JAILED_CONFIG goes on the consuming side of the pipe so it's visible
  # to the hook — a bare `JAILED_CONFIG=… printf | bash hook` would only
  # scope the env var to printf and the hook would fall back to defaults.
  printf '%s' "{\"tool_input\":{\"command\":$(jq -Rn --arg c "$cmd" '$c')}}" \
    | PATH="$STAGED_PS_DIR:$PATH" JAILED_CONFIG="$CFG" bash "$HOOK"
}

# ---- Rewrite happy paths ----

test_case "rewrites 'python3 -c' at start of command"
out=$(run_hook "python3 -c 'print(1)'")
assert_contains "$out" '"permissionDecision": "allow"' "should allow (not ask)"
assert_contains "$out" '"updatedInput"' "must emit updatedInput"
assert_contains "$out" "jailed python3 -c 'print(1)'" "command wrapped with jailed"

test_case "rewrites python3 after a pipe"
out=$(run_hook "echo foo | python3 -c 'import sys; print(sys.stdin.read())'")
assert_contains "$out" "echo foo | jailed python3 -c" "rewrite preserves pipeline structure"

test_case "rewrites python3 after &&"
out=$(run_hook "mkdir -p out && python3 script.py")
assert_contains "$out" "mkdir -p out && jailed python3 script.py" "rewrite handles &&"

test_case "rewrites python3 inside \$( … )"
out=$(run_hook 'result=$(python3 -c "print(1)")')
# Interior double quotes are JSON-escaped in the hook's stdout.
assert_contains "$out" 'result=$(jailed python3 -c \"print(1)\")' "rewrite handles subshell"

test_case "rewrites multiple occurrences"
out=$(run_hook "python3 a.py && python3 b.py")
# Count occurrences of 'jailed python3'
count=$(grep -o "jailed python3" <<< "$out" | wc -l | tr -d ' ')
assert_eq "2" "$count" "both python3 invocations rewritten"

test_case "rewrites different listed commands"
out=$(run_hook "cat file.json | jq '.x'")
assert_contains "$out" "cat file.json | jailed jq '.x'" "jq is also rewritten"

# ---- Pass-through cases ----

test_case "silent when command is not listed"
out=$(run_hook "ls -la")
assert_eq "" "$out" "no output for un-listed commands"

test_case "silent when python3 is already jailed"
out=$(run_hook "jailed python3 -c 'print(1)'")
assert_eq "" "$out" "do not double-jail"

test_case "silent on version-suffixed binaries (python3.11)"
out=$(run_hook "python3.11 -c 'print(1)'")
assert_eq "" "$out" "out of scope: version-suffixed binaries"

test_case "silent on commands that start with listed prefix"
out=$(run_hook "python3script.sh")
assert_eq "" "$out" "must respect word boundary, not substring"

# ---- Config semantics ----

test_case "falls back to built-in defaults when no config file is set"
out=$(printf '%s' \
  "{\"tool_input\":{\"command\":\"python3 -c 1\"}}" | PATH="$STAGED_PS_DIR:$PATH" JAILED_CONFIG=/nonexistent/path bash "$HOOK")
assert_contains "$out" "jailed python3 -c 1" "built-in defaults still catch python3"

test_case "user can narrow the list by editing the config"
narrow_cfg="$CFG_DIR/narrow"
printf 'jq\n' > "$narrow_cfg"
out=$(printf '%s' \
  "{\"tool_input\":{\"command\":\"python3 -c 1\"}}" | PATH="$STAGED_PS_DIR:$PATH" JAILED_CONFIG="$narrow_cfg" bash "$HOOK")
assert_eq "" "$out" "python3 no longer rewritten when removed from config"

out=$(printf '%s' \
  "{\"tool_input\":{\"command\":\"cat | jq .\"}}" | PATH="$STAGED_PS_DIR:$PATH" JAILED_CONFIG="$narrow_cfg" bash "$HOOK")
assert_contains "$out" "cat | jailed jq ." "jq still rewritten (still in config)"

test_case "additionalContext is included so Claude sees why"
out=$(run_hook "python3 -c 'print(1)'")
assert_contains "$out" '"additionalContext"' "must include additionalContext"
assert_contains "$out" "jailed" "additionalContext mentions jailed"

rm -rf "$CFG_DIR" "$STAGED_PS_DIR"
summary
