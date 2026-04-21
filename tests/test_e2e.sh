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

test_case "installed hook rewrites python3 tool-input to jailed python3 (under staged ancestry)"
hook="$tmp_home/.claude/hooks/jailed-hook.sh"
stub_dir=$(make_tmp)
cat > "$stub_dir/ps" <<'PS_EOF'
#!/usr/bin/env bash
pid=""
while (( $# )); do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
case "$pid" in
  9999) echo "1 jailed" ;;
  *)    echo "9999 claude" ;;
esac
PS_EOF
chmod 755 "$stub_dir/ps"
out=$(printf '%s' '{"tool_input":{"command":"python3 -c \"print(1)\""}}' \
  | PATH="$stub_dir:$PATH" JAILED_CONFIG="$tmp_home/.config/jailed/commands" bash "$hook")
assert_contains "$out" '"permissionDecision": "allow"' "hook allows with rewrite"
assert_contains "$out" '"updatedInput"' "updatedInput field present"
assert_contains "$out" 'jailed python3 -c' "command wrapped with jailed"
rm -rf "$stub_dir"

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

test_case "real-chain: jailed claude ancestry → hook activates"
hook="$tmp_home/.claude/hooks/jailed-hook.sh"
cfg="$tmp_home/.config/jailed/commands"
runner=$(make_tmp)/runner.sh
cat > "$runner" <<RUNNER_EOF
#!/usr/bin/env bash
printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' \
  | JAILED_CONFIG="$cfg" bash "$hook"
RUNNER_EOF
chmod 755 "$runner"

# Process tree: jailed-bash → claude-bash → bash(runner) → hook.
# `exec -a <name>` sets argv[0], which is what ps reports as comm.
out=$(
  ( exec -a jailed bash -c "( exec -a claude bash \"$runner\" )" )
)
assert_contains "$out" "jailed python3 -c 1" "ancestry jailed→claude activates hook"

test_case "real-chain: plain claude ancestry → hook stands down"
out=$(
  ( exec -a claude bash "$runner" )
)
assert_eq "" "$out" "no jailed parent → hook silent"

test_case "real-chain: nested claude under jailed claude → hook activates"
# Inner claude spawned without any magic env var — just a chain:
# jailed → claude → bash → claude → bash(runner) → hook.
out=$(
  ( exec -a jailed bash -c "
      ( exec -a claude bash -c \"
          ( exec -a claude bash \\\"$runner\\\" )
        \" )
    "
  )
)
assert_contains "$out" "jailed python3 -c 1" "inner claude under jailed outer activates"

summary
