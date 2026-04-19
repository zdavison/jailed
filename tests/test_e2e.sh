#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
trap 'rm -rf "$tmp_home" "$tmp_prefix"' EXIT

HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null

test_case "install then run a pipeline through jailed"
# HOME override so the wrapper resolves SRT settings from our sandboxed
# install tree ($tmp_home/.config/jailed/srt-settings.json), not the real $HOME.
out=$(echo '<a href=hello>' | HOME="$tmp_home" "$tmp_prefix/bin/jailed" python3 -c '
import sys, re
html = sys.stdin.read()
m = re.search(r"href=(\S+?)>", html)
print(m.group(1) if m else "none")
')
assert_eq "hello" "$out" "end-to-end: jailed python3 pipeline works"

test_case "installed hook rewrites python3 tool-input to jailed python3"
hook="$tmp_home/.claude/hooks/jailed-hook.sh"
out=$(printf '%s' '{"tool_input":{"command":"python3 -c \"print(1)\""}}' \
  | JAILED_CONFIG="$tmp_home/.config/jailed/commands" bash "$hook")
assert_contains "$out" '"permissionDecision": "allow"' "hook allows with rewrite"
assert_contains "$out" '"updatedInput"' "updatedInput field present"
assert_contains "$out" 'jailed python3 -c' "command wrapped with jailed"

test_case "installed hook stays silent on an already-jailed command"
out=$(printf '%s' '{"tool_input":{"command":"jailed python3 -c \"print(1)\""}}' \
  | JAILED_CONFIG="$tmp_home/.config/jailed/commands" bash "$hook")
assert_eq "" "$out" "no double-jail"

test_case "settings.json has new allow rules + hook registration"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$settings" '"Bash(jailed:*)"'         "generic allow rule"
assert_contains "$settings" "jailed-hook.sh"           "new hook registered"
assert_not_contains "$settings" "python-nudge.sh"      "legacy hook NOT registered"

test_case "second install keeps things stable"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(jailed:*)")] | length' \
              "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "no duplicate allow"
hook_count=$(jq '.hooks.PreToolUse | length' "$tmp_home/.claude/settings.json")
assert_eq "1" "$hook_count" "no duplicate hook registration"

test_case "installed unjailed exports UNJAILED=1 to child env"
out=$(env -u UNJAILED "$tmp_prefix/bin/unjailed" env | grep '^UNJAILED=' || true)
assert_eq "UNJAILED=1" "$out" "installed unjailed must export UNJAILED=1"

test_case "installed unjailed with zero args exits 2 with usage"
set +e
out=$("$tmp_prefix/bin/unjailed" 2>&1); rc=$?
set -e
assert_contains "$out" "usage: unjailed" "usage text shown"
assert_eq "2" "$rc" "exit code 2"

summary
