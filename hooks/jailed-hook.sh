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
    # the topmost claude, the parent is unreachable (pid<=1, cycle, or a
    # dead process) — all of which mean it cannot be `unjailed`. Distrust.
    if topmost + 1 >= len(chain):
        return None
    return chain[topmost + 1][1]

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

cfg="${JAILED_CONFIG:-$HOME/.config/jailed/commands}"
targets=()
if [[ -f "$cfg" ]]; then
  # bash 3.2-compatible (no mapfile): read lines into the array, dropping
  # blanks and # comments.
  while IFS= read -r line; do
    targets+=("$line")
  done < <(grep -vE '^[[:space:]]*(#|$)' "$cfg")
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
pattern = rf'(^|[|&;`({{]|\$\()(\s*)({alt_re})\b'
def sub(m):
    start, end = m.start(3), m.end(3)
    # Skip version-suffixed binaries (python3.11, python3.12, ...).
    # \b matches between a word char and `.`, so the bare \b anchor at
    # the tail doesn't reject them. Look one char past the match.
    if end < len(cmd) and cmd[end] == '.' and end + 1 < len(cmd) and cmd[end+1].isdigit():
        return m.group(0)
    # Don't double-jail: if the preceding token was already `jailed`,
    # leave it alone.
    preceding = cmd[:start].rstrip()
    if preceding.endswith('jailed'):
        return m.group(0)
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
