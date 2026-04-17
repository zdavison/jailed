#!/usr/bin/env bash
# PreToolUse hook: nudge Claude toward safe-python when it tries to run raw python/python3.
# - permissionDecisionReason is shown to the *user* in the approval prompt.
# - additionalContext is fed back into *Claude's* context so the model itself
#   learns to prefer safe-python; without this, the reason is invisible to the
#   model and Claude keeps re-proposing python3.

input=$(cat)
cmd=$(echo "$input" | jq -r '.tool_input.command // ""')

# Match python or python3 as a standalone command, anchored to start-of-string or a
# shell separator. Excludes safe-python, safe-python3, python3.N, pythonX, etc.
if echo "$cmd" | grep -qE '(^|[|&;`]|\$\()[[:space:]]*python3?([[:space:]]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "ask",
      permissionDecisionReason: "Prefer safe-python (pre-approved, sandboxed: no network, no filesystem writes) for text processing. Only continue with python3 if you genuinely need network, file writes, subprocess, or full stdlib access.",
      additionalContext: "safe-python and safe-python3 are pre-approved, sandboxed wrappers around /usr/bin/python3 with no network access and no filesystem writes. Prefer them for text processing in pipelines (stdin->stdout, no side effects). Only reach for raw python3 when you genuinely need network, file writes, subprocess spawning, or packages outside the stdlib."
    }
  }'
fi
exit 0
