#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

test_case "install.sh exists and is runnable bash"
[[ -f install.sh ]] && assert_eq "yes" "yes" "install.sh exists" \
  || assert_eq "yes" "no" "install.sh missing"
bash -n install.sh
assert_exit 0 $? "install.sh parses as bash"

test_case "embedded SAFE_PYTHON_SCRIPT matches bin/safe-python"
embedded=$(PUPBOX_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$SAFE_PYTHON_SCRIPT"')
actual=$(cat bin/safe-python)
assert_eq "$actual" "$embedded" "embedded wrapper diverged from bin/safe-python"

test_case "embedded PYTHON_NUDGE_SCRIPT matches hooks/python-nudge.sh"
embedded=$(PUPBOX_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$PYTHON_NUDGE_SCRIPT"')
actual=$(cat hooks/python-nudge.sh)
assert_eq "$actual" "$embedded" "embedded hook diverged from hooks/python-nudge.sh"

test_case "--help prints usage"
out=$(bash install.sh --help 2>&1)
assert_contains "$out" "Usage:" "help output mentions Usage"
assert_contains "$out" "--uninstall" "help mentions --uninstall"

test_case "check_deps passes when all tools present"
out=$(PUPBOX_LIB_ONLY=1 bash -c 'source install.sh; check_deps' 2>&1)
assert_exit 0 $? "check_deps exits 0 when tools present"

test_case "check_deps fails with helpful message when a tool is missing"
out=$(PUPBOX_LIB_ONLY=1 bash -c 'source install.sh; PATH=/nonexistent check_deps' 2>&1 || true)
assert_contains "$out" "bwrap" "message mentions bwrap"
assert_contains "$out" "apt" "message includes apt hint"

test_case "install_bins places safe-python and safe-python3 under \$PREFIX/bin"
tmp=$(make_tmp)
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ -x "$tmp/bin/safe-python" ]] && assert_eq "ok" "ok" "safe-python installed and executable" \
  || assert_eq "ok" "missing" "safe-python not executable or missing"
[[ -L "$tmp/bin/safe-python3" || -x "$tmp/bin/safe-python3" ]] \
  && assert_eq "ok" "ok" "safe-python3 present" \
  || assert_eq "ok" "missing" "safe-python3 not present"

test_case "installed safe-python actually runs"
out=$(echo hi | "$tmp/bin/safe-python" -c 'import sys; print(sys.stdin.read().strip())')
assert_eq "hi" "$out" "installed wrapper still functions"

test_case "install_bins is idempotent (second run no error)"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
assert_exit 0 $? "second install_bins must succeed"

rm -rf "$tmp"

test_case "install_hook writes hook into \$HOME/.claude/hooks/"
tmp_home=$(make_tmp)
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_hook"
hook_path="$tmp_home/.claude/hooks/python-nudge.sh"
[[ -x "$hook_path" ]] && assert_eq "ok" "ok" "hook installed and executable" \
  || assert_eq "ok" "missing" "hook missing or not executable"

test_case "installed hook emits ask JSON for python3"
out=$(printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' | "$hook_path")
assert_contains "$out" '"permissionDecision": "ask"' "hook works end-to-end"

rm -rf "$tmp_home"

test_case "merge_settings adds allow rules and hook to empty settings.json"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
echo '{}' > "$tmp_home/.claude/settings.json"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$result" "Bash(safe-python:*)" "allow rule present"
assert_contains "$result" "Bash(safe-python3:*)" "allow rule present"
assert_contains "$result" "python-nudge.sh" "hook registered"

test_case "merge_settings preserves unrelated existing config"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)"] },
  "model": "claude-opus-4-7"
}
JSON
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$result" "Bash(ls:*)" "existing allow rule preserved"
assert_contains "$result" "claude-opus-4-7" "model preserved"
assert_contains "$result" "Bash(safe-python:*)" "new allow rule added"

test_case "merge_settings is idempotent (no duplicate entries)"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
count=$(echo "$result" | jq '[.permissions.allow[] | select(. == "Bash(safe-python:*)")] | length')
assert_eq "1" "$count" "safe-python allow rule deduped"
hook_count=$(echo "$result" | jq '.hooks.PreToolUse | length')
assert_eq "1" "$hook_count" "hook block deduped"

test_case "merge_settings creates .bak on first run, not on second"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
echo '{"_v":1}' > "$tmp_home/.claude/settings.json"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
[[ -f "$tmp_home/.claude/settings.json.bak" ]] && assert_eq "ok" "ok" "backup created" \
  || assert_eq "ok" "missing" "backup not created on first run"
jq '._v = 99' "$tmp_home/.claude/settings.json.bak" > "$tmp_home/.claude/settings.json.bak.tmp" \
  && mv "$tmp_home/.claude/settings.json.bak.tmp" "$tmp_home/.claude/settings.json.bak"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
bak_v=$(jq -r '._v' "$tmp_home/.claude/settings.json.bak")
assert_eq "99" "$bak_v" "second run must not overwrite .bak"

rm -rf "$tmp_home"

summary
