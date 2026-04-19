# Design: `unjailed` command

## Problem

The `jailed-hook.sh` PreToolUse hook rewrites listed commands (from `~/.config/jailed/commands`) to run under `jailed`, transparently and without approval prompts. The hook is registered globally, so every Claude Code session gets this behavior. Users sometimes want the *opposite* for a particular session — let the hook stand down, so Bash calls go through the usual permission prompts and Claude can (after approval) use network / writable FS.

Requirements:

1. Opt-in "hook disabled" mode per Claude invocation.
2. Nested Claude invocations (e.g. child Claude spawned by a parent via the Bash tool) inherit the parent's state.
3. Claude itself must not be able to disable the hook from within a jailed session.

## Solution

A new binary `bin/unjailed`. Invocation: `unjailed <cmd> [args...]`. It exports `UNJAILED=1` and `exec`s its argv. For non-`claude` targets it is a harmless no-op — nothing reads `UNJAILED` except the hook.

The hook checks `UNJAILED` but does not trust it blindly. Before skipping the rewrite, it validates via a process-ancestry walk.

### Validation rule

The hook walks ancestors via `ps -o ppid=,comm=` starting from its own PID. It finds the **topmost** ancestor whose `comm` is `claude`. The hook trusts `UNJAILED=1` only when the parent of that topmost `claude` process is `unjailed`.

Coverage:

| Scenario | Chain (hook → ... → root) | Topmost-claude parent | Rewrite? |
|---|---|---|---|
| Legit unjailed | `hook → claude → unjailed → shell` | `unjailed` | no |
| Nested claude (parent unjailed) | `hook → claude → bash → claude → unjailed → shell` | `unjailed` | no |
| Attack: `UNJAILED=1 claude -p ...` from Bash tool | `hook → child_claude → bash → parent_claude → shell` | `shell` | yes |
| Attack: `unjailed claude -p ...` from Bash tool | `hook → child_claude → unjailed → bash → parent_claude → shell` | `shell` | yes |
| Default jailed | `hook → claude → shell` | `shell` | yes |
| No claude in ancestry (weird) | — | — | yes |

`unjailed` stays dumb. All trust logic lives in the hook.

### Out of scope (user-level trust boundary)

- Claude overwriting `bin/unjailed` at its installed path.
- Claude dropping a fake binary named `claude` or `unjailed` on PATH to trick `comm=` lookups.

If Claude can write to `$PREFIX/bin` or manipulate `$PATH` in ways that change what the OS reports as `comm`, the user's account is already compromised. Out of scope.

## Components

### 1. `bin/unjailed`

Tiny bash wrapper. Sets `UNJAILED=1` and `exec`s argv. Mirrors `bin/jailed`'s style (`set -u`, usage message on zero args, exported env var).

```bash
#!/usr/bin/env bash
set -u
if (( $# == 0 )); then
  echo "usage: unjailed <cmd> [args...]" >&2
  exit 2
fi
export UNJAILED=1
exec "$@"
```

### 2. Hook changes (`hooks/jailed-hook.sh`)

Add a validator function, called before the existing rewrite logic:

```bash
if [[ "${UNJAILED:-}" == "1" ]] && is_unjailed_trusted; then
  exit 0
fi
```

`is_unjailed_trusted` walks `ps -o ppid=,comm=` from `$$` upward, tracks the topmost `claude` PID, and returns success iff the parent of that PID has `comm == unjailed`.

For testability, ancestry lookup is factored behind an indirection:

- Default: `ps -o ppid=,comm= -p <pid>`.
- Test override: if `JAILED_ANCESTRY_FIXTURE` is set and points to a file, read `<pid> <ppid> <comm>` lines from it. Tests synthesize any process tree they want without fork()ing real `claude` binaries.

This keeps tests fast and cross-platform (macOS/Linux).

### 3. Installer (`install.sh`)

- Embed byte-identical copy of `bin/unjailed` as `UNJAILED_SCRIPT` heredoc, next to `JAILED_SCRIPT`.
- `install_bins` writes `$PREFIX/bin/unjailed` alongside `$PREFIX/bin/jailed`, both chmod 755.
- `--uninstall` removes `$PREFIX/bin/unjailed`.
- Migration path: no legacy name to prune — `unjailed` is new.

### 4. Tests

New test file `tests/test_unjailed.sh` (focused unit tests of the hook's trust check + `unjailed` binary):

1. `UNJAILED=1` + fixture with `hook → claude → unjailed → shell` → no rewrite.
2. `UNJAILED=1` + fixture with nested `claude → bash → claude → unjailed → shell` → no rewrite.
3. `UNJAILED=1` + attack fixture `child_claude → bash → parent_claude → shell` → rewrite.
4. `UNJAILED=1` + attack fixture `child_claude → unjailed → bash → parent_claude → shell` → rewrite (claude above the unjailed).
5. `UNJAILED=1` + no `claude` in ancestry → rewrite (fall-through).
6. No `UNJAILED` → rewrite (regression).
7. `unjailed echo hello` exports `UNJAILED=1` (verified by spawning `unjailed env` and grepping).
8. `unjailed` with zero args prints usage and exits 2.

Extensions to existing test files:

- `tests/test_installer.sh`: add a case that `install_bins` installs both `jailed` and `unjailed`; add a case that `UNJAILED_SCRIPT` embedded content byte-matches `bin/unjailed`; extend the uninstall test to assert `unjailed` is removed.
- `tests/test_e2e.sh`: add a case that the installed `unjailed` wrapper sets `UNJAILED=1` in the child environment.

## Data flow

```
User                                      Hook (per Bash tool call)
----                                      ------------------------
$ unjailed claude
  → UNJAILED=1 in env
  → exec claude                           Claude spawns hook with UNJAILED=1 in env
                                          Hook: UNJAILED is set
                                          Hook: walk ancestry, topmost claude's parent is `unjailed`
                                          Hook: exit 0 (no rewrite, normal permission prompt flow)

$ claude                                  (no UNJAILED)
  → exec claude                           Hook: UNJAILED unset → rewrite as normal
```

## Non-goals

- Partial disabling (allow hook for some commands but not others). Out of scope — keep the knob binary.
- Configuration file toggles. Env var + command wrapper is enough.
- Windows support. The rest of the repo is macOS/Linux only.

## Risks

- **`ps` output portability.** `ps -o ppid=,comm= -p <pid>` works on both macOS BSD `ps` and Linux procps `ps`. On Linux we could alternatively read `/proc/<pid>/stat`, but sticking to `ps` keeps one code path.
- **`comm` truncation.** Linux truncates `comm` to 15 chars. `claude` (6) and `unjailed` (8) are both safe. Worth leaving a comment near the validator.
- **Startup cost.** The ancestry walk adds a few `ps` invocations per Bash tool call. Typically ≤ 5 ancestors; negligible.
