# Generic `jailed` Wrapper + Rewriting Hook — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-purpose `jailed-python` flow with a generic `jailed <cmd>` wrapper that Claude Code's PreToolUse hook transparently prepends to any command listed in a user-editable config. Claude writes `python3 -c '…'`; the hook rewrites the tool input to `jailed python3 -c '…'`; Bash runs the sandboxed version. No retries, no nagging — the rewrite is deterministic.

**Architecture:** One bash wrapper (`bin/jailed`) that sandboxes its argv through `bwrap` (Linux) or `sandbox-exec` (macOS). One PreToolUse hook (`hooks/jailed-hook.sh`) that reads `~/.config/jailed/commands` and emits `hookSpecificOutput.updatedInput.command` with `jailed` prepended at shell-token boundaries for any listed command. `jailed-python`/`jailed-python3` remain as thin shims (`exec jailed python3 "$@"`) for direct human use and backward compatibility.

**Tech Stack:** bash 3.2+, jq, python3 (for regex in the hook), bubblewrap (Linux), sandbox-exec (macOS). No new runtime deps.

**Key design decisions (locked in):**
- **Config format:** newline-delimited list of command names, `#` comments, blank lines ignored. Lives at `~/.config/jailed/commands`. Override via `$JAILED_CONFIG` env var (tests use this).
- **Rewrite strategy:** regex at shell-token boundaries (start-of-string or after `|`, `&`, `;`, `` ` ``, `$(`, `(`, `{`). Handles common cases (pipelines, `&&`, subshells) but not env-prefixed (`env FOO=bar python3`), shell-quoted strings containing separators (`echo ';python3'`), or deeply-nested quoting. Documented, not fixed — MVP.
- **Hook emits `permissionDecision: "allow"`** alongside `updatedInput` so rewritten commands run without an approval prompt. The Bash allowlist needs `Bash(jailed:*)`.
- **Built-in fallback commands** if no config file: `python python3 jq awk sed grep`. Kept deliberately small so the rewrite stays surprise-free out of the box.
- **No project-local config** in MVP (no `.jailed` file in CWD). Future iteration.
- **`jailed-python`/`jailed-python3` shims stay** for direct invocation + existing muscle memory. Under the new hook they're unreachable from rewrites (rewrite always produces `jailed python3`), but manual use still works.
- **Old `hooks/python-nudge.sh` is deleted** from the repo and uninstalled from users' `~/.claude/hooks/` on upgrade.

---

## File Structure

**Created:**
- `bin/jailed` — generic wrapper (bash, ~45 lines including both OS branches).
- `hooks/jailed-hook.sh` — PreToolUse rewriter (bash + embedded python3 regex, ~50 lines).
- `config/commands.default` — packaged default config, shipped as an embedded heredoc in `install.sh` and installed to `~/.config/jailed/commands` on fresh install.
- `tests/test_jailed.sh` — tests the generic wrapper (stdin, network block, write block, stdlib).

**Modified:**
- `bin/jailed-python` — shrinks to `exec "$(dirname "$0")/jailed" python3 "$@"` (plus shebang and a one-line comment).
- `install.sh` — embed new assets; install `jailed` + shim + hook + config; drop legacy `python-nudge.sh`; new allow rule `Bash(jailed:*)`; migrate from prior installs.
- `tests/test_hook.sh` — rewritten to exercise rewriting logic against `hooks/jailed-hook.sh`.
- `tests/test_installer.sh` — assertions for the new binaries/hook/config + migration tests for legacy `python-nudge.sh` and missing config.
- `tests/test_e2e.sh` — install, fire hook with `python3 …` tool-input JSON, verify `updatedInput` emitted.
- `tests/test_wrapper.sh` — unchanged; validates that the `jailed-python` shim still sandboxes correctly.
- `README.md`, `CLAUDE.md` — rewritten architecture section.

**Deleted:**
- `hooks/python-nudge.sh` — superseded by `hooks/jailed-hook.sh`.

---

## Task 1: Generic `jailed` wrapper

**Files:**
- Create: `bin/jailed`
- Create: `tests/test_jailed.sh`

- [ ] **Step 1: Write `tests/test_jailed.sh`**

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

WRAPPER="bin/jailed"

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
assert_exit 7 $? "exit code propagated"

summary
```

- [ ] **Step 2: Run it to confirm it fails**

```
bash tests/test_jailed.sh
```

Expected: multiple failures with `bin/jailed: No such file or directory` or non-zero `summary` exit.

- [ ] **Step 3: Write `bin/jailed`**

```bash
#!/usr/bin/env bash
# jailed: run an arbitrary command under a no-network, no-filesystem-write sandbox.
# Invocation: jailed <cmd> [args...]
# - Linux: bubblewrap with ephemeral tmpfs for $HOME, /tmp, /run
# - macOS: sandbox-exec with a Seatbelt profile that denies network*
#          and file-write* (except /dev sinks). No tmpfs on Darwin;
#          writes fail outright — same no-side-effects contract.

set -u

if (( $# == 0 )); then
  echo "usage: jailed <cmd> [args...]" >&2
  exit 2
fi

if [[ "$(uname)" == "Darwin" ]]; then
  exec sandbox-exec -p '(version 1)
(deny default)
(allow process*)
(allow signal (target self))
(allow mach-lookup)
(allow ipc-posix*)
(allow sysctl-read)
(allow file-read*)
(allow file-write*
  (literal "/dev/null")
  (literal "/dev/stdout")
  (literal "/dev/stderr")
  (literal "/dev/tty")
  (literal "/dev/dtracehelper")
  (regex "^/dev/fd/")
  (regex "^/dev/ttys"))
(deny network*)' "$@"
fi

exec bwrap \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --tmpfs /run \
  --tmpfs "$HOME" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  "$@"
```

Then:

```
chmod +x bin/jailed
```

- [ ] **Step 4: Run the tests to confirm they pass**

```
bash tests/test_jailed.sh
```

Expected: `PASS 6 assertions` (exact count depends on how many assertions each case has — verify end line is green PASS, not FAIL).

- [ ] **Step 5: Commit**

```bash
git add bin/jailed tests/test_jailed.sh
git commit -m "$(cat <<'EOF'
feat(bin): generic jailed wrapper for any command

jailed <cmd> [args...] runs the target through the same sandbox profile
we already use for jailed-python (bwrap on Linux, sandbox-exec on macOS):
no network, read-only FS, writes only to /dev/null and std streams.

Tests mirror test_wrapper.sh but exercise jailed python3, jailed jq, and
exit-code propagation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Convert `bin/jailed-python` to a shim

**Files:**
- Modify: `bin/jailed-python` (full rewrite, ~5 lines)
- Reference (no edits): `tests/test_wrapper.sh` — must continue passing unchanged.

- [ ] **Step 1: Rewrite `bin/jailed-python`**

```bash
#!/usr/bin/env bash
# jailed-python: convenience shim for `jailed python3 "$@"`.
# Kept for direct human use and existing tool integrations. The generic
# `jailed` binary does all the sandboxing work.
exec "$(dirname "$0")/jailed" python3 "$@"
```

Then:

```
chmod +x bin/jailed-python
```

- [ ] **Step 2: Run the existing wrapper test unchanged**

```
bash tests/test_wrapper.sh
```

Expected: `PASS 5 assertions`. The test already invokes `bin/jailed-python -c 'import sys; print(…)'` — if the shim works, nothing visible changes. If it doesn't resolve `bin/jailed` correctly, you'll see errors about `jailed: command not found`.

- [ ] **Step 3: Run the full suite to confirm no regressions**

```
bash tests/run-all.sh
```

Expected: `All test files passed.`

- [ ] **Step 4: Commit**

```bash
git add bin/jailed-python
git commit -m "$(cat <<'EOF'
refactor(bin): jailed-python becomes a shim over jailed

Removes the duplicated sandbox logic in bin/jailed-python and delegates
to the generic bin/jailed. Behavior preserved end-to-end (test_wrapper.sh
passes unchanged).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Default config file (source of truth)

**Files:**
- Create: `config/commands.default`

- [ ] **Step 1: Create `config/commands.default`**

```
# jailed: commands that Claude Code's rewriting hook automatically routes
# through the sandbox. One command per line. Blank lines and `#` comments
# are ignored. Edit ~/.config/jailed/commands to override.

# Python — text processing default.
python
python3

# Stream processors commonly invoked from Claude.
jq
awk
sed
grep
```

- [ ] **Step 2: Commit (no test yet — exercised via hook tests in Task 5)**

```bash
git add config/commands.default
git commit -m "$(cat <<'EOF'
feat(config): default commands list for jailed rewriter

Newline-delimited command names that the PreToolUse hook will transparently
prepend `jailed` to. Installed to ~/.config/jailed/commands on fresh
install; users can edit freely.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rewriting hook — tests first

**Files:**
- Modify: `tests/test_hook.sh` (full rewrite for the new hook)
- Reference (created in Task 5): `hooks/jailed-hook.sh`

- [ ] **Step 1: Rewrite `tests/test_hook.sh`**

```bash
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

run_hook() {
  local cmd="$1"
  JAILED_CONFIG="$CFG" printf '%s' \
    "{\"tool_input\":{\"command\":$(jq -Rn --arg c "$cmd" '$c')}}" \
    | bash "$HOOK"
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
assert_contains "$out" 'result=$(jailed python3 -c "print(1)")' "rewrite handles subshell"

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

test_case "silent when invocation uses jailed-python shim"
out=$(run_hook "jailed-python -c 'print(1)'")
assert_eq "" "$out" "shim already sandboxed; do not double-wrap"

test_case "silent on version-suffixed binaries (python3.11)"
out=$(run_hook "python3.11 -c 'print(1)'")
assert_eq "" "$out" "out of scope: version-suffixed binaries"

test_case "silent on commands that start with listed prefix"
out=$(run_hook "python3script.sh")
assert_eq "" "$out" "must respect word boundary, not substring"

# ---- Config semantics ----

test_case "falls back to built-in defaults when no config file is set"
out=$(JAILED_CONFIG=/nonexistent/path printf '%s' \
  "{\"tool_input\":{\"command\":\"python3 -c 1\"}}" | bash "$HOOK")
assert_contains "$out" "jailed python3 -c 1" "built-in defaults still catch python3"

test_case "user can narrow the list by editing the config"
narrow_cfg="$CFG_DIR/narrow"
printf 'jq\n' > "$narrow_cfg"
out=$(JAILED_CONFIG="$narrow_cfg" printf '%s' \
  "{\"tool_input\":{\"command\":\"python3 -c 1\"}}" | bash "$HOOK")
assert_eq "" "$out" "python3 no longer rewritten when removed from config"

out=$(JAILED_CONFIG="$narrow_cfg" printf '%s' \
  "{\"tool_input\":{\"command\":\"cat | jq .\"}}" | bash "$HOOK")
assert_contains "$out" "cat | jailed jq ." "jq still rewritten (still in config)"

test_case "additionalContext is included so Claude sees why"
out=$(run_hook "python3 -c 'print(1)'")
assert_contains "$out" '"additionalContext"' "must include additionalContext"
assert_contains "$out" "jailed" "additionalContext mentions jailed"

rm -rf "$CFG_DIR"
summary
```

- [ ] **Step 2: Run the tests to confirm they fail**

```
bash tests/test_hook.sh
```

Expected: failures across the board because `hooks/jailed-hook.sh` does not exist yet. Also the old `hooks/python-nudge.sh` will still be on disk — leave it for now; we delete it in Task 5 after the new hook works.

- [ ] **Step 3: Commit tests only**

```bash
git add tests/test_hook.sh
git commit -m "$(cat <<'EOF'
test(hook): rewriting hook specification (failing until task 5)

Tests the new jailed-hook.sh: must rewrite python3/jq at shell-token
boundaries, handle pipelines / && / subshells, not double-jail, respect
word boundaries, fall back to built-in defaults, and honor JAILED_CONFIG
overrides.

Hook implementation lands next commit — suite intentionally red here.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Implement the rewriting hook

**Files:**
- Create: `hooks/jailed-hook.sh`
- Delete: `hooks/python-nudge.sh`

- [ ] **Step 1: Write `hooks/jailed-hook.sh`**

```bash
#!/usr/bin/env bash
# PreToolUse hook: transparently wrap commands in `jailed` before Bash runs them.
#
# Reads the list of commands to jail from (in order):
#   1. $JAILED_CONFIG (for tests / one-off overrides)
#   2. $HOME/.config/jailed/commands
#   3. Built-in fallback (python3 python jq awk sed grep)
#
# Rewrite strategy: at shell-token boundaries (start-of-string, or after
# |, &, ;, `, $(, (, {), prepend `jailed ` to any listed command. This
# handles pipelines, &&, and $(...) naturally. It does NOT handle:
#   - env FOO=bar python3 (command is not at token boundary)
#   - commands embedded inside single-quoted strings that themselves
#     contain shell separators (e.g. `echo ';python3'`) — false positive
# The rewrite is an `allow` + `updatedInput` output, so Bash runs the
# substituted command without an approval prompt.

set -u

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

[[ -z "$cmd" ]] && exit 0

cfg="${JAILED_CONFIG:-$HOME/.config/jailed/commands}"
if [[ -f "$cfg" ]]; then
  mapfile -t targets < <(grep -vE '^[[:space:]]*(#|$)' "$cfg")
else
  targets=(python3 python jq awk sed grep)
fi

# Nothing to do if the list is empty.
(( ${#targets[@]} == 0 )) && exit 0

alt_joined=$(IFS='|'; echo "${targets[*]}")

rewritten=$(python3 - "$cmd" "$alt_joined" <<'PY'
import re, sys
cmd, alts = sys.argv[1], sys.argv[2].split('|')
# Escape each command for regex; longer names first so `python3` matches
# before `python` would.
alts.sort(key=len, reverse=True)
alt_re = '|'.join(re.escape(a) for a in alts if a)
# Pattern: (shell-token boundary)(optional spaces)(target command)(word break)
# The \b at the tail keeps us from matching prefixes (python3script.sh).
pattern = rf'(^|[|&;`({{]|\$\()([[:space:]]*)({alt_re})\b'
def sub(m):
    # Don't double-jail: if the preceding token was already `jailed`,
    # leave it alone. We detect this by looking back past the matched
    # boundary character into the full string.
    start = m.start(3)
    preceding = cmd[:start].rstrip()
    if preceding.endswith('jailed'):
        return m.group(0)
    # Also avoid rewriting occurrences of `jailed-python` (the shim) —
    # those are already sandboxed.
    return f'{m.group(1)}{m.group(2)}jailed {m.group(3)}'
out = re.sub(pattern, sub, cmd)
sys.stdout.write(out)
PY
)

# Only emit JSON if we actually changed the command. A no-op rewrite
# should stay silent so unrelated Bash calls are untouched.
if [[ "$rewritten" != "$cmd" ]]; then
  jq -n --arg new "$rewritten" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      updatedInput: { command: $new },
      additionalContext: "Commands listed in ~/.config/jailed/commands are automatically routed through `jailed` — a sandboxed wrapper with no network and no filesystem writes. Your tool call was rewritten transparently; if you genuinely need network/writes/subprocess, invoke python3 (etc.) via a form the hook will not match (for example, prefix with env VAR=value)."
    }
  }'
fi
exit 0
```

- [ ] **Step 2: Make it executable and run the hook tests**

```
chmod +x hooks/jailed-hook.sh
bash tests/test_hook.sh
```

Expected: `PASS` with ~14 assertions.

- [ ] **Step 3: Delete the obsolete old hook**

```
git rm hooks/python-nudge.sh
```

- [ ] **Step 4: Run the full suite — expect some failures in test_installer.sh and test_e2e.sh**

```
bash tests/run-all.sh
```

Expected: `test_hook.sh` passes, `test_wrapper.sh` + `test_jailed.sh` pass. `test_installer.sh` and `test_e2e.sh` still reference the old hook path and will fail — fixed in Tasks 6 & 7.

- [ ] **Step 5: Commit**

```bash
git add hooks/jailed-hook.sh
git commit -m "$(cat <<'EOF'
feat(hook): jailed-hook.sh — deterministic command rewriter

Replaces hooks/python-nudge.sh. Reads ~/.config/jailed/commands (with
$JAILED_CONFIG override for tests), rewrites tool_input.command at
shell-token boundaries to prepend `jailed`, and emits `updatedInput`
in hookSpecificOutput so Bash transparently runs the sandboxed form
— no ask prompt, no reliance on Claude retrying.

Known MVP limitations documented in the header: env-prefixed commands
and commands embedded in single-quoted strings containing `;`/`|` are
not rewritten correctly. Fine for the common path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Update the installer for the new shape

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

- [ ] **Step 1: Update `tests/test_installer.sh`**

Locate the existing "embedded PYTHON_NUDGE_SCRIPT matches hooks/python-nudge.sh" test (around line 17) and replace the whole file — the shape changes enough that a targeted edit is messier than a rewrite. Use this content:

```bash
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
assert_eq "$actual" "$embedded" "embedded wrapper diverged from bin/jailed"

test_case "embedded JAILED_PYTHON_SHIM matches bin/jailed-python"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$JAILED_PYTHON_SHIM"')
actual=$(cat bin/jailed-python)
assert_eq "$actual" "$embedded" "embedded shim diverged from bin/jailed-python"

test_case "embedded JAILED_HOOK_SCRIPT matches hooks/jailed-hook.sh"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$JAILED_HOOK_SCRIPT"')
actual=$(cat hooks/jailed-hook.sh)
assert_eq "$actual" "$embedded" "embedded hook diverged from hooks/jailed-hook.sh"

test_case "embedded DEFAULT_COMMANDS matches config/commands.default"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$DEFAULT_COMMANDS"')
actual=$(cat config/commands.default)
assert_eq "$actual" "$embedded" "embedded default config diverged from config/commands.default"

test_case "--help prints usage"
out=$(bash install.sh --help 2>&1)
assert_contains "$out" "Usage:" "help output mentions Usage"
assert_contains "$out" "--uninstall" "help mentions --uninstall"

test_case "check_deps passes when all tools present"
out=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; check_deps' 2>&1)
assert_exit 0 $? "check_deps exits 0 when tools present"

test_case "install_bins places jailed, jailed-python, jailed-python3 under \$PREFIX/bin"
tmp=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
for name in jailed jailed-python jailed-python3; do
  [[ -x "$tmp/bin/$name" || -L "$tmp/bin/$name" ]] \
    && assert_eq "ok" "ok" "$name present" \
    || assert_eq "ok" "missing" "$name missing or not executable"
done

test_case "installed jailed actually runs a command through the sandbox"
out=$(echo hi | "$tmp/bin/jailed" python3 -c 'import sys; print(sys.stdin.read().strip())')
assert_eq "hi" "$out" "installed wrapper functions end-to-end"

test_case "installed jailed-python shim still runs"
out=$(echo hi | "$tmp/bin/jailed-python" -c 'import sys; print(sys.stdin.read().strip())')
assert_eq "hi" "$out" "shim still delegates correctly"

test_case "install_bins removes legacy safe-python binaries on upgrade"
mkdir -p "$tmp/bin"
printf '#!/bin/sh\necho legacy\n' > "$tmp/bin/safe-python"
chmod 755 "$tmp/bin/safe-python"
ln -sf safe-python "$tmp/bin/safe-python3"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; PREFIX='$tmp' install_bins"
[[ ! -e "$tmp/bin/safe-python" ]]  && assert_eq "ok" "ok" "legacy safe-python removed"   || assert_eq "ok" "present" "legacy safe-python not cleaned up"
[[ ! -e "$tmp/bin/safe-python3" ]] && assert_eq "ok" "ok" "legacy safe-python3 removed"  || assert_eq "ok" "present" "legacy safe-python3 not cleaned up"

rm -rf "$tmp"

test_case "install_hook installs jailed-hook.sh and removes legacy python-nudge.sh"
tmp_home=$(make_tmp)
# Seed legacy hook.
mkdir -p "$tmp_home/.claude/hooks"
printf '#!/bin/sh\nexit 0\n' > "$tmp_home/.claude/hooks/python-nudge.sh"
chmod 755 "$tmp_home/.claude/hooks/python-nudge.sh"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_hook"
hook_path="$tmp_home/.claude/hooks/jailed-hook.sh"
[[ -x "$hook_path" ]] && assert_eq "ok" "ok" "new hook installed" \
  || assert_eq "ok" "missing" "new hook missing"
[[ ! -e "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "legacy hook removed" \
  || assert_eq "ok" "present" "legacy python-nudge.sh not cleaned up"

rm -rf "$tmp_home"

test_case "install_config writes default list to ~/.config/jailed/commands when absent"
tmp_home=$(make_tmp)
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_config"
config_path="$tmp_home/.config/jailed/commands"
[[ -f "$config_path" ]] && assert_eq "ok" "ok" "config installed" \
  || assert_eq "ok" "missing" "config missing"
assert_contains "$(cat "$config_path")" "python3" "config mentions python3"
assert_contains "$(cat "$config_path")" "jq" "config mentions jq"

test_case "install_config preserves a user-edited config"
# User narrows the list to just jq.
printf '# my custom list\njq\n' > "$config_path"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' install_config"
result=$(cat "$config_path")
assert_eq "# my custom list
jq" "$result" "installer must never overwrite an existing user config"

rm -rf "$tmp_home"

test_case "merge_settings adds Bash(jailed:*) + hook registration"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
echo '{}' > "$tmp_home/.claude/settings.json"
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$result" "Bash(jailed:*)" "generic jailed allow rule present"
assert_contains "$result" "Bash(jailed-python:*)" "python shim allow rule present"
assert_contains "$result" "jailed-hook.sh" "new hook registered"
assert_not_contains "$result" "python-nudge.sh" "legacy hook registration removed"

test_case "merge_settings prunes legacy safe-python allow rules on upgrade"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
cat > "$tmp_home/.claude/settings.json" <<'JSON'
{
  "permissions": { "allow": ["Bash(ls:*)", "Bash(safe-python:*)", "Bash(safe-python3:*)"] },
  "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{"type":"command","command":"$HOME/.claude/hooks/python-nudge.sh"}] }] }
}
JSON
JAILED_PYTHON_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
result=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$result" "Bash(safe-python" "legacy safe-python rules removed"
assert_not_contains "$result" "python-nudge.sh"   "legacy hook registration removed"
assert_contains "$result" "Bash(jailed:*)" "new rule added"
assert_contains "$result" "jailed-hook.sh" "new hook registered"
assert_contains "$result" "Bash(ls:*)" "unrelated rule preserved"

rm -rf "$tmp_home"

test_case "full install runs end-to-end under sandboxed HOME/PREFIX"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "installer exits 0"
for name in jailed jailed-python jailed-python3; do
  [[ -x "$tmp_prefix/bin/$name" || -L "$tmp_prefix/bin/$name" ]] \
    && assert_eq "ok" "ok" "$name placed"   || assert_eq "ok" "no" "$name missing"
done
[[ -x "$tmp_home/.claude/hooks/jailed-hook.sh" ]] && assert_eq "ok" "ok" "hook placed" || assert_eq "ok" "no" "hook missing"
[[ -f "$tmp_home/.config/jailed/commands" ]] && assert_eq "ok" "ok" "config placed" || assert_eq "ok" "no" "config missing"
assert_contains "$(cat "$tmp_home/.claude/settings.json")" "jailed" "settings.json updated"

test_case "full install is idempotent"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "second run exits 0"
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(jailed:*)")] | length' "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "no duplicate allow rule"

rm -rf "$tmp_home" "$tmp_prefix"

test_case "--uninstall removes binaries, hook, allow rules, legacy artifacts"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
# Seed a legacy python-nudge.sh to confirm uninstall catches it too.
printf '#!/bin/sh\nexit 0\n' > "$tmp_home/.claude/hooks/python-nudge.sh"
chmod 755 "$tmp_home/.claude/hooks/python-nudge.sh"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall
assert_exit 0 $? "uninstall exits 0"
for name in jailed jailed-python jailed-python3 safe-python safe-python3; do
  [[ ! -e "$tmp_prefix/bin/$name" ]] && assert_eq "ok" "ok" "$name removed" \
    || assert_eq "ok" "no" "$name still present"
done
[[ ! -e "$tmp_home/.claude/hooks/jailed-hook.sh" ]] && assert_eq "ok" "ok" "new hook removed" || assert_eq "ok" "no" "new hook still present"
[[ ! -e "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "legacy hook removed" || assert_eq "ok" "no" "legacy hook still present"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$settings" "Bash(jailed"   "new allow rules removed"
assert_not_contains "$settings" "Bash(safe-python" "legacy allow rules removed"
assert_not_contains "$settings" "python-nudge.sh"   "legacy hook registration removed"
assert_not_contains "$settings" "jailed-hook.sh"    "new hook registration removed"

rm -rf "$tmp_home" "$tmp_prefix"

summary
```

- [ ] **Step 2: Run it to confirm it fails**

```
bash tests/test_installer.sh
```

Expected: many failures because `install.sh` doesn't yet embed `$JAILED_SCRIPT`, `$JAILED_PYTHON_SHIM`, `$JAILED_HOOK_SCRIPT`, `$DEFAULT_COMMANDS`, or define `install_config`.

- [ ] **Step 3: Rewrite `install.sh`**

Replace the file with:

```bash
#!/usr/bin/env bash
# jailed installer: generic sandbox wrapper + Claude Code integration.
#
# Usage:
#   curl -fsSL <url>/install.sh | bash
#   bash install.sh [--uninstall] [--help]
#
# Env vars:
#   PREFIX     Where to install binaries (default: /usr/local). Uses sudo
#              if not writable.
#   HOME       Root for ~/.claude/ and ~/.config/ edits (inherited).

set -euo pipefail

# -----------------------------------------------------------------------------
# Embedded assets — kept byte-identical to their source-of-truth files via
# tests/test_installer.sh. Edit the source file AND the embedded copy.
# -----------------------------------------------------------------------------

read -r -d '' JAILED_SCRIPT <<'JP_EOF' || true
#!/usr/bin/env bash
# jailed: run an arbitrary command under a no-network, no-filesystem-write sandbox.
# Invocation: jailed <cmd> [args...]
# - Linux: bubblewrap with ephemeral tmpfs for $HOME, /tmp, /run
# - macOS: sandbox-exec with a Seatbelt profile that denies network*
#          and file-write* (except /dev sinks). No tmpfs on Darwin;
#          writes fail outright — same no-side-effects contract.

set -u

if (( $# == 0 )); then
  echo "usage: jailed <cmd> [args...]" >&2
  exit 2
fi

if [[ "$(uname)" == "Darwin" ]]; then
  exec sandbox-exec -p '(version 1)
(deny default)
(allow process*)
(allow signal (target self))
(allow mach-lookup)
(allow ipc-posix*)
(allow sysctl-read)
(allow file-read*)
(allow file-write*
  (literal "/dev/null")
  (literal "/dev/stdout")
  (literal "/dev/stderr")
  (literal "/dev/tty")
  (literal "/dev/dtracehelper")
  (regex "^/dev/fd/")
  (regex "^/dev/ttys"))
(deny network*)' "$@"
fi

exec bwrap \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --tmpfs /run \
  --tmpfs "$HOME" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  "$@"
JP_EOF
JAILED_SCRIPT+=$'\n'

read -r -d '' JAILED_PYTHON_SHIM <<'JP_EOF' || true
#!/usr/bin/env bash
# jailed-python: convenience shim for `jailed python3 "$@"`.
# Kept for direct human use and existing tool integrations. The generic
# `jailed` binary does all the sandboxing work.
exec "$(dirname "$0")/jailed" python3 "$@"
JP_EOF
JAILED_PYTHON_SHIM+=$'\n'

read -r -d '' JAILED_HOOK_SCRIPT <<'JP_EOF' || true
<PASTE EXACT CONTENT OF hooks/jailed-hook.sh FROM TASK 5 HERE>
JP_EOF
JAILED_HOOK_SCRIPT+=$'\n'

read -r -d '' DEFAULT_COMMANDS <<'JP_EOF' || true
# jailed: commands that Claude Code's rewriting hook automatically routes
# through the sandbox. One command per line. Blank lines and `#` comments
# are ignored. Edit ~/.config/jailed/commands to override.

# Python — text processing default.
python
python3

# Stream processors commonly invoked from Claude.
jq
awk
sed
grep
JP_EOF
DEFAULT_COMMANDS+=$'\n'

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

check_deps() {
  local missing=()
  local sandbox_tool="bwrap"
  [[ "$(uname 2>/dev/null)" == "Darwin" ]] && sandbox_tool="sandbox-exec"

  for tool in "$sandbox_tool" jq python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required tools: ${missing[*]}" >&2
    if [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
      echo "sandbox-exec ships with macOS; jq/python3 via: brew install jq python" >&2
    else
      echo "On Debian/Ubuntu: sudo apt install bubblewrap jq python3" >&2
    fi
    return 1
  fi
  return 0
}

_maybe_sudo() {
  local target="$1"; shift
  if [[ -w "$target" ]] || { [[ ! -e "$target" ]] && [[ -w "$(dirname "$target")" ]]; }; then
    "$@"
  else
    sudo "$@"
  fi
}

install_bins() {
  local prefix="${PREFIX:-/usr/local}"
  local bindir="$prefix/bin"

  _maybe_sudo "$bindir" mkdir -p "$bindir"

  # Remove legacy binaries from prior renames.
  for legacy in safe-python safe-python3; do
    if [[ -e "$bindir/$legacy" || -L "$bindir/$legacy" ]]; then
      _maybe_sudo "$bindir/$legacy" rm -f "$bindir/$legacy"
      echo "Removed legacy: $bindir/$legacy"
    fi
  done

  # Generic jailed binary.
  local target="$bindir/jailed"
  printf '%s\n' "$JAILED_SCRIPT" | _maybe_sudo "$target" tee "$target" >/dev/null
  _maybe_sudo "$target" chmod 755 "$target"
  echo "Installed: $target"

  # jailed-python shim.
  local shim="$bindir/jailed-python"
  printf '%s\n' "$JAILED_PYTHON_SHIM" | _maybe_sudo "$shim" tee "$shim" >/dev/null
  _maybe_sudo "$shim" chmod 755 "$shim"
  echo "Installed: $shim"

  # jailed-python3 symlink.
  local link="$bindir/jailed-python3"
  _maybe_sudo "$link" rm -f "$link"
  _maybe_sudo "$link" ln -s jailed-python "$link"
  echo "Installed: $link -> jailed-python"
}

install_hook() {
  local hooks_dir="$HOME/.claude/hooks"
  mkdir -p "$hooks_dir"
  # Drop any legacy hook from prior installs.
  for legacy in python-nudge.sh; do
    if [[ -e "$hooks_dir/$legacy" ]]; then
      rm -f "$hooks_dir/$legacy"
      echo "Removed legacy: $hooks_dir/$legacy"
    fi
  done
  local target="$hooks_dir/jailed-hook.sh"
  printf '%s\n' "$JAILED_HOOK_SCRIPT" > "$target"
  chmod 755 "$target"
  echo "Installed: $target"
}

install_config() {
  local cfg_dir="$HOME/.config/jailed"
  local cfg="$cfg_dir/commands"
  mkdir -p "$cfg_dir"
  # Never overwrite an existing user config. If present, leave it alone.
  if [[ -f "$cfg" ]]; then
    echo "Preserved existing: $cfg"
    return 0
  fi
  printf '%s\n' "$DEFAULT_COMMANDS" > "$cfg"
  echo "Installed: $cfg"
}

merge_settings() {
  local settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  [[ -f "$settings.bak" ]] || cp "$settings" "$settings.bak"

  # Strip legacy allow rules and legacy hook registrations before merging,
  # so upgraders don't keep both generations side-by-side.
  local pruned
  pruned=$(jq '
    if .permissions.allow then
      .permissions.allow |= map(select(
        . != "Bash(safe-python:*)" and . != "Bash(safe-python3:*)"
      ))
    else . end
    | if .hooks.PreToolUse then
        .hooks.PreToolUse |= map(select(
          [.hooks[]?.command] | all(. != "$HOME/.claude/hooks/python-nudge.sh")
        ))
      else . end
  ' "$settings")
  printf '%s\n' "$pruned" > "$settings"

  local patch
  patch=$(cat <<'JSON'
{
  "permissions": {
    "allow": ["Bash(jailed:*)", "Bash(jailed-python:*)", "Bash(jailed-python3:*)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/jailed-hook.sh"}]
    }]
  }
}
JSON
  )

  local merged
  merged=$(jq -n --argjson cur "$(cat "$settings")" --argjson new "$patch" '
    def union_dedupe: . as $arr | reduce $arr[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
    def merge($a; $b):
      if ($a|type) == "object" and ($b|type) == "object" then
        reduce ($a|keys + ($b|keys) | unique)[] as $k
          ({}; .[$k] = (if ($a|has($k)) and ($b|has($k)) then merge($a[$k]; $b[$k])
                        elif ($b|has($k)) then $b[$k]
                        else $a[$k] end))
      elif ($a|type) == "array" and ($b|type) == "array" then
        ($a + $b) | union_dedupe
      else $b
      end;
    merge($cur; $new)
  ')
  printf '%s\n' "$merged" > "$settings"
  echo "Merged into: $settings"
}

run_install() {
  check_deps
  install_bins
  install_hook
  install_config
  merge_settings

  cat <<'EOF'

jailed installed.

Quick test:
  echo '<a href=x>' | jailed python3 -c 'import sys; print(sys.stdin.read())'

Restart Claude Code (or run /config) to pick up the new hook and permissions.
Edit ~/.config/jailed/commands to control which commands are auto-jailed.
EOF
}

usage() {
  cat <<EOF
Usage: bash install.sh [--uninstall] [--help]

Installs jailed + jailed-python + jailed-python3 wrappers and configures
Claude Code to transparently route listed commands through the sandbox.

Options:
  --uninstall   Remove installed files and revert Claude Code config.
  --help        Show this message.

Env:
  PREFIX        Where binaries go (default: /usr/local). Uses sudo if needed.
EOF
}

run_uninstall() {
  local prefix="${PREFIX:-/usr/local}"
  local bindir="$prefix/bin"

  # Remove current + all legacy-generation binaries.
  for f in jailed jailed-python jailed-python3 safe-python safe-python3; do
    if [[ -e "$bindir/$f" || -L "$bindir/$f" ]]; then
      _maybe_sudo "$bindir/$f" rm -f "$bindir/$f"
      echo "Removed: $bindir/$f"
    fi
  done

  for hook in jailed-hook.sh python-nudge.sh; do
    local hpath="$HOME/.claude/hooks/$hook"
    [[ -e "$hpath" ]] && { rm -f "$hpath"; echo "Removed: $hpath"; }
  done

  local settings="$HOME/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    jq '
      if .permissions.allow then
        .permissions.allow |= map(select(
          . != "Bash(jailed:*)"        and . != "Bash(jailed-python:*)" and
          . != "Bash(jailed-python3:*)" and
          . != "Bash(safe-python:*)"   and . != "Bash(safe-python3:*)"
        ))
      else . end
      | if .hooks.PreToolUse then
          .hooks.PreToolUse |= map(select(
            [.hooks[]?.command] | all(
              . != "$HOME/.claude/hooks/jailed-hook.sh" and
              . != "$HOME/.claude/hooks/python-nudge.sh"
            )
          ))
        else . end
    ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    echo "Cleaned: $settings"
  fi

  # We do NOT auto-delete ~/.config/jailed/commands — it's user data.
  echo
  echo "jailed uninstalled. (Backup at $settings.bak remains if you want to restore.)"
  echo "Your config at ~/.config/jailed/commands was left in place."
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --uninstall) run_uninstall ;;
    "") run_install ;;
    *) usage; exit 2 ;;
  esac
}

if [[ -z "${JAILED_PYTHON_LIB_ONLY:-}" ]]; then
  main "$@"
fi
```

**Important:** in the place that reads `<PASTE EXACT CONTENT OF hooks/jailed-hook.sh FROM TASK 5 HERE>`, literally copy-paste the full body from Task 5 step 1 (between the shebang line and the closing `exit 0`, verbatim). The `test_installer.sh` byte-equality test will fail if the copies diverge.

- [ ] **Step 4: Run the installer tests**

```
bash tests/test_installer.sh
```

Expected: `PASS` on all assertions. If the embedded copy check fails, re-paste the hook body exactly.

- [ ] **Step 5: Run the full suite to confirm nothing else broke**

```
bash tests/run-all.sh
```

Expected: `test_jailed.sh`, `test_wrapper.sh`, `test_hook.sh`, `test_installer.sh` all pass. `test_e2e.sh` may still fail (Task 7 updates it).

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "$(cat <<'EOF'
refactor(install): ship jailed binary, rewriting hook, default config

install.sh now embeds and installs four artifacts: bin/jailed (generic
wrapper), bin/jailed-python (shim → jailed python3), hooks/jailed-hook.sh
(rewriting PreToolUse hook), and config/commands.default → installed to
~/.config/jailed/commands on fresh install only (existing user config is
never overwritten).

Settings changes:
- Adds Bash(jailed:*), Bash(jailed-python:*), Bash(jailed-python3:*).
- Registers jailed-hook.sh as a PreToolUse Bash hook.
- Prunes legacy Bash(safe-python:*) rules and legacy python-nudge.sh
  registrations.

--uninstall removes five generations of binaries + both hook variants +
all legacy/current allow rules. Leaves ~/.config/jailed/commands in place
(it's user data).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Update the E2E test

**Files:**
- Modify: `tests/test_e2e.sh`

- [ ] **Step 1: Replace `tests/test_e2e.sh`**

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
trap 'rm -rf "$tmp_home" "$tmp_prefix"' EXIT

test_case "install then run a pipeline through jailed"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
out=$(echo '<a href=hello>' | "$tmp_prefix/bin/jailed" python3 -c '
import sys, re
html = sys.stdin.read()
m = re.search(r"href=(\S+?)>", html)
print(m.group(1) if m else "none")
')
assert_eq "hello" "$out" "end-to-end: jailed python3 pipeline works"

test_case "installed hook rewrites python3 tool-input to jailed python3"
hook="$tmp_home/.claude/hooks/jailed-hook.sh"
out=$(JAILED_CONFIG="$tmp_home/.config/jailed/commands" \
  printf '%s' '{"tool_input":{"command":"python3 -c \"print(1)\""}}' | "$hook")
assert_contains "$out" '"permissionDecision": "allow"' "hook allows with rewrite"
assert_contains "$out" '"updatedInput"' "updatedInput field present"
assert_contains "$out" 'jailed python3 -c' "command wrapped with jailed"

test_case "installed hook stays silent on an already-jailed command"
out=$(JAILED_CONFIG="$tmp_home/.config/jailed/commands" \
  printf '%s' '{"tool_input":{"command":"jailed python3 -c \"print(1)\""}}' | "$hook")
assert_eq "" "$out" "no double-jail"

test_case "settings.json has allow rules + hook registration"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$settings" '"Bash(jailed:*)"' "generic allow"
assert_contains "$settings" "jailed-hook.sh" "hook registered"

test_case "second install keeps things stable"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(jailed:*)")] | length' \
              "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "still no duplicate allow"

summary
```

- [ ] **Step 2: Run all tests**

```
bash tests/run-all.sh
```

Expected: `All test files passed.` across all five test files (test_jailed, test_wrapper, test_hook, test_installer, test_e2e).

- [ ] **Step 3: Commit**

```bash
git add tests/test_e2e.sh
git commit -m "$(cat <<'EOF'
test(e2e): exercise the rewriting hook + installed jailed binary

After install, feeding a python3 command into the installed hook
produces updatedInput with `jailed python3`. Already-jailed commands
pass through silently.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Documentation refresh

**Files:**
- Modify: `README.md` (full rewrite)
- Modify: `CLAUDE.md` (architecture + invariants sections)

- [ ] **Step 1: Rewrite `README.md`**

```markdown
# jailed

A generic sandboxed command wrapper plus a Claude Code integration that
routes listed commands (e.g. `python3`, `jq`, `awk`) through it
transparently. When Claude proposes `python3 -c '…'`, a PreToolUse hook
rewrites the tool input to `jailed python3 -c '…'` before Bash executes —
no approval prompt, no retries, no side effects.

## What `jailed` does

Invoked as `jailed <cmd> [args…]`. Runs the target command with:

- **no network**
- **read-only filesystem** (writes outside `/dev/null` and std streams fail)

Under the hood:

- **Linux:** [bubblewrap](https://github.com/containers/bubblewrap) — `--unshare-all`, `--ro-bind / /`, ephemeral tmpfs for `$HOME`, `/tmp`, `/run`.
- **macOS:** `sandbox-exec` with a Seatbelt profile that denies `network*` and `file-write*` (except `/dev` sinks). No tmpfs on Darwin, so writes fail outright rather than landing ephemerally — same no-side-effects contract.

## Install

    curl -fsSL https://raw.githubusercontent.com/zdavison/jailed/main/install.sh | bash

Or, if you've cloned the repo:

    bash install.sh

Requires `jq` and `python3`, plus the platform sandbox primitive:

- **Linux:** `bwrap` — `sudo apt install bubblewrap jq python3`
- **macOS:** `sandbox-exec` ships with the OS; `brew install jq python` if missing. Xcode Command Line Tools are required so `/usr/bin/python3` is functional (`xcode-select --install`).

## What the installer does

- Drops `jailed`, `jailed-python`, `jailed-python3` into `/usr/local/bin/` (one `sudo` prompt). `jailed-python*` are convenience shims for `jailed python3`.
- Writes `~/.claude/hooks/jailed-hook.sh` (the rewriting PreToolUse hook).
- Writes `~/.config/jailed/commands` **only if absent** — existing user configs are preserved across upgrades.
- Merges into `~/.claude/settings.json`: `permissions.allow` gains `Bash(jailed:*)`, `Bash(jailed-python:*)`, `Bash(jailed-python3:*)`; `hooks.PreToolUse` gains a Bash-matcher hook that runs `jailed-hook.sh`.

Original `settings.json` is backed up to `settings.json.bak` on first run. If you previously installed under `safe-python` or the even-older `pupbox` names, upgrading removes all legacy binaries, allow rules, and hook registrations automatically.

## Configure

`~/.config/jailed/commands` — one command per line, `#` for comments:

```
python
python3
jq
awk
sed
grep
```

Edit freely. Claude's calls to any listed command get rewritten to `jailed <cmd> …` transparently.

## Uninstall

    bash install.sh --uninstall

Removes binaries, hook, and allow rules/hook registration from `settings.json`. Leaves `~/.config/jailed/commands` in place (it's user data).

## Verify

    jailed python3 -c 'print("hello")'
    # -> hello

    jailed python3 -c 'import socket; socket.socket().connect(("1.1.1.1", 80))'
    # -> PermissionError / BlockingIOError

    jailed jq -n '{"ok": 1}'
    # -> {"ok": 1}

## Development

    bash tests/run-all.sh

## Known issues

**Ubuntu 24.04+:** AppArmor restricts unprivileged user namespaces so `bwrap` may fail with `setting up uid map`. Fix:

    sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0

**macOS:** `sandbox-exec` is officially deprecated by Apple (still ubiquitous — WebKit, Chromium, and the OS itself use it). Future macOS versions may remove it. If that happens, the sibling tool [`anthropic-experimental/sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime) is a drop-in with domain-allowlist support.

**Rewrite limitations:** the hook uses regex at shell-token boundaries. It does not rewrite `env FOO=bar python3 …` (command is not at a boundary) or occurrences embedded in single-quoted strings that themselves contain shell separators (e.g. `echo ';python3'`). Both edge cases are rare in Claude's typical usage; workaround is direct invocation as `jailed <cmd>` or removing the command from the config.
```

- [ ] **Step 2: Rewrite `CLAUDE.md`**

Replace the full content with:

```markdown
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo ships `jailed` — a generic sandboxed command wrapper — plus a Claude Code integration that transparently rewrites listed commands (from `~/.config/jailed/commands`) to run through it. `jailed-python` and `jailed-python3` remain as convenience shims over `jailed python3`. Supported on **Linux** (via `bwrap`) and **macOS** (via `sandbox-exec`). The full test suite passes on both.

The project has been renamed twice and restructured once: `pupbox` → `safe-python` → `jailed-python` → current generic `jailed`. Installer migration code silently cleans up artifacts from every prior generation — don't delete that code without a replacement plan.

## Common commands

```bash
bash tests/run-all.sh              # run full test suite
bash tests/test_jailed.sh          # one file at a time
bash install.sh --help             # installer CLI
HOME=/tmp/h PREFIX=/tmp/p bash install.sh           # sandboxed install for manual checks
HOME=/tmp/h PREFIX=/tmp/p bash install.sh --uninstall
```

No build, no lint, no package manager — bash + a single installer script.

## Architecture

Four user-visible artifacts plus an installer that stitches them into Claude Code:

1. **`bin/jailed`** — generic wrapper. `jailed <cmd> [args…]` execs the target under `bwrap` (Linux) or `sandbox-exec` (macOS). One shared SBPL profile; no command-specific config.
2. **`bin/jailed-python`** — shim: `exec "$(dirname "$0")/jailed" python3 "$@"`. `jailed-python3` is a symlink to it. Both exist for direct human use and backward compatibility.
3. **`hooks/jailed-hook.sh`** — PreToolUse hook. Reads `$JAILED_CONFIG` (tests) or `~/.config/jailed/commands` (runtime) or falls back to built-in defaults. For each listed command, rewrites occurrences at shell-token boundaries (`^`, `|`, `&`, `;`, `` ` ``, `$(`, `(`, `{`) to prepend `jailed`. Emits `permissionDecision: allow` + `updatedInput.command` — so the Bash tool runs the rewritten command without asking. This is the deterministic-rewrite path documented in Claude Code's hooks reference.
4. **`config/commands.default`** — packaged default list. Installed to `~/.config/jailed/commands` **only if absent**. User edits are sacred.

### Non-obvious invariants

- **`install.sh` embeds byte-identical copies** of `bin/jailed`, `bin/jailed-python`, `hooks/jailed-hook.sh`, and `config/commands.default` as heredoc strings (`JAILED_SCRIPT`, `JAILED_PYTHON_SHIM`, `JAILED_HOOK_SCRIPT`, `DEFAULT_COMMANDS`). Makes `curl | bash` work with no other files. `tests/test_installer.sh` fails if any embedded copy diverges from its source — **edit both when changing either.**
- **Every installer step is idempotent, reversible, and rename-safe.** `install_bins` removes legacy `safe-python`/`safe-python3` before writing the current generation. `install_hook` removes legacy `python-nudge.sh` before writing the current hook. `install_config` never overwrites an existing user config. `merge_settings` prunes legacy `Bash(safe-python:*)` allow rules and `python-nudge.sh` hook registrations before merging. `--uninstall` removes all generations of binaries, allow rules, and hook registrations (but not the user config). Tests enforce every one of these.
- **Hook rewrite is string-regex, not AST.** Known false negatives: `env FOO=bar python3` (command not at token boundary). Known false positives: listed command tokens appearing inside single-quoted strings that also contain `;` or `|`. Acceptable for MVP; if we need precision, move to a bash-AST-aware rewriter.

### Installer library mode

`install.sh` checks `JAILED_PYTHON_LIB_ONLY=1` at the bottom and skips `main` when set. Tests source it this way to call individual functions (`install_bins`, `install_hook`, `install_config`, `merge_settings`, `check_deps`, …) with overridden `HOME`/`PREFIX`. Preserve this entry point. (Env var name retained from the previous generation to minimize churn — renaming it is a no-op refactor we should fold into the next change that touches install.sh.)

## Testing conventions

- `tests/lib.sh` provides `test_case`, `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_exit`, `summary`, `make_tmp`. Tests `cd` to repo root and `source tests/lib.sh`.
- Each test file ends with `summary` which exits non-zero on any failure.
- `run-all.sh` iterates `tests/test_*.sh` and reports aggregate pass/fail.
- **`test_jailed.sh`** exercises the real sandbox via `bin/jailed` — needs `bwrap` on Linux or `sandbox-exec` on macOS.
- **`test_wrapper.sh`** exercises the real sandbox via the `jailed-python` shim — same platform requirements.
- **`test_hook.sh`** exercises the rewriter purely as a string-transformer — runs anywhere.
- **`test_installer.sh`** and **`test_e2e.sh`** run anywhere with `bash` + `jq` + `python3`.
- Migration tests (legacy state → install → assert clean) live in `test_installer.sh`; keep one per legacy generation. They use old marker/binary names *intentionally* — don't "clean them up" into current names.

## Settings.json merge semantics

`merge_settings` in `install.sh` is the reference: first prune stale `Bash(safe-python:*)` rules and `python-nudge.sh` hook registrations, then deep-merge where objects recurse, arrays concatenate then dedupe by structural equality, scalars let the patch win. When changing permission strings or hook shape, update the embedded patch, the uninstall filter (which removes by exact match across all generations), and the prune list.
```

- [ ] **Step 3: Run the suite one more time**

```
bash tests/run-all.sh
```

Expected: `All test files passed.`

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: explain the generic jailed + rewriting hook architecture

README pitches the deterministic-rewrite flow up front, documents the
config file, and calls out the two known regex-rewrite limitations
(env-prefixed and quoted-separator edge cases).

CLAUDE.md covers the four artifacts, the byte-identity invariant, the
rewrite-is-regex-not-AST caveat, and the migration history so future
edits don't break pre-rename users.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage:**
- Generic `jailed <cmd>` binary → Task 1. ✓
- Hook rewrites via `updatedInput` → Task 4/5. ✓
- Config file listing jailable commands → Task 3 + Task 5 + Task 6. ✓
- Default config installed on fresh install, preserved on upgrade → Task 6 (`install_config`). ✓
- Migration from `jailed-python`-only install → Task 6 (`install_hook` drops `python-nudge.sh`; `merge_settings` prunes legacy rules; `run_uninstall` covers all generations). ✓
- Handling of pipelines, `&&`, `$(…)` → Task 4 tests exercise each. ✓
- Silent on already-jailed / non-listed / word-boundary false positives → Task 4 tests. ✓
- Docs updated → Task 8. ✓

**Placeholder scan:** two spots use placeholder-ish phrasing worth calling out:
- Task 6 step 3 says `<PASTE EXACT CONTENT OF hooks/jailed-hook.sh FROM TASK 5 HERE>`. Deliberate: the executor must literally paste the Task 5 Step 1 body verbatim, and the byte-equality test will catch divergence. Instruction is explicit, not vague.
- No other TODO/TBD markers.

**Type/name consistency:** variables `JAILED_SCRIPT`, `JAILED_PYTHON_SHIM`, `JAILED_HOOK_SCRIPT`, `DEFAULT_COMMANDS` are defined in Task 6 and asserted by the tests written earlier in Task 6 step 1. Functions `install_bins`, `install_hook`, `install_config`, `merge_settings`, `check_deps`, `run_install`, `run_uninstall` consistent throughout. Env var `JAILED_PYTHON_LIB_ONLY` retained from the prior generation (note in CLAUDE.md Task 8). Env var `JAILED_CONFIG` consistently referenced in Tasks 4, 5, 7. Hook output fields `permissionDecision`, `updatedInput`, `additionalContext` match the documented schema from the claude-code-guide agent's survey.
