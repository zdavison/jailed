#!/usr/bin/env bash
# jailed installer: generic command sandbox (via Anthropic SRT) +
# transparent rewriting hook for Claude Code.
#
# Usage:
#   curl -fsSL <url>/install.sh | bash
#   bash install.sh [--uninstall] [--help]
#
# Env vars:
#   PREFIX     Where to install binaries (default: /usr/local). Requires sudo if
#              PREFIX is not writable.
#   HOME       Root for ~/.claude/ and ~/.config/ edits (inherited).

set -euo pipefail

# -----------------------------------------------------------------------------
# Embedded assets — kept byte-identical to bin/jailed, hooks/jailed-hook.sh,
# config/commands.default, and config/srt-settings.json via
# tests/test_installer.sh. Edit both when changing either.
# -----------------------------------------------------------------------------

read -r -d '' JAILED_SCRIPT <<'JP_EOF' || true
#!/usr/bin/env bash
# jailed: run a command under Anthropic Sandbox Runtime (SRT) with a
# deny-all profile — no network, no filesystem writes, read-only view.
# SRT abstracts the platform sandbox primitive: bubblewrap on Linux,
# sandbox-exec on macOS. We configure it; we don't re-implement it.
#
# Invocation: jailed <cmd> [args...]
#
# SRT's positional-arg form joins argv with spaces and passes to a
# shell, which drops argv quoting. We use `srt -c <string>` with
# printf %q escaping so the full argv (including embedded quotes)
# survives intact through a single sh -c hop.

set -u

if (( $# == 0 )); then
  echo "usage: jailed <cmd> [args...]" >&2
  exit 2
fi

# Special case: `jailed claude` does not wrap claude in SRT (claude needs
# network, writes, and subprocess). Instead, exec claude directly. The
# PreToolUse hook reads process ancestry and activates rewriting when it
# sees a `claude` whose parent is `jailed` — which this exec sets up.
if [[ "$(basename -- "$1")" == "claude" ]]; then
  exec "$@"
fi

# Settings resolution, in priority order:
#   1. $JAILED_SRT_SETTINGS (tests and one-off overrides)
#   2. Sibling config/ of this script (dev mode: repo checkout)
#   3. $HOME/.config/jailed/srt-settings.json (installed mode)
if [[ -n "${JAILED_SRT_SETTINGS:-}" ]]; then
  settings="$JAILED_SRT_SETTINGS"
else
  here=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || true)
  dev_settings="$here/config/srt-settings.json"
  if [[ -n "$here" && -f "$dev_settings" ]]; then
    settings="$dev_settings"
  elif [[ -f "$HOME/.config/jailed/srt-settings.json" ]]; then
    settings="$HOME/.config/jailed/srt-settings.json"
  else
    echo "jailed: no SRT settings found at \$HOME/.config/jailed/srt-settings.json." >&2
    echo "      run 'bash install.sh' or set \$JAILED_SRT_SETTINGS." >&2
    exit 2
  fi
fi

# Announce to stderr so users can see jailed was used (Claude Code's TUI
# shows the command Claude *proposed*, not the hook-rewritten one, so
# without this banner a silent sandbox rewrite would be invisible).
# $1 is just the target command name; the hook-rewritten tool-call still
# shows the full argv in Claude Code.
echo "[jailed] $1" >&2

escaped=$(printf '%q ' "$@")
exec srt -s "$settings" -c "$escaped"
JP_EOF
JAILED_SCRIPT+=$'\n'

read -r -d '' JAILED_HOOK_SCRIPT <<'JP_EOF' || true
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

# --- Ancestry-driven activation ---
# The hook rewrites listed commands ONLY when process ancestry shows that
# some `claude` in the chain was launched by `jailed`. That condition is
# set exclusively by `jailed claude` (see bin/jailed). There is no env-var
# signal: a jailed Claude spawning `FOO=bar claude -p ...` cannot change
# the activation decision from inside a tool call. We match any claude→
# jailed pair in the chain (not just the topmost claude) so that nested
# scenarios — e.g. running `jailed claude` inside an existing claude
# session — activate correctly. Attackers can only ADD chain entries
# via exec-a tricks, not remove real ones, so broader matching is safe.
python3 - "$$" <<'PY'
import os, sys, subprocess

def lookup(pid):
    try:
        out = subprocess.check_output(
            ['ps', '-o', 'ppid=,comm=', '-p', str(pid)],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except Exception:
        return None
    if not out:
        return None
    parts = out.split(None, 1)
    if len(parts) < 2:
        return None
    ppid, comm = parts
    # Linux may prefix with a path or bracket kernel threads; basename
    # normalizes. BSD ps returns just the basename already. Linux truncates
    # `comm` to 15 chars — "claude" (6) and "jailed" (6) both fit.
    comm = os.path.basename(comm.strip())
    try:
        return int(ppid), comm
    except ValueError:
        return None

def any_claude_parent_is_jailed(start):
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
    for i in range(len(chain) - 1):
        if chain[i][1] == 'claude' and chain[i + 1][1] == 'jailed':
            return True
    return False

start = int(sys.argv[1])
# Exit 0 means "activate" (rewriter runs); non-zero means "stand down".
sys.exit(0 if any_claude_parent_is_jailed(start) else 1)
PY
if [[ $? -ne 0 ]]; then
  # Not inside a `jailed claude` session — do nothing.
  exit 0
fi
# --- end activation check ---

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
      additionalContext: "Commands listed in ~/.config/jailed/commands are automatically routed through `jailed` — a sandboxed wrapper with no network and no filesystem writes. Your tool call was rewritten transparently. This session is running under `jailed claude`; plain `claude` runs without jailing."
    }
  }'
fi
exit 0
JP_EOF
JAILED_HOOK_SCRIPT+=$'\n'

read -r -d '' DEFAULT_COMMANDS <<'JP_EOF' || true
# jailed: commands that Claude Code's rewriting hook automatically routes
# through the sandbox. One command per line. Blank lines and `#` comments
# are ignored. Edit ~/.config/jailed/commands to override.
#
# Rule of thumb: include Turing-complete scripting environments that
# Claude tends to invoke inline (-c / -e) as text processors. They can
# all reach network/files/subprocess if they want to, but most of the
# time Claude uses them for pure data munging. Tools with no latent
# capabilities (jq, grep, head/tail/cat/...) are deliberately omitted —
# jailing them adds overhead without adding safety.

# Python
python
python3

# JavaScript / TypeScript runtimes
node
deno
bun

# Other scripting languages
perl
ruby
php

# Classical text processors (Turing-complete: awk has system(), GNU sed
# has the `e` command and `w file`).
awk
sed
JP_EOF

read -r -d '' SRT_SETTINGS <<'JP_EOF' || true
{
  "filesystem": {
    "denyRead": [],
    "allowWrite": [],
    "denyWrite": []
  },
  "network": {
    "allowedDomains": [],
    "deniedDomains": []
  }
}
JP_EOF
SRT_SETTINGS+=$'\n'

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

check_deps() {
  local missing=()
  # srt is provided by @anthropic-ai/sandbox-runtime — it abstracts the
  # platform sandbox (bwrap on Linux, sandbox-exec on macOS) so we don't
  # need either ourselves. If srt is missing but npm is present, bootstrap
  # it automatically; otherwise fail with actionable guidance.
  if ! command -v srt >/dev/null 2>&1; then
    if command -v npm >/dev/null 2>&1; then
      echo "srt (Anthropic Sandbox Runtime) not found — installing via npm..."
      if ! npm install -g @anthropic-ai/sandbox-runtime; then
        echo "npm install failed. Install manually:" >&2
        echo "  npm install -g @anthropic-ai/sandbox-runtime" >&2
        return 1
      fi
      if ! command -v srt >/dev/null 2>&1; then
        echo "npm install completed but 'srt' is still not on PATH." >&2
        echo "Check \$(npm bin -g) is in your PATH and retry." >&2
        return 1
      fi
    else
      missing+=("srt")
    fi
  fi

  for tool in jq python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required tools: ${missing[*]}" >&2
    if [[ "${missing[*]}" == *"srt"* ]]; then
      echo "srt needs Node.js + npm. Install npm first, then:" >&2
      echo "  npm install -g @anthropic-ai/sandbox-runtime" >&2
    fi
    if [[ "$(uname 2>/dev/null)" == "Darwin" ]]; then
      echo "jq/python3 via: brew install jq python" >&2
    else
      echo "jq/python3 via: sudo apt install jq python3" >&2
    fi
    return 1
  fi
  return 0
}

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
  local jailed_target="$bindir/jailed"

  _maybe_sudo "$bindir" mkdir -p "$bindir"

  # Clean up binaries from prior renames so upgraders don't end up with
  # orphaned wrappers alongside the current `jailed`.
  for legacy in safe-python safe-python3 unjailed; do
    if [[ -e "$bindir/$legacy" || -L "$bindir/$legacy" ]]; then
      _maybe_sudo "$bindir/$legacy" rm -f "$bindir/$legacy"
      echo "Removed legacy: $bindir/$legacy"
    fi
  done

  printf '%s\n' "$JAILED_SCRIPT" | _maybe_sudo "$jailed_target" tee "$jailed_target" >/dev/null
  _maybe_sudo "$jailed_target" chmod 755 "$jailed_target"

  echo "Installed: $jailed_target"
}

install_hook() {
  local hooks_dir="$HOME/.claude/hooks"
  mkdir -p "$hooks_dir"
  # Drop any legacy hook from prior installs so upgraders don't keep both.
  for legacy in python-nudge.sh; do
    if [[ -e "$hooks_dir/$legacy" ]]; then
      rm -f "$hooks_dir/$legacy"
      echo "Removed legacy: $hooks_dir/$legacy"
    fi
  done
  local target="$hooks_dir/jailed-hook.sh"
  printf '%s\n' "$JAILED_HOOK_SCRIPT" > "$target"
  chmod 755 "$target"
  echo "Installed: $target"
}

install_config() {
  local cfg_dir="$HOME/.config/jailed"
  local cfg="$cfg_dir/commands"
  mkdir -p "$cfg_dir"
  # Never overwrite an existing user config. If present, leave it alone.
  if [[ -f "$cfg" ]]; then
    echo "Preserved existing: $cfg"
    return 0
  fi
  printf '%s' "$DEFAULT_COMMANDS" > "$cfg"
  echo "Installed: $cfg"
}

install_srt_settings() {
  local cfg_dir="$HOME/.config/jailed"
  local cfg="$cfg_dir/srt-settings.json"
  mkdir -p "$cfg_dir"
  # Never clobber an existing user-edited policy — they may have opened
  # specific domains or allowed writes for a workflow. Fresh install only.
  if [[ -f "$cfg" ]]; then
    echo "Preserved existing: $cfg"
    return 0
  fi
  printf '%s' "$SRT_SETTINGS" > "$cfg"
  echo "Installed: $cfg"
}

merge_settings() {
  local settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  [[ -f "$settings.bak" ]] || cp "$settings" "$settings.bak"

  # Strip stale allow rules and legacy hook registrations before merging,
  # so upgraders don't keep both generations side by side.
  local pruned
  pruned=$(jq '
    if .permissions.allow then
      .permissions.allow |= map(select(
        . != "Bash(safe-python:*)" and . != "Bash(safe-python3:*)"
      ))
    else . end
    | if .hooks.PreToolUse then
        .hooks.PreToolUse |= map(select(
          [.hooks[]?.command] | all(. != "$HOME/.claude/hooks/python-nudge.sh")
        ))
      else . end
  ' "$settings")
  printf '%s\n' "$pruned" > "$settings"

  local patch
  patch=$(cat <<'JSON'
{
  "permissions": {
    "allow": ["Bash(jailed:*)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/jailed-hook.sh"}]
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

strip_legacy_claude_md() {
  local md="$HOME/.claude/CLAUDE.md"
  [[ -f "$md" ]] || return 0
  # The new hook steers Claude automatically via additionalContext; no need
  # for a written policy stanza. Strip any from prior generations.
  python3 - "$md" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    s = f.read()
for start, end in (
    ('jailed-python:policy:start', 'jailed-python:policy:end'),
    ('safe-python:policy:start', 'safe-python:policy:end'),
    ('pupbox:python-policy:start', 'pupbox:python-policy:end'),
):
    s = re.sub(rf'<!-- {start} -->.*?<!-- {end} -->\n?', '', s, flags=re.DOTALL)
s = s.rstrip() + ('\n' if s.strip() else '')
with open(path, 'w') as f:
    f.write(s)
PY
}

run_install() {
  check_deps
  install_bins
  install_srt_settings
  install_config
  install_hook
  merge_settings
  strip_legacy_claude_md

  local cfg="$HOME/.config/jailed/commands"
  echo
  echo "jailed installed."
  echo
  echo "Claude's calls to these commands will be transparently sandboxed:"
  # Indent each live entry for readability. grep -v strips comments/blanks.
  grep -vE '^[[:space:]]*(#|$)' "$cfg" | sed 's/^/  /'
  echo
  echo "To enable jailing for another command (e.g. rscript):"
  echo "  echo 'rscript' >> $cfg"
  echo
  echo "To disable jailing for a command, remove or '#'-comment its line in:"
  echo "  $cfg"
  echo
  echo "Quick test:"
  echo "  echo '<a href=x>' | jailed python3 -c 'import sys; print(sys.stdin.read())'"
  echo
  echo "Jailing is opt-in. To launch Claude in a jailed session:"
  echo "  jailed claude"
  echo
  echo "Plain 'claude' runs without the hook rewriting anything."
  echo
  echo "Restart Claude Code (or run /config) to pick up the new hook and permissions."
}

usage() {
  cat <<EOF
Usage: bash install.sh [--uninstall] [--help]

Installs the jailed wrapper and configures Claude Code to transparently
route listed commands through the sandbox.

Options:
  --uninstall   Remove installed files and revert Claude Code config.
  --help        Show this message.

Env:
  PREFIX        Where binaries go (default: /usr/local). Uses sudo if needed.
EOF
}

run_uninstall() {
  local prefix="${PREFIX:-/usr/local}"
  local bindir="$prefix/bin"

  # Remove current and all legacy-generation binaries.
  for f in jailed unjailed jailed-python jailed-python3 safe-python safe-python3; do
    if [[ -e "$bindir/$f" || -L "$bindir/$f" ]]; then
      _maybe_sudo "$bindir/$f" rm -f "$bindir/$f"
      echo "Removed: $bindir/$f"
    fi
  done

  # Current hook + legacy hook.
  for hook_name in jailed-hook.sh python-nudge.sh; do
    local hpath="$HOME/.claude/hooks/$hook_name"
    [[ -e "$hpath" ]] && { rm -f "$hpath"; echo "Removed: $hpath"; }
  done

  local settings="$HOME/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    jq '
      if .permissions.allow then
        .permissions.allow |= map(select(
          . != "Bash(jailed:*)"          and . != "Bash(jailed-python:*)" and
          . != "Bash(jailed-python3:*)"  and
          . != "Bash(safe-python:*)"     and . != "Bash(safe-python3:*)"
        ))
      else . end
      | if .hooks.PreToolUse then
          .hooks.PreToolUse |= map(select(
            [.hooks[]?.command] | all(
              . != "$HOME/.claude/hooks/jailed-hook.sh" and
              . != "$HOME/.claude/hooks/python-nudge.sh"
            )
          ))
        else . end
    ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    echo "Cleaned: $settings"
  fi

  strip_legacy_claude_md
  [[ -f "$HOME/.claude/CLAUDE.md" ]] && echo "Cleaned: $HOME/.claude/CLAUDE.md"

  echo
  echo "jailed uninstalled. (Backup at $settings.bak remains if you want to restore.)"
  echo "Your configs at ~/.config/jailed/ were left in place."
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --uninstall) run_uninstall ;;
    "") run_install ;;
    *) usage; exit 2 ;;
  esac
}

# If sourced by the test harness (JAILED_PYTHON_LIB_ONLY=1), stop after defining vars
# — this is how tests call individual functions with overridden HOME/PREFIX.
if [[ -z "${JAILED_PYTHON_LIB_ONLY:-}" ]]; then
  main "$@"
fi
