#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

test_case "install.sh exists and is runnable bash"
[[ -f install.sh ]] && assert_eq "yes" "yes" "install.sh exists" \
  || assert_eq "yes" "no" "install.sh missing"
bash -n install.sh
assert_exit 0 $? "install.sh parses as bash"

test_case "embedded JAILED_SCRIPT matches bin/jailed"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$JAILED_SCRIPT"')
actual=$(cat bin/jailed)
assert_eq "$actual" "$embedded" "embedded jailed diverged from bin/jailed"

test_case "embedded JAILED_PYTHON_SCRIPT matches bin/jailed-python"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$JAILED_PYTHON_SCRIPT"')
actual=$(cat bin/jailed-python)
assert_eq "$actual" "$embedded" "embedded wrapper diverged from bin/jailed-python"

test_case "embedded PYTHON_NUDGE_SCRIPT matches hooks/python-nudge.sh"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$PYTHON_NUDGE_SCRIPT"')
actual=$(cat hooks/python-nudge.sh)
assert_eq "$actual" "$embedded" "embedded hook diverged from hooks/python-nudge.sh"

test_case "--help prints usage"
out=$(bash install.sh --help 2>&1)
assert_contains "$out" "Usage:" "help output mentions Usage"
assert_contains "$out" "--uninstall" "help mentions --uninstall"

test_case "check_deps passes when all tools present"
out=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; check_deps' 2>&1)
assert_exit 0 $? "check_deps exits 0 when tools present"

test_case "check_deps fails with helpful message when a tool is missing"
out=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; PATH=/nonexistent check_deps' 2>&1 || true)
assert_contains "$out" "bwrap" "message mentions bwrap"
assert_contains "$out" "apt" "message includes apt hint"

test_case "install_bins places jailed, jailed-python and jailed-python3 under \$PREFIX/bin"
tmp=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ -x "$tmp/bin/jailed" ]] && assert_eq "ok" "ok" "jailed installed and executable" \
  || assert_eq "ok" "missing" "jailed not executable or missing"
[[ -x "$tmp/bin/jailed-python" ]] && assert_eq "ok" "ok" "jailed-python installed and executable" \
  || assert_eq "ok" "missing" "jailed-python not executable or missing"
[[ -L "$tmp/bin/jailed-python3" || -x "$tmp/bin/jailed-python3" ]] \
  && assert_eq "ok" "ok" "jailed-python3 present" \
  || assert_eq "ok" "missing" "jailed-python3 not present"

test_case "installed jailed-python actually runs"
# install_bins only places binaries; SRT settings are installed separately,
# so pass the repo-local settings explicitly to probe the binary in isolation.
out=$(echo hi | JAILED_SRT_SETTINGS="$PWD/config/srt-settings.json" \
  "$tmp/bin/jailed-python" -c 'import sys; print(sys.stdin.read().strip())')
assert_eq "hi" "$out" "installed wrapper still functions"

test_case "install_bins is idempotent (second run no error)"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
assert_exit 0 $? "second install_bins must succeed"

test_case "install_bins removes legacy safe-python binaries on upgrade"
# Seed a prior-generation install: both safe-python and safe-python3 present.
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho legacy\n' > "$tmp/bin/safe-python"
chmod 755 "$tmp/bin/safe-python"
ln -sf safe-python "$tmp/bin/safe-python3"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ ! -e "$tmp/bin/safe-python" ]]  && assert_eq "ok" "ok" "legacy safe-python removed" \
  || assert_eq "ok" "present" "legacy safe-python not cleaned up"
[[ ! -e "$tmp/bin/safe-python3" ]] && assert_eq "ok" "ok" "legacy safe-python3 removed" \
  || assert_eq "ok" "present" "legacy safe-python3 not cleaned up"
[[ -x "$tmp/bin/jailed-python" ]]  && assert_eq "ok" "ok" "jailed-python still in place" \
  || assert_eq "ok" "missing" "jailed-python missing after legacy cleanup"

rm -rf "$tmp"

test_case "install_hook writes hook into \$HOME/.claude/hooks/"
tmp_home=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_hook"
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
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$result" "Bash(jailed-python:*)" "allow rule present"
assert_contains "$result" "Bash(jailed-python3:*)" "allow rule present"
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
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$result" "Bash(ls:*)" "existing allow rule preserved"
assert_contains "$result" "claude-opus-4-7" "model preserved"
assert_contains "$result" "Bash(jailed-python:*)" "new allow rule added"

test_case "merge_settings is idempotent (no duplicate entries)"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
count=$(echo "$result" | jq '[.permissions.allow[] | select(. == "Bash(jailed-python:*)")] | length')
assert_eq "1" "$count" "jailed-python allow rule deduped"
hook_count=$(echo "$result" | jq '.hooks.PreToolUse | length')
assert_eq "1" "$hook_count" "hook block deduped"

test_case "merge_settings strips legacy safe-python allow rules on upgrade"
# A pre-rename settings.json has Bash(safe-python:*) rules. After merge,
# those should be gone and replaced by jailed-python rules — otherwise the
# user ends up with both generations side by side.
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)", "Bash(safe-python:*)", "Bash(safe-python3:*)"] }
}
JSON
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
legacy_count=$(echo "$result" | jq '[.permissions.allow[] | select(. == "Bash(safe-python:*)" or . == "Bash(safe-python3:*)")] | length')
assert_eq "0" "$legacy_count" "legacy safe-python rules removed"
new_count=$(echo "$result" | jq '[.permissions.allow[] | select(. == "Bash(jailed-python:*)")] | length')
assert_eq "1" "$new_count" "jailed-python rule added exactly once"
assert_contains "$result" "Bash(ls:*)" "unrelated allow rule preserved"

test_case "merge_settings creates .bak on first run, not on second"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
echo '{"_v":1}' > "$tmp_home/.claude/settings.json"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
[[ -f "$tmp_home/.claude/settings.json.bak" ]] && assert_eq "ok" "ok" "backup created" \
  || assert_eq "ok" "missing" "backup not created on first run"
jq '._v = 99' "$tmp_home/.claude/settings.json.bak" > "$tmp_home/.claude/settings.json.bak.tmp" \
  && mv "$tmp_home/.claude/settings.json.bak.tmp" "$tmp_home/.claude/settings.json.bak"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
bak_v=$(jq -r '._v' "$tmp_home/.claude/settings.json.bak")
assert_eq "99" "$bak_v" "second run must not overwrite .bak"

rm -rf "$tmp_home"

test_case "upsert_claude_md adds policy block to empty file"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
: > "$tmp_home/.claude/CLAUDE.md"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_contains "$result" "jailed-python:policy:start" "start marker"
assert_contains "$result" "jailed-python:policy:end" "end marker"
assert_contains "$result" "jailed-python" "block content present"

test_case "upsert_claude_md preserves existing unrelated content"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# My personal prefs

- never use emojis
MD
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_contains "$result" "never use emojis" "original content preserved"
assert_contains "$result" "Python execution policy" "policy added"

test_case "upsert_claude_md is idempotent"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
count=$(grep -c "jailed-python:policy:start" <<< "$result")
assert_eq "1" "$count" "policy block not duplicated"

test_case "upsert_claude_md replaces old content inside markers"
python3 -c "
import re
p = '$tmp_home/.claude/CLAUDE.md'
with open(p) as f: s = f.read()
s = re.sub(r'(jailed-python:policy:start -->).*?(<!-- jailed-python:policy:end)',
          r'\1\nCORRUPTED\n\2', s, flags=re.DOTALL)
with open(p, 'w') as f: f.write(s)
"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$result" "CORRUPTED" "corrupted content replaced"
assert_contains "$result" "Decision rule" "correct content restored"

rm -rf "$tmp_home"

test_case "upsert_claude_md migrates legacy pupbox:python-policy markers"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# User notes

- keep tests green

<!-- pupbox:python-policy:start -->
## Python execution policy

Stale pre-rename content the installer should replace.
<!-- pupbox:python-policy:end -->
MD
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$result" "pupbox:python-policy" "legacy markers removed on upgrade"
assert_not_contains "$result" "Stale pre-rename content" "legacy block body removed"
assert_contains "$result" "keep tests green" "unrelated content preserved"
new_count=$(grep -c "jailed-python:policy:start" <<< "$result")
assert_eq "1" "$new_count" "exactly one new policy block written"

rm -rf "$tmp_home"

test_case "upsert_claude_md migrates legacy safe-python:policy markers"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# User notes

<!-- safe-python:policy:start -->
## Python execution policy

Stale safe-python content.
<!-- safe-python:policy:end -->
MD
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$result" "safe-python:policy" "legacy safe-python markers removed"
assert_not_contains "$result" "Stale safe-python content" "legacy safe-python body removed"
new_count=$(grep -c "jailed-python:policy:start" <<< "$result")
assert_eq "1" "$new_count" "exactly one new policy block written"

rm -rf "$tmp_home"

test_case "full install runs all steps under a sandboxed HOME/PREFIX"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "installer exits 0"
[[ -x "$tmp_prefix/bin/jailed" ]]         && assert_eq "ok" "ok" "jailed placed"         || assert_eq "ok" "no" "jailed missing"
[[ -x "$tmp_prefix/bin/jailed-python" ]]  && assert_eq "ok" "ok" "jailed-python placed"   || assert_eq "ok" "no" "jailed-python missing"
[[ -x "$tmp_prefix/bin/jailed-python3" ]] && assert_eq "ok" "ok" "jailed-python3 placed"  || assert_eq "ok" "no" "jailed-python3 missing"
[[ -x "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "hook placed" || assert_eq "ok" "no" "hook missing"
assert_contains "$(cat "$tmp_home/.claude/settings.json")" "jailed-python" "settings.json updated"
assert_contains "$(cat "$tmp_home/.claude/CLAUDE.md")" "Python execution policy" "CLAUDE.md updated"

test_case "full install is idempotent (second run zero errors, no dupes)"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "second run exits 0"
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(jailed-python:*)")] | length' "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "no duplicate allow rule"
md_count=$(grep -c "jailed-python:policy:start" "$tmp_home/.claude/CLAUDE.md")
assert_eq "1" "$md_count" "no duplicate policy block"

rm -rf "$tmp_home" "$tmp_prefix"

test_case "--uninstall removes binaries, hook, settings entries, and CLAUDE.md block"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall
assert_exit 0 $? "uninstall exits 0"
[[ ! -e "$tmp_prefix/bin/jailed" ]]         && assert_eq "ok" "ok" "jailed removed"           || assert_eq "ok" "no" "jailed still present"
[[ ! -e "$tmp_prefix/bin/jailed-python" ]]  && assert_eq "ok" "ok" "jailed-python removed"   || assert_eq "ok" "no" "jailed-python still present"
[[ ! -e "$tmp_prefix/bin/jailed-python3" ]] && assert_eq "ok" "ok" "jailed-python3 removed"  || assert_eq "ok" "no" "jailed-python3 still present"
[[ ! -e "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "hook removed" || assert_eq "ok" "no" "hook still present"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$settings" "jailed-python" "allow rules removed"
assert_not_contains "$settings" "python-nudge.sh" "hook registration removed"
md=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$md" "jailed-python:policy:start" "policy block removed"

rm -rf "$tmp_home" "$tmp_prefix"

test_case "--uninstall also strips legacy pupbox:python-policy block"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# Keep me

<!-- pupbox:python-policy:start -->
legacy body
<!-- pupbox:python-policy:end -->
MD
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall >/dev/null
md=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$md" "pupbox:python-policy" "legacy markers removed by uninstall"
assert_not_contains "$md" "legacy body" "legacy block body removed by uninstall"
assert_contains "$md" "Keep me" "unrelated content preserved through uninstall"

rm -rf "$tmp_home" "$tmp_prefix"

test_case "--uninstall removes legacy safe-python binaries + allow rules"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
# Seed pre-rename state: safe-python binaries, safe-python allow rules,
# safe-python:policy block in CLAUDE.md.
mkdir -p "$tmp_prefix/bin" "$tmp_home/.claude"
printf '#!/bin/sh\nexit 0\n' > "$tmp_prefix/bin/safe-python"
chmod 755 "$tmp_prefix/bin/safe-python"
ln -sf safe-python "$tmp_prefix/bin/safe-python3"
cat > "$tmp_home/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)", "Bash(safe-python:*)", "Bash(safe-python3:*)"] }
}
JSON
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
<!-- safe-python:policy:start -->
old policy
<!-- safe-python:policy:end -->
MD
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall >/dev/null
[[ ! -e "$tmp_prefix/bin/safe-python" ]]  && assert_eq "ok" "ok" "legacy safe-python binary removed"  || assert_eq "ok" "no" "legacy safe-python still present"
[[ ! -e "$tmp_prefix/bin/safe-python3" ]] && assert_eq "ok" "ok" "legacy safe-python3 binary removed" || assert_eq "ok" "no" "legacy safe-python3 still present"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$settings" "Bash(safe-python" "legacy safe-python allow rules removed"
assert_contains "$settings" "Bash(ls:*)" "unrelated allow rule preserved"
md=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$md" "safe-python:policy" "legacy safe-python markers removed"

rm -rf "$tmp_home" "$tmp_prefix"

summary
