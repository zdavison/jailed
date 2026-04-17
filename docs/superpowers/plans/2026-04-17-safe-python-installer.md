# safe-python Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a one-line installer that drops `safe-python` / `safe-python3` wrappers (Python running under `bwrap` with no network and a read-only filesystem) onto a Linux host and configures Claude Code to prefer them over raw `python3`.

**Architecture:** A single self-contained `install.sh` with the wrapper script and the PreToolUse hook embedded as bash heredocs. The installer places two binaries (`safe-python`, `safe-python3`) under `$PREFIX/bin`, drops a hook at `~/.claude/hooks/python-nudge.sh`, merges an `allow` rule + hook registration into `~/.claude/settings.json` via `jq`, and upserts a "Python execution policy" section in `~/.claude/CLAUDE.md`. Everything is idempotent so re-running it is safe. End-user entry point: `curl -fsSL <raw-url>/install.sh | bash`.

**Tech Stack:** Bash, `bwrap` (bubblewrap), `jq`, Python 3, Claude Code settings + hooks. Tests are plain bash with a tiny assertion helper — no test framework dependency.

---

## File Structure

```
pupbox/
├── .gitignore
├── README.md                            # usage + the one-liner
├── install.sh                           # THE self-contained installer (source of truth)
├── bin/
│   └── safe-python                      # standalone copy of the wrapper, for direct dev use
├── hooks/
│   └── python-nudge.sh                  # standalone copy of the hook, for direct dev use
├── tests/
│   ├── lib.sh                           # assert_eq, assert_contains, cleanup helpers
│   ├── test_wrapper.sh                  # wrapper blocks net + fs writes, allows stdin/stdout
│   ├── test_hook.sh                     # hook emits ask+reason for python3, silent otherwise
│   ├── test_installer.sh                # file placement, JSON merge, CLAUDE.md upsert, idempotency
│   └── test_e2e.sh                      # full install in sandboxed HOME + pipeline smoke test
└── docs/superpowers/plans/
    └── 2026-04-17-safe-python-installer.md
```

**Authoritative source:** `install.sh` is the bundle shipped to users. The standalone copies at `bin/safe-python` and `hooks/python-nudge.sh` exist for direct development/testing and MUST stay byte-identical to the heredocs in `install.sh`. A test enforces this.

**Why one bundle:** `curl ... | bash` must work without the pipe also downloading companion files. Embedding as heredocs keeps the installer truly one-liner-friendly.

**Parameterization:**
- `PREFIX` (default `/usr/local`): where `safe-python` / `safe-python3` land (`$PREFIX/bin`). Override for testing: `PREFIX=/tmp/test-root bash install.sh`.
- `HOME` (inherited): determines `~/.claude/` location. Override for testing: `HOME=/tmp/test-home bash install.sh`.
- When `PREFIX=/usr/local`, the installer uses `sudo` for binary placement only; the Claude config under `$HOME` never needs sudo.

---

## Task 1: Repo scaffolding + git init

**Files:**
- Create: `.gitignore`
- Create: `README.md`
- Create: `bin/`, `hooks/`, `tests/` directories (empty for now)

- [ ] **Step 1: Initialize git repo**

```bash
cd /home/z/Desktop/work/pupbox
git init
git branch -m main
```

Expected: `Initialized empty Git repository` plus branch rename success.

- [ ] **Step 2: Create `.gitignore`**

```
# scratch + test artifacts
/tmp-test/
/.test-home/
*.log

# editor
.idea/
.vscode/
*.swp
```

- [ ] **Step 3: Create `README.md` with one-liner placeholder**

```markdown
# pupbox — safe-python for Claude Code

A sandboxed Python wrapper (`bwrap`: no network, read-only filesystem) that Claude Code
can invoke freely as a text processor without permission prompts, while still being able
to escape to real `python3` when genuinely needed.

## Install

    curl -fsSL https://raw.githubusercontent.com/<you>/pupbox/main/install.sh | bash

After install:

- `safe-python -c '...'` and `safe-python3 -c '...'` are pre-approved in Claude Code.
- Real `python3` still works but prompts with a reminder to prefer `safe-python`.
- Your own shell is untouched.

Requires: Linux, `bwrap` (apt: `bubblewrap`), `jq`, `python3`.

## Uninstall

    bash install.sh --uninstall
```

- [ ] **Step 4: Create empty directories with `.gitkeep`**

```bash
mkdir -p bin hooks tests
touch bin/.gitkeep hooks/.gitkeep tests/.gitkeep
```

- [ ] **Step 5: Initial commit**

```bash
git add .gitignore README.md bin/.gitkeep hooks/.gitkeep tests/.gitkeep docs/
git commit -m "scaffold: initial repo structure"
```

Expected: clean commit, `git status` shows working tree clean.

---

## Task 2: Test harness (`tests/lib.sh`)

**Files:**
- Create: `tests/lib.sh`

Rationale: small bash helper so every test file has consistent assert output and temp cleanup. No external deps.

- [ ] **Step 1: Write `tests/lib.sh`**

```bash
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
  dir=$(mktemp -d -t pupbox-test.XXXXXX)
  echo "$dir"
}
```

- [ ] **Step 2: Sanity-check the helper by running a trivial test**

```bash
cat > /tmp/_pupbox_sanity.sh <<'EOF'
#!/usr/bin/env bash
source tests/lib.sh
test_case "sanity: assert_eq works"
assert_eq "a" "a" "trivial equal"
assert_contains "hello world" "world" "trivial contains"
summary
EOF
bash /tmp/_pupbox_sanity.sh
```

Expected: `PASS 2 assertions`, exit 0.

- [ ] **Step 3: Remove the sanity scratch file and commit**

```bash
rm /tmp/_pupbox_sanity.sh
git add tests/lib.sh
git commit -m "test: add bash assertion helpers"
```

---

## Task 3: `safe-python` wrapper (TDD)

**Files:**
- Create: `tests/test_wrapper.sh`
- Create: `bin/safe-python`

Rationale: wrapper must (a) pass stdin/stdout through, (b) block outbound network, (c) block writes to real filesystem paths, (d) still let Python import stdlib.

- [ ] **Step 1: Write the failing test `tests/test_wrapper.sh`**

```bash
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
# Pick a marker path that must NOT exist after the wrapper runs.
marker="/tmp/pupbox-wrapper-test-$$.marker"
rm -f "$marker"
bash "$WRAPPER" -c "open('$marker', 'w').write('x')" 2>/dev/null || true
if [[ -e "$marker" ]]; then
  # If it exists on the real FS, the sandbox leaked. Clean up + fail.
  rm -f "$marker"
  assert_eq "absent" "present" "sandbox leaked: marker was written to real /tmp"
else
  assert_eq "absent" "absent" "real /tmp unaffected by sandboxed write"
fi

test_case "wrapper can import stdlib (json)"
result=$(bash "$WRAPPER" -c 'import json; print(json.dumps({"ok": 1}))')
assert_eq '{"ok": 1}' "$result" "json stdlib import works"

summary
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_wrapper.sh
```

Expected: FAIL on first case because `bin/safe-python` doesn't exist yet (`bash: bin/safe-python: No such file or directory`).

- [ ] **Step 3: Write `bin/safe-python`**

```bash
#!/usr/bin/env bash
# safe-python: /usr/bin/python3 under bubblewrap.
# - read-only view of /, no writes outside ephemeral tmpfs
# - no network (unshare-all)
# - dies with parent shell

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
  /usr/bin/python3 "$@"
```

- [ ] **Step 4: Make it executable and re-run tests**

```bash
chmod +x bin/safe-python
bash tests/test_wrapper.sh
```

Expected: `PASS 5 assertions`.

- [ ] **Step 5: Commit**

```bash
git add bin/safe-python tests/test_wrapper.sh
git commit -m "feat: safe-python wrapper with bwrap sandbox"
```

---

## Task 4: `python-nudge.sh` PreToolUse hook (TDD)

**Files:**
- Create: `tests/test_hook.sh`
- Create: `hooks/python-nudge.sh`

Rationale: the hook reads Claude Code's PreToolUse JSON on stdin, and emits a decision JSON on stdout that turns `python3`/`python` Bash calls into `ask` with a custom reason. Must NOT match `safe-python`, `safe-python3`, or path-suffixed interpreters like `python3.11`.

- [ ] **Step 1: Write the failing test `tests/test_hook.sh`**

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

HOOK="hooks/python-nudge.sh"

run_hook() {
  local cmd="$1"
  printf '%s' "{\"tool_input\":{\"command\":$(jq -Rn --arg c "$cmd" '$c')}}" \
    | bash "$HOOK"
}

test_case "fires on 'python3 -c'"
out=$(run_hook "python3 -c 'print(1)'")
assert_contains "$out" '"permissionDecision": "ask"' "must ask"
assert_contains "$out" "safe-python" "reason must mention safe-python"

test_case "fires on 'python -c' at start"
out=$(run_hook "python -c 'print(1)'")
assert_contains "$out" '"permissionDecision": "ask"' "must ask"

test_case "fires on python3 after a pipe"
out=$(run_hook "echo foo | python3 -c 'import sys; print(sys.stdin.read())'")
assert_contains "$out" '"permissionDecision": "ask"' "must ask for pipeline"

test_case "silent on safe-python"
out=$(run_hook "safe-python -c 'print(1)'")
assert_eq "" "$out" "must produce no output for safe-python"

test_case "silent on safe-python3"
out=$(run_hook "safe-python3 -c 'print(1)'")
assert_eq "" "$out" "must produce no output for safe-python3"

test_case "silent on pytest"
out=$(run_hook "pytest tests/")
assert_eq "" "$out" "must produce no output for pytest"

test_case "silent on python3.11 (version-suffixed binary)"
out=$(run_hook "python3.11 -c 'print(1)'")
assert_eq "" "$out" "should not fire on versioned binary (out of scope for v1)"

summary
```

Note on the last case: `python3.11` is intentionally out of scope — users invoking version-pinned interpreters know what they're doing, and matching them risks false positives on `/usr/bin/python3.11` paths. The test documents the intentional behavior.

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_hook.sh
```

Expected: FAIL — `hooks/python-nudge.sh` doesn't exist.

- [ ] **Step 3: Write `hooks/python-nudge.sh`**

```bash
#!/usr/bin/env bash
# PreToolUse hook: nudge Claude toward safe-python when it tries to run raw python/python3.
# Emits an ask-decision with a custom reason; stays silent for everything else.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Match python or python3 as a standalone command, anchored to start-of-string or a
# shell separator. Excludes safe-python, safe-python3, python3.N, pythonX, etc.
if echo "$cmd" | grep -qE '(^|[|&;`]|\$\()[[:space:]]*python3?([[:space:]]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "Prefer safe-python (pre-approved, sandboxed: no network, no filesystem writes) for text processing. Only continue with python3 if you genuinely need network, file writes, subprocess, or full stdlib access."
    }
  }'
fi
exit 0
```

- [ ] **Step 4: Make it executable and re-run tests**

```bash
chmod +x hooks/python-nudge.sh
bash tests/test_hook.sh
```

Expected: `PASS 9 assertions`.

- [ ] **Step 5: Commit**

```bash
git add hooks/python-nudge.sh tests/test_hook.sh
git commit -m "feat: PreToolUse hook nudging python3 -> safe-python"
```

---

## Task 5: Installer skeleton with parity check

**Files:**
- Create: `install.sh`
- Create: `tests/test_installer.sh`

Rationale: first cut of the installer — establishes the structure (embedded heredocs, `PREFIX`/`HOME` parameterization, `--uninstall` flag stub) and proves the embedded wrapper/hook match the standalone files byte-for-byte. No actual install work yet.

- [ ] **Step 1: Write the failing test `tests/test_installer.sh`**

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

test_case "embedded SAFE_PYTHON_SCRIPT matches bin/safe-python"
# Source install.sh in library mode so it exposes the variables without executing main.
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

summary
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: FAIL — `install.sh` doesn't exist.

- [ ] **Step 3: Write initial `install.sh`**

```bash
#!/usr/bin/env bash
# pupbox installer: safe-python + Claude Code integration.
#
# Usage:
#   curl -fsSL <url>/install.sh | bash
#   bash install.sh [--uninstall] [--help]
#
# Env vars:
#   PREFIX     Where to install binaries (default: /usr/local). Requires sudo if
#              PREFIX is not writable.
#   HOME       Root for ~/.claude/ edits (inherited).

set -euo pipefail

# -----------------------------------------------------------------------------
# Embedded assets (kept byte-identical to bin/safe-python + hooks/python-nudge.sh
# via tests/test_installer.sh).
# -----------------------------------------------------------------------------

read -r -d '' SAFE_PYTHON_SCRIPT <<'PUPBOX_EOF' || true
#!/usr/bin/env bash
# safe-python: /usr/bin/python3 under bubblewrap.
# - read-only view of /, no writes outside ephemeral tmpfs
# - no network (unshare-all)
# - dies with parent shell

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
  /usr/bin/python3 "$@"
PUPBOX_EOF

read -r -d '' PYTHON_NUDGE_SCRIPT <<'PUPBOX_EOF' || true
#!/usr/bin/env bash
# PreToolUse hook: nudge Claude toward safe-python when it tries to run raw python/python3.
# Emits an ask-decision with a custom reason; stays silent for everything else.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Match python or python3 as a standalone command, anchored to start-of-string or a
# shell separator. Excludes safe-python, safe-python3, python3.N, pythonX, etc.
if echo "$cmd" | grep -qE '(^|[|&;`]|\$\()[[:space:]]*python3?([[:space:]]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "Prefer safe-python (pre-approved, sandboxed: no network, no filesystem writes) for text processing. Only continue with python3 if you genuinely need network, file writes, subprocess, or full stdlib access."
    }
  }'
fi
exit 0
PUPBOX_EOF

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: bash install.sh [--uninstall] [--help]

Installs safe-python + safe-python3 wrappers and configures Claude Code
to prefer them over raw python3.

Options:
  --uninstall   Remove installed files and revert Claude Code config.
  --help        Show this message.

Env:
  PREFIX        Where binaries go (default: /usr/local). Uses sudo if needed.
EOF
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --uninstall) echo "uninstall not yet implemented"; exit 1 ;;
    "") echo "install not yet implemented"; exit 1 ;;
    *) usage; exit 2 ;;
  esac
}

# If sourced by the test harness (PUPBOX_LIB_ONLY=1), stop after defining vars.
if [[ -z "${PUPBOX_LIB_ONLY:-}" ]]; then
  main "$@"
fi
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 5 assertions`. If the parity test fails, the embedded heredocs diverged from the standalone source files — fix whichever is out of date.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat: installer skeleton with embedded-asset parity check"
```

---

## Task 6: Dependency check

**Files:**
- Modify: `install.sh` (add `check_deps` function)
- Modify: `tests/test_installer.sh` (add dependency-check test)

Rationale: fail fast and clearly if `bwrap`, `jq`, or `python3` is missing, with an exact apt command.

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
test_case "check_deps passes when all tools present"
out=$(PUPBOX_LIB_ONLY=1 bash -c 'source install.sh; check_deps' 2>&1)
assert_exit 0 $? "check_deps exits 0 when tools present"

test_case "check_deps fails with helpful message when a tool is missing"
# Simulate a missing tool by shadowing command -v.
out=$(PUPBOX_LIB_ONLY=1 PATH=/nonexistent bash -c 'source install.sh; check_deps' 2>&1 || true)
assert_contains "$out" "bwrap" "message mentions bwrap"
assert_contains "$out" "apt" "message includes apt hint"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: `check_deps: command not found` — function doesn't exist yet.

- [ ] **Step 3: Add `check_deps` to `install.sh`**

Insert before the `usage()` function:

```bash
check_deps() {
  local missing=()
  for tool in bwrap jq python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "On Debian/Ubuntu: sudo apt install bubblewrap jq python3" >&2
    return 1
  fi
  return 0
}
```

- [ ] **Step 4: Run tests again**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 9 assertions`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): dependency check for bwrap, jq, python3"
```

---

## Task 7: Binary placement (`safe-python` + `safe-python3`)

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

Rationale: write the embedded wrapper to `$PREFIX/bin/safe-python` and create `safe-python3` as a symlink to it. `sudo` only when `$PREFIX/bin` is not user-writable. `$PREFIX` is a parameter so tests can point it at a tmpdir.

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: `install_bins: command not found`.

- [ ] **Step 3: Add `install_bins` to `install.sh`**

Insert after `check_deps`:

```bash
# Run a command with sudo iff the target path is not user-writable.
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
  local target="$bindir/safe-python"
  local link="$bindir/safe-python3"

  _maybe_sudo "$bindir" mkdir -p "$bindir"

  # Write via tee so sudo flows naturally.
  printf '%s\n' "$SAFE_PYTHON_SCRIPT" | _maybe_sudo "$target" tee "$target" >/dev/null
  _maybe_sudo "$target" chmod 755 "$target"

  # safe-python3 -> safe-python (replace existing symlink or file).
  _maybe_sudo "$link" rm -f "$link"
  _maybe_sudo "$link" ln -s safe-python "$link"

  echo "Installed: $target"
  echo "Installed: $link -> safe-python"
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 13 assertions`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): place safe-python + safe-python3 under \$PREFIX/bin"
```

---

## Task 8: Hook placement

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

Rationale: write the hook to `$HOME/.claude/hooks/python-nudge.sh`, create the `hooks/` dir if missing, make it executable. No sudo — `~/.claude` is always user-owned.

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
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
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: `install_hook: command not found`.

- [ ] **Step 3: Add `install_hook` to `install.sh`**

Insert after `install_bins`:

```bash
install_hook() {
  local hooks_dir="$HOME/.claude/hooks"
  local target="$hooks_dir/python-nudge.sh"
  mkdir -p "$hooks_dir"
  printf '%s\n' "$PYTHON_NUDGE_SCRIPT" > "$target"
  chmod 755 "$target"
  echo "Installed: $target"
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 15 assertions`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): place PreToolUse hook under ~/.claude/hooks"
```

---

## Task 9: Merge into `~/.claude/settings.json`

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

Rationale: deep-merge two fragments into the user's settings.json via `jq` so existing config is preserved. Idempotent: second run must not duplicate array entries. Back up the original to `settings.json.bak` on first merge only.

**The fragments to merge (logical view):**

```json
{
  "permissions": {
    "allow": ["Bash(safe-python:*)", "Bash(safe-python3:*)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/python-nudge.sh"}]
    }]
  }
}
```

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
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
# Mutate the live file; second run must not overwrite the backup.
jq '._v = 99' "$tmp_home/.claude/settings.json.bak" > "$tmp_home/.claude/settings.json.bak.tmp" \
  && mv "$tmp_home/.claude/settings.json.bak.tmp" "$tmp_home/.claude/settings.json.bak"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' merge_settings"
bak_v=$(jq -r '._v' "$tmp_home/.claude/settings.json.bak")
assert_eq "99" "$bak_v" "second run must not overwrite .bak"

rm -rf "$tmp_home"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: `merge_settings: command not found`.

- [ ] **Step 3: Add `merge_settings` to `install.sh`**

Insert after `install_hook`:

```bash
merge_settings() {
  local settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  # One-shot backup.
  [[ -f "$settings.bak" ]] || cp "$settings" "$settings.bak"

  local patch
  patch=$(cat <<'JSON'
{
  "permissions": {
    "allow": ["Bash(safe-python:*)", "Bash(safe-python3:*)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/python-nudge.sh"}]
    }]
  }
}
JSON
  )

  # Deep-merge with dedupe:
  # - permissions.allow: union (preserve order, drop duplicates)
  # - hooks.PreToolUse: union by full structural equality (drop duplicates)
  # - everything else: recursive merge, patch wins on scalar conflicts
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
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 22 assertions`. If the dedupe test fails, the `union_dedupe` logic needs to treat the hook object as a single atomic entry — verify by inspecting the merged `hooks.PreToolUse` array.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): merge allow rules + hook into ~/.claude/settings.json"
```

---

## Task 10: Upsert `~/.claude/CLAUDE.md` policy section

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

Rationale: add (or replace) a labeled `## Python execution policy` block in the user's global CLAUDE.md. Uses clearly-delimited markers so re-running the installer replaces the existing block rather than appending a second copy.

**The policy block:**

```markdown
<!-- pupbox:python-policy:start -->
## Python execution policy

- **Default: `safe-python` / `safe-python3`** for text processing in pipelines
  (e.g. `pup ... | safe-python -c '...'`). Pre-approved, no prompt. Read-only
  filesystem, no network — ideal for parsing/transforming stdin to stdout.
- **Escape hatch: `python3`** when you actually need network, file writes,
  subprocess, or real project scripts/tests. Will prompt with a reminder;
  confirm when the need is real.

Decision rule: if the Python code reads stdin and prints to stdout with no
side effects, use `safe-python`. Otherwise `python3`.
<!-- pupbox:python-policy:end -->
```

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
test_case "upsert_claude_md adds policy block to empty file"
tmp_home=$(make_tmp)
mkdir -p "$tmp_home/.claude"
: > "$tmp_home/.claude/CLAUDE.md"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_contains "$result" "pupbox:python-policy:start" "start marker"
assert_contains "$result" "pupbox:python-policy:end" "end marker"
assert_contains "$result" "safe-python" "block content present"

test_case "upsert_claude_md preserves existing unrelated content"
cat > "$tmp_home/.claude/CLAUDE.md" <<'MD'
# My personal prefs

- never use emojis
MD
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_contains "$result" "never use emojis" "original content preserved"
assert_contains "$result" "Python execution policy" "policy added"

test_case "upsert_claude_md is idempotent"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
count=$(grep -c "pupbox:python-policy:start" <<< "$result")
assert_eq "1" "$count" "policy block not duplicated"

test_case "upsert_claude_md replaces old content inside markers"
# Corrupt the block inside markers; upsert should restore correct content.
python3 -c "
import re
p = '$tmp_home/.claude/CLAUDE.md'
with open(p) as f: s = f.read()
s = re.sub(r'(pupbox:python-policy:start -->).*?(<!-- pupbox:python-policy:end)',
          r'\1\nCORRUPTED\n\2', s, flags=re.DOTALL)
with open(p, 'w') as f: f.write(s)
"
PUPBOX_LIB_ONLY=1 bash -c "source install.sh; HOME='$tmp_home' upsert_claude_md"
result=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$result" "CORRUPTED" "corrupted content replaced"
assert_contains "$result" "Decision rule" "correct content restored"

rm -rf "$tmp_home"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: `upsert_claude_md: command not found`.

- [ ] **Step 3: Add `upsert_claude_md` to `install.sh`**

Insert after `merge_settings`:

```bash
upsert_claude_md() {
  local md="$HOME/.claude/CLAUDE.md"
  mkdir -p "$HOME/.claude"
  [[ -f "$md" ]] || : > "$md"

  local block
  block=$(cat <<'MD'
<!-- pupbox:python-policy:start -->
## Python execution policy

- **Default: `safe-python` / `safe-python3`** for text processing in pipelines
  (e.g. `pup ... | safe-python -c '...'`). Pre-approved, no prompt. Read-only
  filesystem, no network — ideal for parsing/transforming stdin to stdout.
- **Escape hatch: `python3`** when you actually need network, file writes,
  subprocess, or real project scripts/tests. Will prompt with a reminder;
  confirm when the need is real.

Decision rule: if the Python code reads stdin and prints to stdout with no
side effects, use `safe-python`. Otherwise `python3`.
<!-- pupbox:python-policy:end -->
MD
  )

  # Strip any existing delimited block, then append a fresh one.
  local cleaned
  cleaned=$(python3 - "$md" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    s = f.read()
s = re.sub(
    r'<!-- pupbox:python-policy:start -->.*?<!-- pupbox:python-policy:end -->\n?',
    '', s, flags=re.DOTALL)
# Trim trailing blank lines so we don't keep accumulating them.
s = s.rstrip() + ('\n' if s.strip() else '')
sys.stdout.write(s)
PY
  )

  {
    printf '%s' "$cleaned"
    [[ -n "$cleaned" ]] && printf '\n'
    printf '%s\n' "$block"
  } > "$md"
  echo "Updated: $md"
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 28 assertions`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): upsert Python policy block in ~/.claude/CLAUDE.md"
```

---

## Task 11: Wire `main()` to run everything

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

Rationale: connect `check_deps` → `install_bins` → `install_hook` → `merge_settings` → `upsert_claude_md` under the default (no-args) entry point. Print a friendly summary at the end.

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
test_case "full install runs all steps under a sandboxed HOME/PREFIX"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "installer exits 0"
[[ -x "$tmp_prefix/bin/safe-python" ]]  && assert_eq "ok" "ok" "safe-python placed"   || assert_eq "ok" "no" "safe-python missing"
[[ -x "$tmp_prefix/bin/safe-python3" ]] && assert_eq "ok" "ok" "safe-python3 placed"  || assert_eq "ok" "no" "safe-python3 missing"
[[ -x "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "hook placed" || assert_eq "ok" "no" "hook missing"
assert_contains "$(cat "$tmp_home/.claude/settings.json")" "safe-python" "settings.json updated"
assert_contains "$(cat "$tmp_home/.claude/CLAUDE.md")" "Python execution policy" "CLAUDE.md updated"

test_case "full install is idempotent (second run zero errors, no dupes)"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh
assert_exit 0 $? "second run exits 0"
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(safe-python:*)")] | length' "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "no duplicate allow rule"
md_count=$(grep -c "pupbox:python-policy:start" "$tmp_home/.claude/CLAUDE.md")
assert_eq "1" "$md_count" "no duplicate policy block"

rm -rf "$tmp_home" "$tmp_prefix"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: FAIL — the `""` branch of `main` still prints `install not yet implemented`.

- [ ] **Step 3: Replace the `""` branch in `main()`**

Change the case arm:

```bash
    "") echo "install not yet implemented"; exit 1 ;;
```

to:

```bash
    "") run_install ;;
```

Then add `run_install` after `upsert_claude_md`:

```bash
run_install() {
  check_deps
  install_bins
  install_hook
  merge_settings
  upsert_claude_md

  cat <<'EOF'

pupbox installed.

Quick test:
  echo '<a href=x>' | safe-python -c 'import sys; print(sys.stdin.read())'

Restart Claude Code (or run /config) to pick up the new hook and permissions.
EOF
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 36 assertions`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): wire main() to run full install sequence"
```

---

## Task 12: `--uninstall` flag

**Files:**
- Modify: `install.sh`
- Modify: `tests/test_installer.sh`

Rationale: clean reversal — remove binaries, remove hook, remove allow rules + hook registration from settings.json (via inverse `jq`), and strip the CLAUDE.md block.

- [ ] **Step 1: Add failing test to `tests/test_installer.sh`**

Append before `summary`:

```bash
test_case "--uninstall removes binaries, hook, settings entries, and CLAUDE.md block"
tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh --uninstall
assert_exit 0 $? "uninstall exits 0"
[[ ! -e "$tmp_prefix/bin/safe-python" ]]  && assert_eq "ok" "ok" "safe-python removed"   || assert_eq "ok" "no" "safe-python still present"
[[ ! -e "$tmp_prefix/bin/safe-python3" ]] && assert_eq "ok" "ok" "safe-python3 removed"  || assert_eq "ok" "no" "safe-python3 still present"
[[ ! -e "$tmp_home/.claude/hooks/python-nudge.sh" ]] && assert_eq "ok" "ok" "hook removed" || assert_eq "ok" "no" "hook still present"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_not_contains "$settings" "safe-python" "allow rules removed"
assert_not_contains "$settings" "python-nudge.sh" "hook registration removed"
md=$(cat "$tmp_home/.claude/CLAUDE.md")
assert_not_contains "$md" "pupbox:python-policy:start" "policy block removed"

rm -rf "$tmp_home" "$tmp_prefix"
```

- [ ] **Step 2: Run it to verify it fails**

```bash
bash tests/test_installer.sh
```

Expected: `uninstall not yet implemented` → exit 1.

- [ ] **Step 3: Implement `run_uninstall`**

Change the `--uninstall` case arm:

```bash
    --uninstall) echo "uninstall not yet implemented"; exit 1 ;;
```

to:

```bash
    --uninstall) run_uninstall ;;
```

Then add after `run_install`:

```bash
run_uninstall() {
  local prefix="${PREFIX:-/usr/local}"
  local bindir="$prefix/bin"

  for f in safe-python safe-python3; do
    if [[ -e "$bindir/$f" || -L "$bindir/$f" ]]; then
      _maybe_sudo "$bindir/$f" rm -f "$bindir/$f"
      echo "Removed: $bindir/$f"
    fi
  done

  local hook="$HOME/.claude/hooks/python-nudge.sh"
  [[ -e "$hook" ]] && { rm -f "$hook"; echo "Removed: $hook"; }

  local settings="$HOME/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    jq '
      if .permissions.allow then
        .permissions.allow |= map(select(. != "Bash(safe-python:*)" and . != "Bash(safe-python3:*)"))
      else . end
      | if .hooks.PreToolUse then
          .hooks.PreToolUse |= map(select(
            [.hooks[]?.command] | all(. != "$HOME/.claude/hooks/python-nudge.sh")
          ))
        else . end
    ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    echo "Cleaned: $settings"
  fi

  local md="$HOME/.claude/CLAUDE.md"
  if [[ -f "$md" ]]; then
    python3 - "$md" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    s = f.read()
s = re.sub(
    r'<!-- pupbox:python-policy:start -->.*?<!-- pupbox:python-policy:end -->\n?',
    '', s, flags=re.DOTALL)
s = s.rstrip() + ('\n' if s.strip() else '')
with open(path, 'w') as f:
    f.write(s)
PY
    echo "Cleaned: $md"
  fi

  echo
  echo "pupbox uninstalled. (Backup at $settings.bak remains if you want to restore.)"
}
```

- [ ] **Step 4: Run tests**

```bash
bash tests/test_installer.sh
```

Expected: `PASS 43 assertions`.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "feat(install): --uninstall flag for full reversal"
```

---

## Task 13: End-to-end smoke test

**Files:**
- Create: `tests/test_e2e.sh`

Rationale: one top-level scenario that mirrors the real user flow — install into sandboxed roots, invoke `safe-python` via an actual pipeline, verify the hook emits the right JSON when given a synthetic Claude Code tool-input, confirm idempotency of a second install.

- [ ] **Step 1: Write `tests/test_e2e.sh`**

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

tmp_home=$(make_tmp)
tmp_prefix=$(make_tmp)
trap 'rm -rf "$tmp_home" "$tmp_prefix"' EXIT

test_case "install then run a pipeline through safe-python"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
out=$(echo '<a href=hello>' | "$tmp_prefix/bin/safe-python" -c '
import sys, re
html = sys.stdin.read()
m = re.search(r"href=(\S+?)>", html)
print(m.group(1) if m else "none")
')
assert_eq "hello" "$out" "end-to-end pipeline works"

test_case "installed hook correctly fires on python3 tool-input"
hook="$tmp_home/.claude/hooks/python-nudge.sh"
out=$(printf '%s' '{"tool_input":{"command":"python3 -c \"print(1)\""}}' | "$hook")
assert_contains "$out" '"permissionDecision": "ask"' "hook asks on python3"

test_case "installed hook stays silent on safe-python tool-input"
out=$(printf '%s' '{"tool_input":{"command":"safe-python -c \"print(1)\""}}' | "$hook")
assert_eq "" "$out" "hook silent on safe-python"

test_case "settings.json has both allow rules and hook registration"
settings=$(cat "$tmp_home/.claude/settings.json")
assert_contains "$settings" '"Bash(safe-python:*)"' "safe-python allow"
assert_contains "$settings" '"Bash(safe-python3:*)"' "safe-python3 allow"
assert_contains "$settings" "python-nudge.sh" "hook command"

test_case "second install keeps things stable"
HOME="$tmp_home" PREFIX="$tmp_prefix" bash install.sh >/dev/null
allow_count=$(jq '[.permissions.allow[] | select(. == "Bash(safe-python:*)")] | length' \
              "$tmp_home/.claude/settings.json")
assert_eq "1" "$allow_count" "still no duplicate allow"

summary
```

- [ ] **Step 2: Run it**

```bash
bash tests/test_e2e.sh
```

Expected: `PASS 7 assertions`.

- [ ] **Step 3: Commit**

```bash
git add tests/test_e2e.sh
git commit -m "test: end-to-end install + pipeline + hook + idempotency"
```

---

## Task 14: Single `tests/run-all.sh` entry point

**Files:**
- Create: `tests/run-all.sh`

Rationale: single command to run every test file, useful for CI and local sanity checks before publishing.

- [ ] **Step 1: Write `tests/run-all.sh`**

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

failed=0
for t in tests/test_*.sh; do
  echo "=== $t ==="
  bash "$t" || failed=$((failed+1))
  echo
done

if (( failed > 0 )); then
  echo "$failed test file(s) failed."
  exit 1
fi
echo "All test files passed."
```

- [ ] **Step 2: Make it executable and run**

```bash
chmod +x tests/run-all.sh
bash tests/run-all.sh
```

Expected: all four test files report PASS; final line `All test files passed.`

- [ ] **Step 3: Commit**

```bash
git add tests/run-all.sh
git commit -m "test: aggregate runner for all test files"
```

---

## Task 15: README finalization + the one-liner

**Files:**
- Modify: `README.md`

Rationale: the stub from Task 1 referenced a placeholder GitHub URL. After the installer works end-to-end, replace it with the real URL the user will host at, and flesh out usage + troubleshooting.

- [ ] **Step 1: Overwrite `README.md` with the finalized version**

```markdown
# pupbox — safe-python for Claude Code

A sandboxed Python wrapper that Claude Code can invoke freely as a text
processor without permission prompts. Runs `/usr/bin/python3` under
[bubblewrap](https://github.com/containers/bubblewrap) with:

- **no network** (`--unshare-all`)
- **read-only root filesystem** (`--ro-bind / /`)
- **ephemeral `/tmp`, `/run`, and `$HOME`** (writes vanish on exit)

Real `python3` still works — it just prompts with a reminder to prefer
`safe-python` unless you truly need network, file writes, or subprocess.

## Install

    curl -fsSL https://raw.githubusercontent.com/<you>/pupbox/main/install.sh | bash

Or, if you've cloned the repo:

    bash install.sh

Requires Linux with `bwrap`, `jq`, and `python3`:

    sudo apt install bubblewrap jq python3

## What it changes

- Drops `safe-python` and `safe-python3` into `/usr/local/bin/` (one `sudo` prompt).
- Writes `~/.claude/hooks/python-nudge.sh`.
- Merges into `~/.claude/settings.json`:
  - `permissions.allow` gains `Bash(safe-python:*)` and `Bash(safe-python3:*)`.
  - `hooks.PreToolUse` gains a Bash-matcher hook that runs `python-nudge.sh`.
- Upserts a `## Python execution policy` section (delimited by HTML comment
  markers) in `~/.claude/CLAUDE.md`.

Original `settings.json` is backed up to `settings.json.bak` on first run.

## Uninstall

    bash install.sh --uninstall

## Verify

    echo '<a href=x>' | safe-python -c '
    import sys, re
    print(re.search(r"href=(\S+?)>", sys.stdin.read()).group(1))
    '
    # -> x

    safe-python -c 'import socket; socket.socket().connect(("1.1.1.1", 80))'
    # -> PermissionError / BlockingIOError

## Development

    bash tests/run-all.sh
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: finalize README with install, uninstall, verify sections"
```

---

## Self-Review

**Spec coverage:**
- One-line installer — Task 11 (`curl | bash` works because `install.sh` is self-contained).
- Installs `safe-python` and `safe-python3` — Task 7.
- Configures Claude to prefer them — Tasks 9 (allow rules), 10 (CLAUDE.md policy).
- Escape hatch for real `python3` — Tasks 4 + 9 (hook gives ask+reason, not deny).
- Doesn't touch the user's own shell — confirmed: no PATH hacks, no aliases, no shell rc edits.
- Idempotent — Tasks 7, 9, 10, 11 each test a second run.
- Reversible — Task 12 (`--uninstall`).

**Placeholder scan:** No TBDs, no "add error handling", no "similar to Task N". Every step has the full content needed.

**Type/name consistency:** functions `check_deps`, `install_bins`, `install_hook`, `merge_settings`, `upsert_claude_md`, `run_install`, `run_uninstall`, `_maybe_sudo` — all used consistently across tasks. Variables `SAFE_PYTHON_SCRIPT`, `PYTHON_NUDGE_SCRIPT` defined in Task 5, referenced in Tasks 7 and 8. Markers `pupbox:python-policy:start`/`end` consistent between Tasks 10 and 12.

**Two known risks to watch during execution:**

1. **`bwrap` unprivileged user namespaces on Ubuntu 24.04+.** If Task 3's test fails with "setting up uid map", the host has AppArmor's `kernel.apparmor_restrict_unprivileged_userns=1`. The fix is out-of-band: `sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0` (or configure a named AppArmor profile). Document this in `README.md` if it bites the user on install.

2. **`jq`'s deep-merge with dedupe (Task 9, Step 3).** The custom `merge`/`union_dedupe` function is subtle. If the idempotency test fails, inspect the merged JSON manually and check whether hook-object equality compares the full nested structure (it should, because `. == $x` is deep). If `jq` versions differ in behavior here, switching to a Python-based merger is a straightforward fallback.