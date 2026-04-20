#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

test_case "install.sh exists and is runnable bash"
[[ -f install.sh ]] && assert_eq "yes" "yes" "install.sh exists" \
  || assert_eq "yes" "no" "install.sh missing"
bash -n install.sh
assert_exit 0 $? "install.sh parses as bash"

# ---- Embed parity: install.sh must mirror the source-of-truth files ----

test_case "embedded JAILED_SCRIPT matches bin/jailed"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$JAILED_SCRIPT"')
actual=$(cat bin/jailed)
assert_eq "$actual" "$embedded" "embedded jailed diverged from bin/jailed"

test_case "embedded JAILED_HOOK_SCRIPT matches hooks/jailed-hook.sh"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$JAILED_HOOK_SCRIPT"')
actual=$(cat hooks/jailed-hook.sh)
assert_eq "$actual" "$embedded" "embedded hook diverged from hooks/jailed-hook.sh"

test_case "embedded DEFAULT_COMMANDS matches config/commands.default"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$DEFAULT_COMMANDS"')
actual=$(cat config/commands.default)
assert_eq "$actual" "$embedded" "embedded config diverged from config/commands.default"

test_case "embedded SRT_SETTINGS matches config/srt-settings.json"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$SRT_SETTINGS"')
actual=$(cat config/srt-settings.json)
assert_eq "$actual" "$embedded" "embedded SRT settings diverged from config/srt-settings.json"

# ---- CLI / help ----

test_case "--help prints usage"
out=$(bash install.sh --help 2>&1)
assert_contains "$out" "Usage:" "help output mentions Usage"
assert_contains "$out" "--uninstall" "help mentions --uninstall"

# ---- check_deps ----

test_case "check_deps passes when all tools present"
out=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; check_deps' 2>&1)
assert_exit 0 $? "check_deps exits 0 when tools present"

test_case "check_deps fails with helpful message when tools are missing"
out=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; PATH=/nonexistent check_deps' 2>&1 || true)
assert_contains "$out" "srt" "message mentions srt"
assert_contains "$out" "sandbox-runtime" "message points at the npm package"

# ---- install_bins ----

test_case "install_bins places jailed under \$PREFIX/bin"
tmp=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ -x "$tmp/bin/jailed" ]] && assert_eq "ok" "ok" "jailed installed and executable" \
  || assert_eq "ok" "missing" "jailed not executable or missing"

test_case "installed jailed actually runs"
# install_bins places binaries; SRT settings are a separate step, so pass
# them explicitly here to probe the binary in isolation.
out=$(echo hi | JAILED_SRT_SETTINGS="$PWD/config/srt-settings.json" \
  "$tmp/bin/jailed" python3 -c 'import sys; print(sys.stdin.read().strip())')
assert_eq "hi" "$out" "installed wrapper still functions"

test_case "install_bins is idempotent (second run no error)"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
assert_exit 0 $? "second install_bins must succeed"

test_case "install_bins removes legacy safe-python binaries on upgrade"
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho legacy\n' > "$tmp/bin/safe-python"
chmod 755 "$tmp/bin/safe-python"
ln -sf safe-python "$tmp/bin/safe-python3"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ ! -e "$tmp/bin/safe-python" ]]  && assert_eq "ok" "ok" "legacy safe-python removed" \
  || assert_eq "ok" "present" "legacy safe-python not cleaned up"
[[ ! -e "$tmp/bin/safe-python3" ]] && assert_eq "ok" "ok" "legacy safe-python3 removed" \
  || assert_eq "ok" "present" "legacy safe-python3 not cleaned up"
[[ -x "$tmp/bin/jailed" ]]  && assert_eq "ok" "ok" "jailed still in place" \
  || assert_eq "ok" "missing" "jailed missing after legacy cleanup"

test_case "install_bins removes legacy unjailed binary on upgrade"
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho legacy\n' > "$tmp/bin/unjailed"
chmod 755 "$tmp/bin/unjailed"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ ! -e "$tmp/bin/unjailed" ]] && assert_eq "ok" "ok" "legacy unjailed removed" \
  || assert_eq "ok" "present" "legacy unjailed not cleaned up"
[[ -x "$tmp/bin/jailed" ]] && assert_eq "ok" "ok" "jailed still in place" \
  || assert_eq "ok" "missing" "jailed missing after legacy cleanup"

rm -rf "$tmp"

# ---- install_hook ----

test_case "install_hook writes jailed-hook.sh into \$HOME/.claude/hooks/"
tmp_home=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_hook"
hook_path="$tmp_home/.claude/hooks/jailed-hook.sh"
[[ -x "$hook_path" ]] && assert_eq "ok" "ok" "new hook installed and executable" \
  || assert_eq "ok" "missing" "new hook missing or not executable"

test_case "installed hook rewrites python3 into jailed python3 (under staged ancestry)"
# The installed hook activates only when process ancestry shows it's running
# under `jailed claude`. Stage that via a fake `ps` first on PATH.
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
out=$(printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' | PATH="$stub_dir:$PATH" "$hook_path")
assert_contains "$out" '"permissionDecision": "allow"' "hook allows with rewrite"
assert_contains "$out" "jailed python3 -c 1" "command wrapped with jailed"
rm -rf "$stub_dir"

test_case "install_hook removes legacy python-nudge.sh on upgrade"
# Seed a legacy hook from a prior generation.
printf '#!/bin/sh\nexit 0\n' > "$tmp_home/.claude/hooks/python-nudge.sh"
chmod 755 "$tmp_home/.claude/hooks/python-nudge.sh"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_hook"
[[ ! -e "$tmp_home/.claude/hooks/python-nudge.sh" ]] \
  && assert_eq "ok" "ok" "legacy hook removed" \
  || assert_eq "ok" "present" "legacy python-nudge.sh not cleaned up"
[[ -x "$tmp_home/.claude/hooks/jailed-hook.sh" ]] \
  && assert_eq "ok" "ok" "new hook still in place" \
  || assert_eq "ok" "missing" "new hook missing after legacy cleanup"

rm -rf "$tmp_home"

# ---- install_config (commands list) ----

test_case "install_config writes default commands list when absent"
tmp_home=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_config"
cfg_path="$tmp_home/.config/jailed/commands"
[[ -f "$cfg_path" ]] && assert_eq "ok" "ok" "config installed" \
  || assert_eq "ok" "missing" "config missing"
assert_contains "$(cat "$cfg_path")" "python3" "config mentions python3"
assert_contains "$(cat "$cfg_path")" "jq" "config mentions jq"

test_case "install_config preserves a user-edited commands list"
# User narrows the list to just jq; installer must not overwrite.
printf '# custom\njq\n' > "$cfg_path"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_config"
result=$(cat "$cfg_path")
assert_eq "# custom
jq" "$result" "installer must never overwrite an existing user config"

rm -rf "$tmp_home"

# ---- install_srt_settings ----

test_case "install_srt_settings writes deny-all policy when absent"
tmp_home=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_srt_settings"
settings_path="$tmp_home/.config/jailed/srt-settings.json"
[[ -f "$settings_path" ]] && assert_eq "ok" "ok" "settings installed" \
  || assert_eq "ok" "missing" "settings missing"
jq -e '.filesystem.allowWrite == [] and .network.allowedDomains == []' "$settings_path" >/dev/null 2>&1
assert_exit 0 $? "default policy is deny-all (empty allow lists)"

test_case "install_srt_settings preserves a user-edited policy"
jq '.network.allowedDomains = ["example.com"]' "$settings_path" \
  > "$settings_path.tmp" && mv "$settings_path.tmp" "$settings_path"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_srt_settings"
result=$(jq -r '.network.allowedDomains[0]' "$settings_path")
assert_eq "example.com" "$result" "user-edited policy survived re-install"

rm -rf "$tmp_home"

# ---- merge_settings ----

test_case "merge_settings adds jailed allow rules + jailed-hook registration"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
echo '{}' > "$tmp_home/.claude/settings.json"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$result" "Bash(jailed:*)"         "generic allow rule present"
assert_contains "$result" "jailed-hook.sh"         "new hook registered"
assert_not_contains "$result" "python-nudge.sh"    "legacy hook NOT registered on fresh install"

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
assert_contains "$result" "Bash(ls:*)"       "existing allow rule preserved"
assert_contains "$result" "claude-opus-4-7"  "model preserved"
assert_contains "$result" "Bash(jailed:*)"   "new allow rule added"

test_case "merge_settings is idempotent (no duplicate entries)"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
count=$(echo "$result" | jq '[.permissions.allow[] | select(. == "Bash(jailed:*)")] | length')
assert_eq "1" "$count" "jailed allow rule deduped"
hook_count=$(echo "$result" | jq '.hooks.PreToolUse | length')
assert_eq "1" "$hook_count" "hook block deduped"

test_case "merge_settings strips legacy safe-python allow rules + legacy hook registration"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)", "Bash(safe-python:*)", "Bash(safe-python3:*)"] },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type":"command","command":"$HOME/.claude/hooks/python-nudge.sh"}]
    }]
  }
}
JSON
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$result" "Bash(safe-python" "legacy safe-python rules removed"
assert_not_contains "$result" "python-nudge.sh"   "legacy hook registration removed"
assert_contains "$result" "Bash(jailed:*)"       "new allow rule added"
assert_contains "$result" "jailed-hook.sh"       "new hook registered"
assert_contains "$result" "Bash(ls:*)"            "unrelated rule preserved"

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

# ---- strip_legacy_claude_md ----

test_case "strip_legacy_claude_md removes jailed-python:policy block"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# Keep me

<!-- jailed-python:policy:start -->
## Python execution policy
body
<!-- jailed-python:policy:end -->
MD
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' strip_legacy_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$result" "jailed-python:policy" "marker block removed"
assert_not_contains "$result" "Python execution policy" "block body removed"
assert_contains "$result" "Keep me" "unrelated content preserved"

test_case "strip_legacy_claude_md also removes safe-python + pupbox markers"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
<!-- safe-python:policy:start -->
old safe-python body
<!-- safe-python:policy:end -->

<!-- pupbox:python-policy:start -->
old pupbox body
<!-- pupbox:python-policy:end -->
MD
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' strip_legacy_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$result" "safe-python:policy"    "safe-python marker removed"
assert_not_contains "$result" "pupbox:python-policy"  "pupbox marker removed"
assert_not_contains "$result" "old safe-python body"  "safe-python body removed"
assert_not_contains "$result" "old pupbox body"       "pupbox body removed"

rm -rf "$tmp_home"

# ---- Full install ----

test_case "full install runs end-to-end under sandboxed HOME/PREFIX"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "installer exits 0"
[[ -x "$tmp_prefix/bin/jailed" ]] \
  && assert_eq "ok" "ok" "jailed placed"   || assert_eq "ok" "no" "jailed missing"
[[ -x "$tmp_home/.claude/hooks/jailed-hook.sh" ]] && assert_eq "ok" "ok" "hook placed" || assert_eq "ok" "no" "hook missing"
[[ -f "$tmp_home/.config/jailed/commands" ]] && assert_eq "ok" "ok" "commands config placed" || assert_eq "ok" "no" "commands config missing"
[[ -f "$tmp_home/.config/jailed/srt-settings.json" ]] && assert_eq "ok" "ok" "SRT settings placed" || assert_eq "ok" "no" "SRT settings missing"
assert_contains "$(cat "$tmp_home/.claude/settings.json")" "Bash(jailed:*)" "settings.json has new allow rule"

test_case "full install is idempotent"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "second run exits 0"
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(jailed:*)")] | length' "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "no duplicate allow rule"
hook_count=$(jq '.hooks.PreToolUse | length' "$tmp_home/.claude/settings.json")
assert_eq "1" "$hook_count" "no duplicate hook registration"

rm -rf "$tmp_home" "$tmp_prefix"

# ---- --uninstall ----

test_case "--uninstall removes binaries, hook, settings entries"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall
assert_exit 0 $? "uninstall exits 0"
[[ ! -e "$tmp_prefix/bin/jailed" ]] && assert_eq "ok" "ok" "jailed removed" \
  || assert_eq "ok" "no" "jailed still present"
[[ ! -e "$tmp_prefix/bin/unjailed" ]] && assert_eq "ok" "ok" "unjailed removed" \
  || assert_eq "ok" "no" "unjailed still present"
[[ ! -e "$tmp_home/.claude/hooks/jailed-hook.sh" ]] && assert_eq "ok" "ok" "new hook removed" || assert_eq "ok" "no" "new hook still present"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$settings" "Bash(jailed"   "jailed allow rules removed"
assert_not_contains "$settings" "jailed-hook.sh" "jailed-hook registration removed"

rm -rf "$tmp_home" "$tmp_prefix"

test_case "--uninstall strips all legacy generations (binaries + settings + markers)"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
# Seed a fully legacy pre-rename state.
mkdir -p "$tmp_prefix/bin" "$tmp_home/.claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$tmp_prefix/bin/safe-python"
chmod 755 "$tmp_prefix/bin/safe-python"
ln -sf safe-python "$tmp_prefix/bin/safe-python3"
printf '#!/bin/sh\nexit 0\n' > "$tmp_home/.claude/hooks/python-nudge.sh"
chmod 755 "$tmp_home/.claude/hooks/python-nudge.sh"
cat > "$tmp_home/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)", "Bash(safe-python:*)", "Bash(safe-python3:*)"] },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type":"command","command":"$HOME/.claude/hooks/python-nudge.sh"}]
    }]
  }
}
JSON
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# Keep me

<!-- safe-python:policy:start -->
old safe-python body
<!-- safe-python:policy:end -->
MD
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall >/dev/null
[[ ! -e "$tmp_prefix/bin/safe-python" ]]  && assert_eq "ok" "ok" "legacy safe-python binary removed"  || assert_eq "ok" "no" "legacy safe-python still present"
[[ ! -e "$tmp_prefix/bin/safe-python3" ]] && assert_eq "ok" "ok" "legacy safe-python3 binary removed" || assert_eq "ok" "no" "legacy safe-python3 still present"
[[ ! -e "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "legacy hook removed" || assert_eq "ok" "no" "legacy hook still present"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$settings" "Bash(safe-python" "legacy safe-python allow rules removed"
assert_not_contains "$settings" "python-nudge.sh"  "legacy hook registration removed"
assert_contains "$settings" "Bash(ls:*)" "unrelated rules preserved"
md=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$md" "safe-python:policy" "legacy marker block removed"
assert_not_contains "$md" "old safe-python body" "legacy block body removed"
assert_contains "$md" "Keep me" "unrelated prose preserved"

rm -rf "$tmp_home" "$tmp_prefix"

summary
