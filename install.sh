#!/usr/bin/env bash
# pupbox installer: safe-python + Claude Code integration.
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
# Embedded assets (kept byte-identical to bin/safe-python + hooks/python-nudge.sh
# via tests/test_installer.sh).
# -----------------------------------------------------------------------------

read -r -d '' SAFE_PYTHON_SCRIPT <<'PUPBOX_EOF' || true
#!/usr/bin/env bash
# safe-python: /usr/bin/python3 sandboxed.
# - read-only view of the filesystem, no writes outside allowed /dev sinks
# - no network
# - Linux: bubblewrap with ephemeral tmpfs for $HOME, /tmp, /run
# - macOS: sandbox-exec with an equivalent Seatbelt profile.
#          Writes fail outright instead of landing in a tmpfs — there is no
#          cheap tmpfs on Darwin, and the no-side-effects contract is the same.

set -u

if [[ "$(uname)" == "Darwin" ]]; then
  exec sandbox-exec -p '(version 1)
(deny default)
(allow process*)
(allow signal (target self))
(allow mach-lookup)
(allow ipc-posix*)
(allow sysctl-read)
(allow file-read*)
(allow file-write*
  (literal "/dev/null")
  (literal "/dev/stdout")
  (literal "/dev/stderr")
  (literal "/dev/tty")
  (literal "/dev/dtracehelper")
  (regex "^/dev/fd/")
  (regex "^/dev/ttys"))
(deny network*)' /usr/bin/python3 "$@"
fi

exec bwrap \
  --ro-bind / / \
  --dev /dev \
  --proc /proc \
  --tmpfs /tmp \
  --tmpfs /run \
  --tmpfs "$HOME" \
  --unshare-all \
  --die-with-parent \
  --new-session \
  /usr/bin/python3 "$@"
PUPBOX_EOF
SAFE_PYTHON_SCRIPT+=$'\n'

read -r -d '' PYTHON_NUDGE_SCRIPT <<'PUPBOX_EOF' || true
#!/usr/bin/env bash
# PreToolUse hook: nudge Claude toward safe-python when it tries to run raw python/python3.
# Emits an ask-decision with a custom reason; stays silent for everything else.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Match python or python3 as a standalone command, anchored to start-of-string or a
# shell separator. Excludes safe-python, safe-python3, python3.N, pythonX, etc.
if echo "$cmd" | grep -qE '(^|[|&;`]|\$\()[[:space:]]*python3?([[:space:]]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "Prefer safe-python (pre-approved, sandboxed: no network, no filesystem writes) for text processing. Only continue with python3 if you genuinely need network, file writes, subprocess, or full stdlib access."
    }
  }'
fi
exit 0
PUPBOX_EOF
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
  local target="$bindir/safe-python"
  local link="$bindir/safe-python3"

  _maybe_sudo "$bindir" mkdir -p "$bindir"

  # Write via tee so sudo flows naturally.
  printf '%s\n' "$SAFE_PYTHON_SCRIPT" | _maybe_sudo "$target" tee "$target" >/dev/null
  _maybe_sudo "$target" chmod 755 "$target"

  # safe-python3 -> safe-python (replace existing symlink or file).
  _maybe_sudo "$link" rm -f "$link"
  _maybe_sudo "$link" ln -s safe-python "$link"

  echo "Installed: $target"
  echo "Installed: $link -> safe-python"
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

  local patch
  patch=$(cat <<'JSON'
{
  "permissions": {
    "allow": ["Bash(safe-python:*)", "Bash(safe-python3:*)"]
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
<!-- pupbox:python-policy:start -->
## Python execution policy

- **Default: `safe-python` / `safe-python3`** for text processing in pipelines
  (e.g. `pup ... | safe-python -c '...'`). Pre-approved, no prompt. Read-only
  filesystem, no network — ideal for parsing/transforming stdin to stdout.
- **Escape hatch: `python3`** when you actually need network, file writes,
  subprocess, or real project scripts/tests. Will prompt with a reminder;
  confirm when the need is real.

Decision rule: if the Python code reads stdin and prints to stdout with no
side effects, use `safe-python`. Otherwise `python3`.
<!-- pupbox:python-policy:end -->
MD
  )

  # Strip any existing delimited block, then append a fresh one.
  local cleaned
  cleaned=$(python3 - "$md" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    s = f.read()
s = re.sub(
    r'<!-- pupbox:python-policy:start -->.*?<!-- pupbox:python-policy:end -->\n?',
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

pupbox installed.

Quick test:
  echo '<a href=x>' | safe-python -c 'import sys; print(sys.stdin.read())'

Restart Claude Code (or run /config) to pick up the new hook and permissions.
EOF
}

usage() {
  cat <<EOF
Usage: bash install.sh [--uninstall] [--help]

Installs safe-python + safe-python3 wrappers and configures Claude Code
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

  for f in safe-python safe-python3; do
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
        .permissions.allow |= map(select(. != "Bash(safe-python:*)" and . != "Bash(safe-python3:*)"))
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
s = re.sub(
    r'<!-- pupbox:python-policy:start -->.*?<!-- pupbox:python-policy:end -->\n?',
    '', s, flags=re.DOTALL)
s = s.rstrip() + ('\n' if s.strip() else '')
with open(path, 'w') as f:
    f.write(s)
PY
    echo "Cleaned: $md"
  fi

  echo
  echo "pupbox uninstalled. (Backup at $settings.bak remains if you want to restore.)"
}

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --uninstall) run_uninstall ;;
    "") run_install ;;
    *) usage; exit 2 ;;
  esac
}

# If sourced by the test harness (PUPBOX_LIB_ONLY=1), stop after defining vars.
if [[ -z "${PUPBOX_LIB_ONLY:-}" ]]; then
  main "$@"
fi
