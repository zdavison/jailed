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
# safe-python: /usr/bin/python3 under bubblewrap.
# - read-only view of /, no writes outside ephemeral tmpfs
# - no network (unshare-all)
# - dies with parent shell

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
  for tool in bwrap jq python3; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if (( ${#missing[@]} > 0 )); then
    echo "Missing required tools: ${missing[*]}" >&2
    echo "On Debian/Ubuntu: sudo apt install bubblewrap jq python3" >&2
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

main() {
  case "${1:-}" in
    --help|-h) usage; exit 0 ;;
    --uninstall) echo "uninstall not yet implemented"; exit 1 ;;
    "") echo "install not yet implemented"; exit 1 ;;
    *) usage; exit 2 ;;
  esac
}

# If sourced by the test harness (PUPBOX_LIB_ONLY=1), stop after defining vars.
if [[ -z "${PUPBOX_LIB_ONLY:-}" ]]; then
  main "$@"
fi
