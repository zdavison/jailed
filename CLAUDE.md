# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

This repo ships `jailed` — a thin wrapper around Anthropic Sandbox Runtime (`srt`) configured for deny-all (no network, no writes) — plus a Claude Code PreToolUse hook that transparently rewrites listed commands (from `~/.config/jailed/commands`) to run through `jailed`. Supported on **Linux** and **macOS** — SRT handles the platform difference (bwrap vs sandbox-exec).

Rename history: `pupbox` → `safe-python` → `jailed-python` → current generic `jailed`. Installer migration code silently removes legacy binaries, allow rules, hook registrations, and CLAUDE.md marker blocks from every prior generation. Don't delete that code without a replacement plan — there are real users with those prior-generation artifacts.

## Common commands

```bash
bash tests/run-all.sh              # run full test suite (4 files)
bash tests/test_jailed.sh          # one file at a time
bash install.sh --help             # installer CLI
HOME=/tmp/h PREFIX=/tmp/p bash install.sh           # sandboxed install for manual checks
HOME=/tmp/h PREFIX=/tmp/p bash install.sh --uninstall
```

No build, no lint, no package manager — bash + a single installer script.

## Architecture

Three user-visible artifacts + an installer that stitches them into Claude Code:

1. **`bin/jailed`** — ~30-line bash wrapper. `jailed <cmd> [args…]` resolves an SRT settings file (env override → repo-local dev file → `~/.config/jailed/srt-settings.json`), then `exec srt -s <settings> -c <printf-%q-escaped-argv>`. We use SRT's `-c` with `printf %q` escaping because SRT's positional-arg form joins argv with spaces through a shell, which drops quoting.
2. **`hooks/jailed-hook.sh`** — PreToolUse hook. Reads `$JAILED_CONFIG` (tests) or `~/.config/jailed/commands` (runtime) or falls back to built-in defaults. For each listed command, rewrites occurrences at shell-token boundaries (`^`, `|`, `&`, `;`, `` ` ``, `$(`, `(`, `{`) to prepend `jailed`. Emits `permissionDecision: allow` + `updatedInput.command` — so Bash runs the rewritten command without prompting.
3. **`config/commands.default`** — packaged default list of commands to auto-jail. Installed to `~/.config/jailed/commands` only if absent. Plus `config/srt-settings.json` → `~/.config/jailed/srt-settings.json`, same no-overwrite semantics. User edits are sacred.

### Non-obvious invariants

- **`install.sh` embeds byte-identical copies** of `bin/jailed`, `hooks/jailed-hook.sh`, `config/commands.default`, and `config/srt-settings.json` as heredoc strings (`JAILED_SCRIPT`, `JAILED_HOOK_SCRIPT`, `DEFAULT_COMMANDS`, `SRT_SETTINGS`). Makes `curl | bash` work with no other files. `tests/test_installer.sh` fails if any embedded copy diverges from its source — **edit both when changing either.**
- **Every installer step is idempotent, reversible, and rename-safe.** `install_bins` removes legacy `safe-python`/`safe-python3` before writing the current generation. `install_hook` removes legacy `python-nudge.sh` before writing `jailed-hook.sh`. `install_config` and `install_srt_settings` never overwrite existing user files. `merge_settings` prunes legacy `Bash(safe-python:*)` allow rules and `python-nudge.sh` hook registrations before merging. `strip_legacy_claude_md` removes every generation of policy marker blocks. `--uninstall` removes all generations of binaries, allow rules, and hook registrations — but leaves `~/.config/jailed/` (user data) in place. Tests enforce every one of these.
- **Hook rewrite is string-regex, not AST.** Known false negatives: `env FOO=bar python3` (command not at a token boundary). Known false positives: listed command tokens appearing inside single-quoted strings that also contain `;` or `|`. Version-suffixed binaries (`python3.11`) are explicitly excluded via a post-match char check in the Python rewriter. Acceptable for MVP; if we ever need precision, move to a bash-AST-aware rewriter.
- **macOS bash is 3.2.** The hook avoids `mapfile` (bash 4+) and carefully initializes arrays so `set -u` is safe even on empty config files. Keep that discipline.
- **Python `re` regex quirks:** don't use POSIX `[[:space:]]` inside the hook — Python treats it as a nested set with a FutureWarning and won't match. Use `\s`.

### Installer library mode

`install.sh` checks `JAILED_PYTHON_LIB_ONLY=1` at the bottom and skips `main` when set. Tests source it this way to call individual functions (`install_bins`, `install_hook`, `install_config`, `install_srt_settings`, `merge_settings`, `strip_legacy_claude_md`, `check_deps`, …) with overridden `HOME`/`PREFIX`. Preserve this entry point. (Env var name retained from the previous generation — renaming it to `JAILED_LIB_ONLY` would be a cosmetic refactor, not touching it unless we're already there.)

## Testing conventions

- `tests/lib.sh` provides `test_case`, `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_exit`, `summary`, `make_tmp`. Tests `cd` to repo root and `source tests/lib.sh`.
- Each test file ends with `summary` which exits non-zero on any failure.
- `run-all.sh` iterates `tests/test_*.sh` and reports aggregate pass/fail.
- **`test_jailed.sh`** exercises the real sandbox via `bin/jailed` — needs `srt` on PATH.
- **`test_hook.sh`** exercises the rewriter purely as a string-transformer — runs anywhere with `bash`/`jq`/`python3`.
- **`test_installer.sh`** exercises individual installer functions in sandboxed HOME/PREFIX — no `srt` needed for most assertions (except the "installed wrapper still functions" case which sets `JAILED_SRT_SETTINGS` to the repo's config file explicitly).
- **`test_e2e.sh`** does a full install + invokes the installed binary + feeds JSON through the installed hook. Needs `srt`.
- Migration tests (seeded legacy state → install/uninstall → assert clean) live in `test_installer.sh`; keep one per legacy generation. They use old marker/binary names *intentionally* — don't "clean them up" into current names.

## Settings.json merge semantics

`merge_settings` in `install.sh` is the reference: first prune stale `Bash(safe-python:*)` rules and legacy `python-nudge.sh` hook registrations, then deep-merge where objects recurse, arrays concatenate then dedupe by structural equality, scalars let the patch win. When changing permission strings or hook shape, update the embedded patch, the uninstall filter (which removes by exact match across all generations), and the prune list.
