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
