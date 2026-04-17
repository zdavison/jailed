# pupbox — safe-python for Claude Code

A sandboxed Python wrapper that Claude Code can invoke freely as a text
processor without permission prompts. Runs `/usr/bin/python3` with:

- **no network**
- **read-only filesystem** (writes outside `/dev/null` and std streams fail)

Under the hood:

- **Linux:** [bubblewrap](https://github.com/containers/bubblewrap) — `--unshare-all`, `--ro-bind / /`, ephemeral tmpfs for `$HOME`, `/tmp`, `/run`.
- **macOS:** `sandbox-exec` with a Seatbelt profile that denies `network*` and `file-write*` (except `/dev` sinks). No tmpfs on Darwin, so writes fail outright rather than landing ephemerally — same no-side-effects contract.

Real `python3` still works — it just prompts with a reminder to prefer
`safe-python` unless you truly need network, file writes, or subprocess.

## Install

    curl -fsSL https://raw.githubusercontent.com/zdavison/pupbox/main/install.sh | bash

Or, if you've cloned the repo:

    bash install.sh

Requires `jq` and `python3`, plus the platform sandbox primitive:

- **Linux:** `bwrap` — `sudo apt install bubblewrap jq python3`
- **macOS:** `sandbox-exec` ships with the OS; `brew install jq python` if missing. Xcode Command Line Tools are required so `/usr/bin/python3` is functional (`xcode-select --install`).

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

## Known issues

**Ubuntu 24.04+:** AppArmor restricts unprivileged user namespaces so `bwrap` may fail with `setting up uid map`. Fix:

    sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0

**macOS:** `sandbox-exec` is officially deprecated by Apple (and still ubiquitous — WebKit, Chromium, and the OS itself use it). It prints no warning on invocation, but future macOS versions may remove it. If that happens, the sibling tool [`anthropic-experimental/sandbox-runtime`](https://github.com/anthropic-experimental/sandbox-runtime) is a drop-in with domain-allowlist support.
