#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

UNJAILED="bin/unjailed"

# ---- bin/unjailed wrapper ----

test_case "unjailed with no args prints usage and exits 2"
out=$(bash "$UNJAILED" 2>&1; echo "exit=$?")
assert_contains "$out" "usage: unjailed" "must print usage on zero args"
assert_contains "$out" "exit=2" "must exit 2 on zero args"

test_case "unjailed execs argv with UNJAILED=1 in env"
# Use env(1) as the child so we can read its environment.
out=$(env -u UNJAILED bash "$UNJAILED" env | grep '^UNJAILED=' || true)
assert_eq "UNJAILED=1" "$out" "UNJAILED=1 must be exported to the child"

test_case "unjailed preserves argv quoting to the child"
# Pass an argument with a space; child should see it as a single arg.
out=$(bash "$UNJAILED" python3 -c 'import sys; print("|".join(sys.argv[1:]))' "a b" "c")
assert_eq "a b|c" "$out" "argv must survive intact (no shell re-splitting)"

# ---- Hook trust validator ----

HOOK="hooks/jailed-hook.sh"
CFG_DIR=$(make_tmp)
CFG="$CFG_DIR/commands"
printf 'python3\npython\njq\n' > "$CFG"

# Helper: run the hook against a python3 command, with a synthetic ancestry
# fixture. Returns the hook's stdout. Empty stdout means "no rewrite".
run_hook_fixture() {
  local fixture_file="$1"
  local unjailed_val="$2"   # "1" or "" (empty = unset)
  local start_pid="$3"      # synthetic pid that stands in for $$
  # Build the env prefix without arrays to stay bash 3.2-safe under set -u.
  # When unjailed_val is non-empty, prepend UNJAILED=<val> to the env call.
  printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' \
    | if [[ -n "$unjailed_val" ]]; then
        env UNJAILED="$unjailed_val" \
            JAILED_CONFIG="$CFG" \
            JAILED_ANCESTRY_FIXTURE="$fixture_file" \
            JAILED_ANCESTRY_START="$start_pid" \
            bash "$HOOK"
      else
        env JAILED_CONFIG="$CFG" \
            JAILED_ANCESTRY_FIXTURE="$fixture_file" \
            JAILED_ANCESTRY_START="$start_pid" \
            bash "$HOOK"
      fi
}

# Fixture format: `<pid> <ppid> <comm>` one per line.

test_case "UNJAILED=1 + legit unjailed ancestry → no rewrite"
f=$(make_tmp)/fix
cat > "$f" <<'EOF'
100 50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_eq "" "$out" "hook must stand down when topmost claude's parent is unjailed"

test_case "UNJAILED=1 + realistic start (hook bash shell) → no rewrite"
# Mirrors production: $$ is the hook's bash, claude is one level up.
cat > "$f" <<'EOF'
200 100 bash
100 50  claude
50  10  unjailed
10  1   bash
EOF
out=$(run_hook_fixture "$f" "1" "200")
assert_eq "" "$out" "chain starting at hook bash shell must still be trusted"

test_case "UNJAILED=1 + nested claude under unjailed → no rewrite"
# Ancestry: self(100)=claude → 90=bash → 80=claude → 50=unjailed → 10=bash
cat > "$f" <<'EOF'
100 90 claude
90  80 bash
80  50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_eq "" "$out" "nested claude under unjailed must still be trusted"

test_case "UNJAILED=1 + attack (UNJAILED=1 claude -p from bash tool) → rewrite"
# Ancestry: child_claude(100) → bash(90) → parent_claude(80) → shell(10)
# UNJAILED=1 was injected by parent claude; no unjailed ancestor.
cat > "$f" <<'EOF'
100 90 claude
90  80 bash
80  10 claude
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_contains "$out" "jailed python3" "attack must be rejected → rewrite happens"

test_case "UNJAILED=1 + attack (unjailed claude -p from bash tool) → rewrite"
# Ancestry: child_claude(100) → unjailed(95) → bash(90) → parent_claude(80) → shell(10)
# Topmost claude is 80; its parent is shell, not unjailed.
cat > "$f" <<'EOF'
100 95 claude
95  90 unjailed
90  80 bash
80  10 claude
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_contains "$out" "jailed python3" "claude above unjailed must flip to distrust"

test_case "UNJAILED=1 + no claude in ancestry → rewrite"
cat > "$f" <<'EOF'
100 50 python3
50  10 bash
10  1  bash
EOF
out=$(run_hook_fixture "$f" "1" "100")
assert_contains "$out" "jailed python3" "no claude ancestor → distrust UNJAILED"

test_case "UNJAILED unset → hook rewrites as normal (regression)"
cat > "$f" <<'EOF'
100 50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "" "100")
assert_contains "$out" "jailed python3" "no UNJAILED → rewrite regardless of ancestry"

test_case "UNJAILED=2 (non-'1' value) → hook rewrites as normal"
cat > "$f" <<'EOF'
100 50 claude
50  10 unjailed
10  1  bash
EOF
out=$(run_hook_fixture "$f" "2" "100")
assert_contains "$out" "jailed python3" "only UNJAILED=1 triggers trust check"

rm -rf "$CFG_DIR"

summary
