# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

pupbox ships `safe-python` — a sandboxed wrapper around `/usr/bin/python3` — plus a Claude Code integration that pre-approves it and nudges Claude away from raw `python3`. Supported on **Linux** (via `bwrap`) and **macOS** (via `sandbox-exec`). The full test suite passes on both.

## Common commands

```bash
bash tests/run-all.sh              # run full test suite
bash tests/test_installer.sh       # run one test file
bash install.sh --help             # installer CLI
HOME=/tmp/h PREFIX=/tmp/p bash install.sh           # sandboxed install for manual checks
HOME=/tmp/h PREFIX=/tmp/p bash install.sh --uninstall
```

No build, no lint, no package manager — it's bash + a single installer script.

## Architecture

Three user-visible artifacts, plus an installer that stitches them into Claude Code:

1. **`bin/safe-python`** — branches on `uname`:
   - **Linux:** `exec bwrap --ro-bind / / --unshare-all --tmpfs $HOME ... /usr/bin/python3`. Read-only FS, no network, ephemeral tmpfs for `$HOME`/`/tmp`/`/run`, dies with parent.
   - **macOS:** `exec sandbox-exec -p '<SBPL>' /usr/bin/python3`. Seatbelt profile: `(deny default)` + `(allow file-read*)` + `(deny network*)` + narrow `(allow file-write*)` for `/dev/null`, `/dev/std{out,err}`, `/dev/tty`, `/dev/fd/*`, `/dev/ttys*`. No tmpfs; writes outside those sinks fail outright. Requires Xcode CLT so `/usr/bin/python3` resolves.
2. **`hooks/python-nudge.sh`** — Claude Code `PreToolUse` hook. Reads the tool-call JSON on stdin, matches `python`/`python3` as a standalone command (anchored at start-of-string or after `|&;`` `$(`), and emits an `ask` permissionDecision with a reason pointing to `safe-python`. Silent on `safe-python`, `pytest`, `python3.11`, etc.
3. **`install.sh`** — single-file installer. Writes binaries to `$PREFIX/bin` (sudo iff not writable), hook to `$HOME/.claude/hooks/`, deep-merges `$HOME/.claude/settings.json` (adds allow rules + hook registration), and upserts an HTML-comment-delimited `## Python execution policy` block into `$HOME/.claude/CLAUDE.md`.

### Two non-obvious invariants

- **`install.sh` embeds byte-identical copies of `bin/safe-python` and `hooks/python-nudge.sh` as heredoc strings** (`SAFE_PYTHON_SCRIPT`, `PYTHON_NUDGE_SCRIPT`). This is what makes `curl | bash` work with no other files. `tests/test_installer.sh` fails if the embedded copies diverge from the source files — **edit both when changing either.**
- **Every installer step must be idempotent and reversible.** `merge_settings` dedupes by structural equality (allow list + PreToolUse hook block). `upsert_claude_md` strips anything between `<!-- pupbox:python-policy:start -->` / `:end -->` markers before re-writing. `--uninstall` must leave settings.json and CLAUDE.md clean. Tests enforce all of this.

### Installer library mode

`install.sh` checks `PUPBOX_LIB_ONLY=1` at the bottom and skips `main` when set. Tests source it this way to call individual functions (`install_bins`, `merge_settings`, `check_deps`, …) with overridden `HOME`/`PREFIX`. Preserve this entry point.

## Testing conventions

- `tests/lib.sh` provides `test_case`, `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_exit`, `summary`, `make_tmp`. Tests `cd` to repo root and `source tests/lib.sh`.
- Each test file ends with `summary` which exits non-zero on any failure.
- `run-all.sh` iterates `tests/test_*.sh` and reports aggregate pass/fail.
- `test_wrapper.sh` exercises the real sandbox — needs `bwrap` on Linux or `sandbox-exec` on macOS. The other test files run anywhere with `bash` + `jq` + `python3`.

## Settings.json merge semantics

`merge_settings` in `install.sh` is the reference: deep-merge where objects recurse, arrays concatenate then dedupe by structural equality, scalars let the patch win. When changing permission strings or hook shape, update both the embedded patch and the uninstall filter (which removes by exact match).
