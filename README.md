# jailed

A simple command sandbox, just prefix with `jailed` to sandbox.

```bash
echo '<a href=x>' | jailed python3 -c 'import sys; print(sys.stdin.read())'
```

Built for `claude`, and on install will configure a `PreToolUse` hook that will automatically prefix uses of common inline scripting tools with `jailed`.

`jailed` commands are also automatically added to your approval whitelist, so you don't need to approve tool use requests for `jailed` commands.

## What `jailed` does

Invoked as `jailed <cmd> [args…]`. Runs the target command under
[Anthropic Sandbox Runtime](https://github.com/anthropic-experimental/sandbox-runtime)
(`srt`) with a deny-all policy:

- **no network**
- **no filesystem writes** (reads are allowed; writes to `/dev/null` and std streams still work)

SRT abstracts the platform sandbox primitive — `bubblewrap` on Linux,
`sandbox-exec` on macOS — so the same `jailed <cmd>` contract holds on
both OSes.

## Why?

I originally wrote Claude to support an unattended workflow for [pup](https://github.com/datadog-labs/pup).

When telling `claude` to investigate an issue with `pup`, it would pipe all output to `python3` to format the API responses, and repeatedly ask me to approve permissions.

I wasn't comfortable with adding a scripting environment (`python3`) to the permanent allowlist, so instead I wrote `jailed`.

The general idea is that you won't be prompted for permissions for anything thats jailed, because it should be relatively safe.

## Install

    curl -fsSL https://raw.githubusercontent.com/zdavison/jailed/main/install.sh | bash

Requires `jq` and `python3`. The installer will `npm install -g @anthropic-ai/sandbox-runtime`
automatically if `srt` isn't already on your PATH (needs Node.js + npm).

- **Linux:** `sudo apt install jq python3`, plus Node.js from whatever source you prefer.
- **macOS:** `brew install jq python` (plus Xcode Command Line Tools so `/usr/bin/python3` resolves). Node.js via `brew install node` or nvm.

## What the installer does

- Drops `jailed`, into `$PREFIX/bin/` (one `sudo` prompt).
- Writes `~/.claude/hooks/jailed-hook.sh` (the rewriting PreToolUse hook).
- Writes `~/.config/jailed/commands` **only if absent** — the default list of commands to auto-jail. Your edits survive re-installs.
- Writes `~/.config/jailed/srt-settings.json` **only if absent** — SRT's policy file (deny-all by default).
- Merges into `~/.claude/settings.json`: `permissions.allow` gains `Bash(jailed:*)`, `Bash(jailed-python:*)`, `Bash(jailed-python3:*)`; `hooks.PreToolUse` gains a Bash-matcher hook that runs `jailed-hook.sh`.

Original `settings.json` is backed up to `settings.json.bak` on first run. If you previously installed under the `safe-python` or `pupbox` names, upgrading removes all legacy binaries, allow rules, hook registrations, and policy-block markers automatically.

## Configure

**`~/.config/jailed/commands`** — one command per line, `#` for comments. Claude's calls to any listed command get rewritten to `jailed <cmd> …` transparently. Defaults cover the Turing-complete scripting environments Claude tends to use inline as text processors:

```
python  python3
node    deno    bun
perl    ruby    php
awk     sed
```

Inherently safe tools (`jq`, `grep`, `head`, `tail`, `cat`, …) are **not** jailed by default — they have no file-write / network / subprocess capability to sandbox against, so jailing them would just add overhead. Add anything else you want sandboxed (e.g. `yq`, `lua`, `Rscript`), or remove entries to run them unfettered.

**`~/.config/jailed/srt-settings.json`** — the SRT policy file. Default is
deny-all (empty `allowWrite`, empty `allowedDomains`). See the
[SRT docs](https://github.com/anthropic-experimental/sandbox-runtime#configuration)
if you want to allow specific domains or write paths.

## Uninstall

    bash install.sh --uninstall

Removes binaries, hook, and allow rules / hook registration from `settings.json` (current + all legacy generations). Leaves `~/.config/jailed/` in place (it's user data). SRT itself (the npm package) is left alone.

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

**Rewrite limitations:** the hook uses regex at shell-token boundaries. It does *not* rewrite `env FOO=bar python3 …` (command is not at a boundary) or occurrences embedded in single-quoted strings that themselves contain shell separators (e.g. `echo ';python3'`). Both edge cases are rare in Claude's typical usage; workaround is to invoke `jailed <cmd>` directly, or remove the command from `~/.config/jailed/commands`.
