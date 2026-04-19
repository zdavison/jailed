# `unjailed` Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a new `unjailed` wrapper binary and teach the PreToolUse hook to stand down for Claude sessions launched through it, without letting a running (jailed) Claude disable its own hook.

**Architecture:** `unjailed` is a 10-line bash script that exports `UNJAILED=1` and `exec`s argv. The hook checks `UNJAILED` but only trusts it after a process-ancestry walk confirms that the topmost `claude` ancestor's parent is `unjailed`. A fixture-file env override makes the ancestry walk fully unit-testable.

**Tech Stack:** bash (3.2 compatible), inline python3 (already a hook dep), jq (already a hook dep), `ps -o ppid=,comm=` (portable across macOS BSD `ps` and Linux procps `ps`).

---

## File Structure

**New files**
- `bin/unjailed` — wrapper. Sets `UNJAILED=1`, execs argv.
- `tests/test_unjailed.sh` — unit tests for the wrapper + for the hook's trust validator (using fixture-backed ancestry).

**Modified files**
- `hooks/jailed-hook.sh` — early-exit short-circuit when `UNJAILED=1` and ancestry validates.
- `install.sh` — embed `UNJAILED_SCRIPT` heredoc; install + uninstall `unjailed` binary.
- `tests/test_installer.sh` — parity assertion for `UNJAILED_SCRIPT`; install + uninstall coverage.
- `tests/test_e2e.sh` — end-to-end check that installed `unjailed` exports `UNJAILED=1`.

---

## Task 1: Create `bin/unjailed`

**Files:**
- Create: `bin/unjailed`
- Test: `tests/test_unjailed.sh` (create; further tasks will extend it)

- [ ] **Step 1: Create the test file with a failing usage test**

Create `tests/test_unjailed.sh`:

```bash
#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

UNJAILED="bin/unjailed"

# ---- bin/unjailed wrapper ----

test_case "unjailed with no args prints usage and exits 2"
out=$(bash "$UNJAILED" 2>&1; echo "exit=$?")
assert_contains "$out" "usage: unjailed" "must print usage on zero args"
assert_contains "$out" "exit=2" "must exit 2 on zero args"

test_case "unjailed execs argv with UNJAILED=1 in env"
# Use env(1) as the child so we can read its environment.
out=$(bash "$UNJAILED" env | grep '^UNJAILED=' || true)
assert_eq "UNJAILED=1" "$out" "UNJAILED=1 must be exported to the child"

test_case "unjailed preserves argv quoting to the child"
# Pass an argument with a space; child should see it as a single arg.
out=$(bash "$UNJAILED" python3 -c 'import sys; print("|".join(sys.argv[1:]))' "a b" "c")
assert_eq "a b|c" "$out" "argv must survive intact (no shell re-splitting)"

summary
```

- [ ] **Step 2: Run the test to confirm it fails**

Run: `bash tests/test_unjailed.sh`
Expected: FAIL — file `bin/unjailed` does not exist; bash reports "No such file or directory".

- [ ] **Step 3: Create `bin/unjailed`**

Create `bin/unjailed`:

```bash
#!/usr/bin/env bash
# unjailed: run a command with UNJAILED=1 in its env.
# The jailed-hook's default behavior is to rewrite listed commands to run
# through the `jailed` sandbox. When Claude Code is launched as
# `unjailed claude`, the hook sees UNJAILED=1 in its inherited env and,
# after validating via a process-ancestry check that the value was set by
# this wrapper (and not spoofed by a jailed Claude), stands down — so the
# user gets normal permission prompts and unsandboxed execution.
#
# For any non-`claude` target this wrapper is a harmless no-op: nothing
# else on the system reads UNJAILED.
#
# Trust model: see docs/superpowers/specs/2026-04-19-unjailed-command-design.md.

set -u

if (( $# == 0 )); then
  echo "usage: unjailed <cmd> [args...]" >&2
  exit 2
fi

export UNJAILED=1
exec "$@"
```

Then make it executable:

```bash
chmod 755 bin/unjailed
```

- [ ] **Step 4: Run the test; verify it passes**

Run: `bash tests/test_unjailed.sh`
Expected: PASS 3+ assertions.

- [ ] **Step 5: Commit**

```bash
git add bin/unjailed tests/test_unjailed.sh
git commit -m "$(cat <<'EOF'
feat: add unjailed wrapper that exports UNJAILED=1

The wrapper is a no-op for any command except Claude Code: it sets
UNJAILED=1 in the child's env and execs argv. The companion hook change
(next commit) teaches the jailed hook to stand down for Claude sessions
launched through unjailed, after validating ancestry.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add trust-validator (ancestry walk) to the hook

The validator must be driven by a fixture file in tests — actual process-tree manipulation from bash is impractical.

**Files:**
- Modify: `hooks/jailed-hook.sh` (insert a trust-check block immediately after the existing `[[ -z "$cmd" ]] && exit 0` guard)
- Test: `tests/test_unjailed.sh` (extend)

- [ ] **Step 1: Write fixture-based trust tests (failing)**

Append to `tests/test_unjailed.sh` (before the final `summary`):

```bash
# ---- Hook trust validator ----

HOOK="hooks/jailed-hook.sh"
CFG_DIR=$(make_tmp)
CFG="$CFG_DIR/commands"
printf 'python3\npython\njq\n' > "$CFG"

# Helper: run the hook against a python3 command, with a synthetic ancestry
# fixture. Returns the hook's stdout. Empty stdout means "no rewrite".
run_hook_fixture() {
  local fixture_file="$1"
  local unjailed_val="$2"   # "1" or "" (empty = unset)
  local start_pid="$3"      # synthetic pid that stands in for $$
  local env_unjailed=()
  [[ -n "$unjailed_val" ]] && env_unjailed=(UNJAILED="$unjailed_val")
  printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' \
    | env "${env_unjailed[@]}" \
          JAILED_CONFIG="$CFG" \
          JAILED_ANCESTRY_FIXTURE="$fixture_file" \
          JAILED_ANCESTRY_START="$start_pid" \
          bash "$HOOK"
}

# Fixture format: `<pid> <ppid> <comm>` one per line.

test_case "UNJAILED=1 + legit unjailed ancestry → no rewrite"
f=$(make_tmp)/fix
cat > "$f" <<'EOF'
100 50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_eq "" "$out" "hook must stand down when topmost claude's parent is unjailed"

test_case "UNJAILED=1 + nested claude under unjailed → no rewrite"
# Ancestry: self(100)=claude → 90=bash → 80=claude → 50=unjailed → 10=bash
cat > "$f" <<'EOF'
100 90 claude
90  80 bash
80  50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_eq "" "$out" "nested claude under unjailed must still be trusted"

test_case "UNJAILED=1 + attack (UNJAILED=1 claude -p from bash tool) → rewrite"
# Ancestry: child_claude(100) → bash(90) → parent_claude(80) → shell(10)
# UNJAILED=1 was injected by parent claude; no unjailed ancestor.
cat > "$f" <<'EOF'
100 90 claude
90  80 bash
80  10 claude
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_contains "$out" "jailed python3" "attack must be rejected → rewrite happens"

test_case "UNJAILED=1 + attack (unjailed claude -p from bash tool) → rewrite"
# Ancestry: child_claude(100) → unjailed(95) → bash(90) → parent_claude(80) → shell(10)
# Topmost claude is 80; its parent is shell, not unjailed.
cat > "$f" <<'EOF'
100 95 claude
95  90 unjailed
90  80 bash
80  10 claude
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_contains "$out" "jailed python3" "claude above unjailed must flip to distrust"

test_case "UNJAILED=1 + no claude in ancestry → rewrite"
cat > "$f" <<'EOF'
100 50 python3
50  10 bash
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_contains "$out" "jailed python3" "no claude ancestor → distrust UNJAILED"

test_case "UNJAILED unset → hook rewrites as normal (regression)"
cat > "$f" <<'EOF'
100 50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "" "100")
assert_contains "$out" "jailed python3" "no UNJAILED → rewrite regardless of ancestry"

rm -rf "$CFG_DIR"
```

- [ ] **Step 2: Run the tests to confirm they fail**

Run: `bash tests/test_unjailed.sh`
Expected: All 6 trust-validator tests FAIL — the hook currently ignores `UNJAILED` and always rewrites. (Task 1 tests still pass.)

- [ ] **Step 3: Add the trust-check block to the hook**

Edit `hooks/jailed-hook.sh`. After the existing line `[[ -z "$cmd" ]] && exit 0` and before the `cfg=` line, insert:

```bash
# --- Trust check for UNJAILED ---
# If UNJAILED=1 is set AND process ancestry shows this hook was launched by
# a `claude` whose topmost-claude-ancestor's parent is `unjailed`, stand
# down (no rewrite → normal permission prompts). Anything else — including
# a jailed Claude spawning `UNJAILED=1 claude -p ...` to forge the env var
# — fails the check and we continue with the usual rewrite.
#
# Ancestry lookup: real `ps` by default; fixture file for tests.
if [[ "${UNJAILED:-}" == "1" ]]; then
  start_pid="${JAILED_ANCESTRY_START:-$$}"
  python3 - "$start_pid" <<'PY'
import os, sys, subprocess

fixture = os.environ.get('JAILED_ANCESTRY_FIXTURE') or ''

def lookup_ps(pid):
    try:
        out = subprocess.check_output(
            ['ps', '-o', 'ppid=,comm=', '-p', str(pid)],
            stderr=subprocess.DEVNULL,
        ).decode()
    except Exception:
        return None
    out = out.strip()
    if not out:
        return None
    parts = out.split(None, 1)
    if len(parts) < 2:
        return None
    ppid, comm = parts
    # On Linux, `comm` can include a leading path or brackets; basename
    # is good enough for our targets ("claude", "unjailed"). macOS BSD
    # `ps` prints just the basename already.
    comm = os.path.basename(comm.strip())
    try:
        return int(ppid), comm
    except ValueError:
        return None

def lookup_fixture(pid):
    try:
        with open(fixture) as f:
            for line in f:
                parts = line.strip().split(None, 2)
                if len(parts) < 3:
                    continue
                p, pp, c = parts
                if int(p) == pid:
                    return int(pp), c
    except Exception:
        return None
    return None

def lookup(pid):
    return lookup_fixture(pid) if fixture else lookup_ps(pid)

def topmost_claude_parent_comm(start):
    # Build chain of (pid, comm) from start upward.
    chain = []
    pid = start
    seen = set()
    while pid and pid not in seen and pid != 1:
        seen.add(pid)
        res = lookup(pid)
        if not res:
            break
        ppid, comm = res
        chain.append((pid, comm))
        if ppid == 0 or ppid == pid:
            break
        pid = ppid
    # Topmost (highest-index) claude in the chain.
    topmost = -1
    for i, (_, c) in enumerate(chain):
        if c == 'claude':
            topmost = i
    if topmost < 0:
        return None
    # Parent's comm is the next entry upward. If the chain ended right at
    # the topmost claude, do a fresh lookup for its parent.
    if topmost + 1 < len(chain):
        return chain[topmost + 1][1]
    claude_pid = chain[topmost][0]
    res = lookup(claude_pid)
    if not res:
        return None
    ppid, _ = res
    res = lookup(ppid)
    if not res:
        return None
    return res[1]

start = int(sys.argv[1])
parent = topmost_claude_parent_comm(start)
sys.exit(0 if parent == 'unjailed' else 1)
PY
  if [[ $? -eq 0 ]]; then
    # Trusted unjailed session — stand down, let the Bash call go through
    # the normal permission flow.
    exit 0
  fi
  # Untrusted UNJAILED (spoofed / attack) — fall through to the rewrite.
fi
# --- end trust check ---
```

Note the `start_pid="${JAILED_ANCESTRY_START:-$$}"` — in production the hook walks from its own PID; in tests the fixture provides a synthetic start.

- [ ] **Step 4: Run the tests; all trust tests should pass**

Run: `bash tests/test_unjailed.sh`
Expected: PASS. The Task 1 tests continue to pass; the 6 trust-validator tests now pass.

Also run the full existing suite to confirm no regression:

Run: `bash tests/test_hook.sh`
Expected: PASS (no regression — `UNJAILED` unset in those tests, so the new block is a no-op).

- [ ] **Step 5: Commit**

```bash
git add hooks/jailed-hook.sh tests/test_unjailed.sh
git commit -m "$(cat <<'EOF'
feat: hook stands down for trusted UNJAILED=1 sessions

New trust check runs before the existing rewriter: if UNJAILED=1 is set
AND process ancestry confirms the topmost `claude` ancestor's parent is
`unjailed`, exit without rewriting so the Bash call goes through the
normal permission-prompt flow. Everything else falls through.

The ancestry walk uses `ps -o ppid=,comm=` (portable across macOS BSD ps
and Linux procps ps). Tests pin a synthetic ancestry via
JAILED_ANCESTRY_FIXTURE, so every attack scenario in the spec is covered
without fork()ing real binaries.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Real-process smoke test

Fixture tests verify the algorithm. This adds one cheap real-process test so we'd notice if `ps` output ever diverges from what the script parses.

**Files:**
- Modify: `tests/test_unjailed.sh` (extend)

- [ ] **Step 1: Add the smoke test**

Append to `tests/test_unjailed.sh` before the final `summary`:

```bash
# ---- Real-process smoke test ----

test_case "real ps lookup: no UNJAILED + real ancestry → rewrite happens"
# Unset JAILED_ANCESTRY_FIXTURE so the walker calls actual `ps`. With
# UNJAILED unset the trust block is skipped entirely — this just confirms
# the hook still rewrites in the normal case when running the new code
# path. (Covers "did my change accidentally break the default flow?")
tmp_cfg=$(make_tmp)/commands
printf 'python3\n' > "$tmp_cfg"
out=$(printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' \
  | JAILED_CONFIG="$tmp_cfg" bash "$HOOK")
assert_contains "$out" "jailed python3" "default flow still rewrites"

test_case "real ps lookup: UNJAILED=1 with no legit unjailed ancestor → rewrite"
# This test IS running the ancestry walk against the real process tree.
# Ancestors: bash (this test) → bash (run-all) → shell / CI. None are
# called `unjailed`, so trust check fails → rewrite.
out=$(printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' \
  | UNJAILED=1 JAILED_CONFIG="$tmp_cfg" bash "$HOOK")
assert_contains "$out" "jailed python3" "spoofed UNJAILED=1 must not bypass"
```

- [ ] **Step 2: Run the tests**

Run: `bash tests/test_unjailed.sh`
Expected: PASS (all prior tests still pass; these two pass).

- [ ] **Step 3: Commit**

```bash
git add tests/test_unjailed.sh
git commit -m "$(cat <<'EOF'
test: smoke-test real ps lookup for UNJAILED trust check

Fixture tests cover the algorithm. These two tests call the validator
without a fixture so we catch regressions in the `ps -o ppid=,comm=`
parsing path if output format ever diverges on a supported platform.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Embed `UNJAILED_SCRIPT` in install.sh and install it

**Files:**
- Modify: `install.sh` (add `UNJAILED_SCRIPT` heredoc; update `install_bins` and `run_uninstall`)
- Modify: `tests/test_installer.sh` (add parity test; extend install and uninstall tests)

- [ ] **Step 1: Write failing parity + install tests**

Edit `tests/test_installer.sh`. Immediately after the existing `"embedded JAILED_SCRIPT matches bin/jailed"` test block (~line 17), add:

```bash
test_case "embedded UNJAILED_SCRIPT matches bin/unjailed"
embedded=$(JAILED_PYTHON_LIB_ONLY=1 bash -c 'source install.sh; printf "%s" "$UNJAILED_SCRIPT"')
actual=$(cat bin/unjailed)
assert_eq "$actual" "$embedded" "embedded unjailed diverged from bin/unjailed"
```

Then, in the existing `install_bins` test block (search for `"install_bins places jailed under \$PREFIX/bin"`), append after the `[[ -x "$tmp/bin/jailed" ]]...` assertion:

```bash
[[ -x "$tmp/bin/unjailed" ]] && assert_eq "ok" "ok" "unjailed installed and executable" \
  || assert_eq "ok" "missing" "unjailed not executable or missing"
```

In the legacy-removal test block (search for `"install_bins removes legacy safe-python"`), add after the `[[ -x "$tmp/bin/jailed" ]]` check:

```bash
[[ -x "$tmp/bin/unjailed" ]] && assert_eq "ok" "ok" "unjailed still in place" \
  || assert_eq "ok" "missing" "unjailed missing after legacy cleanup"
```

In the uninstall test block (search for `"--uninstall removes binaries"`), add:

```bash
[[ ! -e "$tmp_prefix/bin/unjailed" ]] && assert_eq "ok" "ok" "unjailed removed" \
  || assert_eq "ok" "no" "unjailed still present"
```

- [ ] **Step 2: Run tests; confirm they fail**

Run: `bash tests/test_installer.sh`
Expected: FAIL on the new parity test (`UNJAILED_SCRIPT` is undefined) and on the `[[ -x "$tmp/bin/unjailed" ]]` checks.

- [ ] **Step 3: Add `UNJAILED_SCRIPT` heredoc to install.sh**

Edit `install.sh`. Immediately after the closing `JP_EOF` of `JAILED_SCRIPT` (around line 72, after `JAILED_SCRIPT+=$'\n'`), insert:

```bash
read -r -d '' UNJAILED_SCRIPT <<'JP_EOF' || true
#!/usr/bin/env bash
# unjailed: run a command with UNJAILED=1 in its env.
# The jailed-hook's default behavior is to rewrite listed commands to run
# through the `jailed` sandbox. When Claude Code is launched as
# `unjailed claude`, the hook sees UNJAILED=1 in its inherited env and,
# after validating via a process-ancestry check that the value was set by
# this wrapper (and not spoofed by a jailed Claude), stands down — so the
# user gets normal permission prompts and unsandboxed execution.
#
# For any non-`claude` target this wrapper is a harmless no-op: nothing
# else on the system reads UNJAILED.
#
# Trust model: see docs/superpowers/specs/2026-04-19-unjailed-command-design.md.

set -u

if (( $# == 0 )); then
  echo "usage: unjailed <cmd> [args...]" >&2
  exit 2
fi

export UNJAILED=1
exec "$@"
JP_EOF
UNJAILED_SCRIPT+=$'\n'
```

Keep this block byte-identical to `bin/unjailed`. The parity test from Step 1 enforces this.

- [ ] **Step 4: Update `install_bins` to install `unjailed`**

In `install.sh`, find `install_bins()` (~line 264). After the `echo "Installed: $jailed_target"` line (last line of the function body), insert:

```bash
  local unjailed_target="$bindir/unjailed"
  printf '%s\n' "$UNJAILED_SCRIPT" | _maybe_sudo "$unjailed_target" tee "$unjailed_target" >/dev/null
  _maybe_sudo "$unjailed_target" chmod 755 "$unjailed_target"
  echo "Installed: $unjailed_target"
```

- [ ] **Step 5: Update `run_uninstall` to remove `unjailed`**

In `install.sh`, find the `for f in jailed jailed-python jailed-python3 safe-python safe-python3; do` loop inside `run_uninstall()` (~line 464). Change the list to include `unjailed`:

```bash
  for f in jailed unjailed jailed-python jailed-python3 safe-python safe-python3; do
```

- [ ] **Step 6: Run tests; confirm they pass**

Run: `bash tests/test_installer.sh`
Expected: PASS. All new assertions green; no regressions in the existing suite.

- [ ] **Step 7: Commit**

```bash
git add install.sh tests/test_installer.sh
git commit -m "$(cat <<'EOF'
feat(install): ship bin/unjailed alongside bin/jailed

install_bins now writes \$PREFIX/bin/unjailed byte-identical to the
repo's bin/unjailed (enforced by the embedded-parity test). Uninstall
removes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: End-to-end test — installed `unjailed` exports `UNJAILED=1`

**Files:**
- Modify: `tests/test_e2e.sh`

- [ ] **Step 1: Add the e2e assertion**

Edit `tests/test_e2e.sh`. Before the final `summary`, append:

```bash
test_case "installed unjailed exports UNJAILED=1 to child env"
out=$("$tmp_prefix/bin/unjailed" env | grep '^UNJAILED=' || true)
assert_eq "UNJAILED=1" "$out" "installed unjailed must export UNJAILED=1"

test_case "installed unjailed with zero args exits 2 with usage"
set +e
out=$("$tmp_prefix/bin/unjailed" 2>&1); rc=$?
set -e
assert_contains "$out" "usage: unjailed" "usage text shown"
assert_eq "2" "$rc" "exit code 2"
```

- [ ] **Step 2: Run the e2e suite**

Run: `bash tests/test_e2e.sh`
Expected: PASS.

- [ ] **Step 3: Run the complete test suite**

Run: `bash tests/run-all.sh`
Expected: PASS across `test_hook.sh`, `test_installer.sh`, `test_e2e.sh`, `test_unjailed.sh`, `test_jailed.sh`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_e2e.sh
git commit -m "$(cat <<'EOF'
test: e2e coverage for installed unjailed wrapper

After a full install, exercise the installed bin/unjailed: confirm it
exports UNJAILED=1 and that zero-args invocation prints usage + exits 2.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Update CLAUDE.md architecture notes

The project doc calls out three user-visible artifacts; `unjailed` is a new fourth. Keep the doc honest.

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the architecture section**

In `CLAUDE.md`, locate the paragraph that begins:

> Three user-visible artifacts + an installer that stitches them into Claude Code:

Replace `Three` with `Four`, and after the existing item `3. **config/commands.default**...` block (before `### Non-obvious invariants`), insert:

```markdown
4. **`bin/unjailed`** — ~10-line bash wrapper. `unjailed <cmd> [args…]` exports `UNJAILED=1` and `exec`s argv. For any target except `claude` it is a harmless no-op. The hook reads `UNJAILED` but only trusts it after an ancestry walk (via `ps -o ppid=,comm=`) confirms that the topmost `claude` ancestor's parent is `unjailed` — so a jailed Claude cannot forge `UNJAILED=1` from its own Bash tool (nested claude spawns inherit, but `UNJAILED=1 claude -p …` from inside a jailed Claude fails the ancestry check).
```

Also update the `install.sh embeds byte-identical copies` invariant to mention `bin/unjailed` and `UNJAILED_SCRIPT`:

Find the sentence:

> **`install.sh` embeds byte-identical copies** of `bin/jailed`, `hooks/jailed-hook.sh`, `config/commands.default`, and `config/srt-settings.json` as heredoc strings (`JAILED_SCRIPT`, `JAILED_HOOK_SCRIPT`, `DEFAULT_COMMANDS`, `SRT_SETTINGS`).

Change to:

> **`install.sh` embeds byte-identical copies** of `bin/jailed`, `bin/unjailed`, `hooks/jailed-hook.sh`, `config/commands.default`, and `config/srt-settings.json` as heredoc strings (`JAILED_SCRIPT`, `UNJAILED_SCRIPT`, `JAILED_HOOK_SCRIPT`, `DEFAULT_COMMANDS`, `SRT_SETTINGS`).

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "$(cat <<'EOF'
docs: note bin/unjailed in CLAUDE.md architecture section

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification Summary

After all tasks, `bash tests/run-all.sh` should report:

- `test_hook.sh` — unchanged pass count (no regression).
- `test_installer.sh` — pre-existing tests + new unjailed install/uninstall/parity.
- `test_e2e.sh` — pre-existing tests + two new unjailed assertions.
- `test_unjailed.sh` — 3 wrapper tests + 6 fixture-based trust tests + 2 real-process smoke tests.
- `test_jailed.sh` — unchanged (requires `srt`; no changes needed).

All four top-level scenarios from the spec's coverage table are exercised by the fixture tests in Task 2.
