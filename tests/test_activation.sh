#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."
source tests/lib.sh

HOOK="hooks/jailed-hook.sh"
CFG_DIR=$(make_tmp)
CFG="$CFG_DIR/commands"
printf 'python3\n' > "$CFG"

SANDBOX=$(make_tmp)
cat > "$SANDBOX/ps" <<'PS_EOF'
#!/usr/bin/env bash
# Fake ps. Reads synthetic chain from $TREE (format: "pid ppid comm" per
# line). On -p <pid>, returns "<ppid> <comm>". If <pid> is not in the file
# (e.g. the hook's real $$), returns the first record's ppid+comm so the
# walk continues into the synthetic chain.
pid=""
while (( $# )); do
  case "$1" in
    -p) pid="$2"; shift 2 ;;
    *)  shift ;;
  esac
done
first_pp=""; first_c=""
while read -r p pp c; do
  [[ -z "$p" || "${p:0:1}" == "#" ]] && continue
  [[ -z "$first_pp" ]] && { first_pp="$pp"; first_c="$c"; }
  if [[ "$p" == "$pid" ]]; then
    printf '%s %s\n' "$pp" "$c"
    exit 0
  fi
done < "$TREE"
if [[ -n "$first_pp" ]]; then
  printf '%s %s\n' "$first_pp" "$first_c"
  exit 0
fi
exit 1
PS_EOF
chmod 755 "$SANDBOX/ps"

run_hook_with_tree() {
  local tree=$1
  printf '%s' '{"tool_input":{"command":"python3 -c 1"}}' \
    | PATH="$SANDBOX:$PATH" TREE="$tree" JAILED_CONFIG="$CFG" bash "$HOOK"
}

TREE=$(make_tmp)/tree

test_case "claude with jailed parent → activate"
cat > "$TREE" <<'EOF'
100 50 claude
50  10 jailed
10  1  bash
EOF
out=$(run_hook_with_tree "$TREE")
assert_contains "$out" "jailed python3" "chain claude→jailed must activate rewriting"

test_case "plain claude (no jailed parent) → stand down"
cat > "$TREE" <<'EOF'
100 50 claude
50  10 bash
10  1  bash
EOF
out=$(run_hook_with_tree "$TREE")
assert_eq "" "$out" "no jailed ancestor → hook must be silent"

test_case "nested claude under jailed claude → activate"
cat > "$TREE" <<'EOF'
200 100 claude
100 90  bash
90  50  claude
50  10  jailed
10  1   bash
EOF
out=$(run_hook_with_tree "$TREE")
assert_contains "$out" "jailed python3" "outer claude-has-jailed-parent activates inner hook"

test_case "no claude in chain → stand down"
cat > "$TREE" <<'EOF'
100 50 bash
50  10 bash
10  1  bash
EOF
out=$(run_hook_with_tree "$TREE")
assert_eq "" "$out" "no claude ancestor → silent"

test_case "claude's direct parent is a wrapper (not jailed) → stand down"
cat > "$TREE" <<'EOF'
100 50 claude
50  40 weird-wrapper
40  10 jailed
10  1  bash
EOF
out=$(run_hook_with_tree "$TREE")
assert_eq "" "$out" "only claude's immediate parent comm matters"

rm -rf "$CFG_DIR" "$SANDBOX"
summary
