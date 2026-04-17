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

## Known issue

On Ubuntu 24.04+ with AppArmor restricting unprivileged user namespaces,
`bwrap` may fail with `setting up uid map`. Fix:

    sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
