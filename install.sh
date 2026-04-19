#!/usr/bin/env bash
# jailed-python installer: sandboxed python3 + Claude Code integration.
#
# Usage:
#   curl -fsSL <url>/install.sh | bash
#   bash install.sh [--uninstall] [--help]
#
# Env vars:
#   PREFIX     Where to install binaries (default: /usr/local). Requires sudo if
#              PREFIX is not writable.
#   HOME       Root for ~/.claude/ edits (inherited).

set -euo pipefail

# -----------------------------------------------------------------------------
# Embedded assets (kept byte-identical to bin/jailed, bin/jailed-python, and
# hooks/python-nudge.sh via tests/test_installer.sh).
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

escaped=$(printf '%q ' "$@")
exec srt -s "$settings" -c "$escaped"
JP_EOF
JAILED_SCRIPT+=$'\n'

read -r -d '' JAILED_PYTHON_SCRIPT <<'JP_EOF' || true
#!/usr/bin/env bash
# jailed-python: convenience shim for `jailed python3 "$@"`.
# Kept for direct human use and existing tool integrations. The generic
# `jailed` binary does all the sandboxing work.
exec "$(dirname "$0")/jailed" python3 "$@"
JP_EOF
JAILED_PYTHON_SCRIPT+=$'\n'

read -r -d '' PYTHON_NUDGE_SCRIPT <<'JP_EOF' || true
#!/usr/bin/env bash
# PreToolUse hook: nudge Claude toward jailed-python when it tries to run raw python/python3.
# - permissionDecisionReason is shown to the *user* in the approval prompt.
# - additionalContext is fed back into *Claude's* context so the model itself
#   learns to prefer jailed-python; without this, the reason is invisible to the
#   model and Claude keeps re-proposing python3.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Match python or python3 as a standalone command, anchored to start-of-string or a
# shell separator. Excludes jailed-python, jailed-python3, python3.N, pythonX, etc.
if echo "$cmd" | grep -qE '(^|[|&;`]|\$\()[[:space:]]*python3?([[:space:]]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "Prefer jailed-python (pre-approved, sandboxed: no network, no filesystem writes) for text processing. Only continue with python3 if you genuinely need network, file writes, subprocess, or full stdlib access.",
      additionalContext: "jailed-python and jailed-python3 are pre-approved, sandboxed wrappers around /usr/bin/python3 with no network access and no filesystem writes. Prefer them for text processing in pipelines (stdin->stdout, no side effects). Only reach for raw python3 when you genuinely need network, file writes, subprocess spawning, or packages outside the stdlib."
    }
  }'
fi
exit 0
JP_EOF
PYTHON_NUDGE_SCRIPT+=$'\n'

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

check_deps() {
  local missing=()
  local sandbox_tool="bwrap"
  [[ "$(uname 2>/dev/null)" == "Darwin" ]] && sandbox_tool="sandbox-exec"

  for tool in "$sandbox_tool" jq python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required tools: ${missing[*]}" >&2
    if [[ "$(uname)" == "Darwin" ]]; then
      echo "sandbox-exec ships with macOS; jq/python3 via: brew install jq python" >&2
    else
      echo "On Debian/Ubuntu: sudo apt install bubblewrap jq python3" >&2
    fi
    return 1
  fi
  return 0
}

# Run a command with sudo iff the target path is not user-writable.
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
  local target="$bindir/jailed-python"
  local link="$bindir/jailed-python3"

  _maybe_sudo "$bindir" mkdir -p "$bindir"

  # Clean up binaries from prior renames so upgraders don't end up with
  # orphaned safe-python alongside the new jailed-python.
  for legacy in safe-python safe-python3; do
    if [[ -e "$bindir/$legacy" || -L "$bindir/$legacy" ]]; then
      _maybe_sudo "$bindir/$legacy" rm -f "$bindir/$legacy"
      echo "Removed legacy: $bindir/$legacy"
    fi
  done

  # Install the generic jailed sandbox wrapper first (jailed-python shims to it).
  printf '%s\n' "$JAILED_SCRIPT" | _maybe_sudo "$jailed_target" tee "$jailed_target" >/dev/null
  _maybe_sudo "$jailed_target" chmod 755 "$jailed_target"

  # Write via tee so sudo flows naturally.
  printf '%s\n' "$JAILED_PYTHON_SCRIPT" | _maybe_sudo "$target" tee "$target" >/dev/null
  _maybe_sudo "$target" chmod 755 "$target"

  # jailed-python3 -> jailed-python (replace existing symlink or file).
  _maybe_sudo "$link" rm -f "$link"
  _maybe_sudo "$link" ln -s jailed-python "$link"

  echo "Installed: $jailed_target"
  echo "Installed: $target"
  echo "Installed: $link -> jailed-python"
}

install_hook() {
  local hooks_dir="$HOME/.claude/hooks"
  local target="$hooks_dir/python-nudge.sh"
  mkdir -p "$hooks_dir"
  printf '%s\n' "$PYTHON_NUDGE_SCRIPT" > "$target"
  chmod 755 "$target"
  echo "Installed: $target"
}

merge_settings() {
  local settings="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"
  [[ -f "$settings" ]] || echo '{}' > "$settings"

  # One-shot backup.
  [[ -f "$settings.bak" ]] || cp "$settings" "$settings.bak"

  # Strip stale allow rules from prior installs before merging. Without this,
  # a user upgrading from safe-python would end up with both the legacy rule
  # and the current jailed-python rule side-by-side.
  local pruned
  pruned=$(jq '
    if .permissions.allow then
      .permissions.allow |= map(select(
        . != "Bash(safe-python:*)" and . != "Bash(safe-python3:*)"
      ))
    else . end
  ' "$settings")
  printf '%s\n' "$pruned" > "$settings"

  local patch
  patch=$(cat <<'JSON'
{
  "permissions": {
    "allow": ["Bash(jailed-python:*)", "Bash(jailed-python3:*)"]
  },
  "hooks": {
    "PreToolUse": [{
      "matcher": "Bash",
      "hooks": [{"type": "command", "command": "$HOME/.claude/hooks/python-nudge.sh"}]
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

upsert_claude_md() {
  local md="$HOME/.claude/CLAUDE.md"
  mkdir -p "$HOME/.claude"
  [[ -f "$md" ]] || : > "$md"

  local block
  block=$(cat <<'MD'
<!-- jailed-python:policy:start -->
## Python execution policy

- **Default: `jailed-python` / `jailed-python3`** for text processing in
  pipelines (e.g. `pup ... | jailed-python -c '...'`). Pre-approved, no
  prompt. Read-only filesystem, no network — ideal for parsing/transforming
  stdin to stdout.
- **Escape hatch: `python3`** when you actually need network, file writes,
  subprocess, or real project scripts/tests. Will prompt with a reminder;
  confirm when the need is real.

Decision rule: if the Python code reads stdin and prints to stdout with no
side effects, use `jailed-python`. Otherwise `python3`.
<!-- jailed-python:policy:end -->
MD
  )

  # Strip any existing delimited block. Handles current marker + two legacy
  # marker generations (safe-python:policy from last rename, pupbox:python-policy
  # from original) so upgrading installs never leave orphaned blocks.
  local cleaned
  cleaned=$(python3 - "$md" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    s = f.read()
for start, end in (
    ('jailed-python:policy:start', 'jailed-python:policy:end'),
    ('safe-python:policy:start', 'safe-python:policy:end'),
    ('pupbox:python-policy:start', 'pupbox:python-policy:end'),
):
    s = re.sub(
        rf'<!-- {start} -->.*?<!-- {end} -->\n?',
        '', s, flags=re.DOTALL)
# Trim trailing blank lines so we don't keep accumulating them.
s = s.rstrip() + ('\n' if s.strip() else '')
sys.stdout.write(s)
PY
  )

  {
    printf '%s' "$cleaned"
    [[ -n "$cleaned" ]] && printf '\n'
    printf '%s\n' "$block"
  } > "$md"
  echo "Updated: $md"
}

run_install() {
  check_deps
  install_bins
  install_hook
  merge_settings
  upsert_claude_md

  cat <<'EOF'

jailed-python installed.

Quick test:
  echo '<a href=x>' | jailed-python -c 'import sys; print(sys.stdin.read())'

Restart Claude Code (or run /config) to pick up the new hook and permissions.
EOF
}

usage() {
  cat <<EOF
Usage: bash install.sh [--uninstall] [--help]

Installs jailed-python + jailed-python3 wrappers and configures Claude Code
to prefer them over raw python3.

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

  # Remove current and all legacy-generation binaries so uninstall is total
  # regardless of which version the user last installed.
  for f in jailed jailed-python jailed-python3 safe-python safe-python3; do
    if [[ -e "$bindir/$f" || -L "$bindir/$f" ]]; then
      _maybe_sudo "$bindir/$f" rm -f "$bindir/$f"
      echo "Removed: $bindir/$f"
    fi
  done

  local hook="$HOME/.claude/hooks/python-nudge.sh"
  [[ -e "$hook" ]] && { rm -f "$hook"; echo "Removed: $hook"; }

  local settings="$HOME/.claude/settings.json"
  if [[ -f "$settings" ]]; then
    jq '
      if .permissions.allow then
        .permissions.allow |= map(select(
          . != "Bash(jailed-python:*)" and . != "Bash(jailed-python3:*)" and
          . != "Bash(safe-python:*)"   and . != "Bash(safe-python3:*)"
        ))
      else . end
      | if .hooks.PreToolUse then
          .hooks.PreToolUse |= map(select(
            [.hooks[]?.command] | all(. != "$HOME/.claude/hooks/python-nudge.sh")
          ))
        else . end
    ' "$settings" > "$settings.tmp" && mv "$settings.tmp" "$settings"
    echo "Cleaned: $settings"
  fi

  local md="$HOME/.claude/CLAUDE.md"
  if [[ -f "$md" ]]; then
    python3 - "$md" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    s = f.read()
# Strip current marker and all legacy marker generations so uninstall is
# total regardless of when the user last installed.
for start, end in (
    ('jailed-python:policy:start', 'jailed-python:policy:end'),
    ('safe-python:policy:start', 'safe-python:policy:end'),
    ('pupbox:python-policy:start', 'pupbox:python-policy:end'),
):
    s = re.sub(
        rf'<!-- {start} -->.*?<!-- {end} -->\n?',
        '', s, flags=re.DOTALL)
s = s.rstrip() + ('\n' if s.strip() else '')
with open(path, 'w') as f:
    f.write(s)
PY
    echo "Cleaned: $md"
  fi

  echo
  echo "jailed-python uninstalled. (Backup at $settings.bak remains if you want to restore.)"
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
