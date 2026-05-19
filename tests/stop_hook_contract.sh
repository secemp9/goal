#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "$REPO_ROOT/.tmp-goal-test.XXXXXX")"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required" >&2
    exit 1
fi

# shellcheck source=../src/goal_lib.sh
source "$REPO_ROOT/src/goal_lib.sh"

die() {
    echo "not ok - $*" >&2
    exit 1
}

assert_empty_file() {
    local file="$1"
    local label="$2"

    if [[ -s "$file" ]]; then
        echo "$label was not empty:" >&2
        cat "$file" >&2
        exit 1
    fi
}

run_stop_hook() {
    local stdout_file="$1"
    local stderr_file="$2"
    local code

    set +e
    "$REPO_ROOT/src/hooks/stop_hook.sh" >"$stdout_file" 2>"$stderr_file"
    code=$?
    set -e

    printf '%s' "$code"
}

assert_json_block_reason_contains() {
    local stdout_file="$1"
    local expected_text="$2"

    jq -e \
        --arg expected_text "$expected_text" \
        '.decision == "block" and (.reason | contains("<goal_context>")) and (.reason | contains($expected_text))' \
        "$stdout_file" >/dev/null
}

active_stdout="$TMP_DIR/active.stdout.json"
active_stderr="$TMP_DIR/active.stderr.txt"
export GOAL_STATE_FILE="$TMP_DIR/active-goal.json"

goal_create "continue until done" 2 >/dev/null
active_code="$(run_stop_hook "$active_stdout" "$active_stderr")"

[[ "$active_code" == "0" ]] || die "active Stop hook exited $active_code"
assert_empty_file "$active_stderr" "active stderr"
assert_json_block_reason_contains "$active_stdout" "Continue working toward the active thread goal."
jq -e '.status == "active" and .turns_used == 1 and .turn_budget == 2' "$GOAL_STATE_FILE" >/dev/null
echo "ok active Stop hook emits JSON block decision"

budget_stdout="$TMP_DIR/budget.stdout.json"
budget_stderr="$TMP_DIR/budget.stderr.txt"
export GOAL_STATE_FILE="$TMP_DIR/budget-goal.json"

goal_create "wrap up at budget" 1 >/dev/null
budget_code="$(run_stop_hook "$budget_stdout" "$budget_stderr")"

[[ "$budget_code" == "0" ]] || die "budget Stop hook exited $budget_code"
assert_empty_file "$budget_stderr" "budget stderr"
assert_json_block_reason_contains "$budget_stdout" "reached its turn budget"
jq -e '.status == "budget_limited" and .turns_used == 1 and .turn_budget == 1' "$GOAL_STATE_FILE" >/dev/null
echo "ok budget Stop hook emits JSON block decision"

budget_again_stdout="$TMP_DIR/budget-again.stdout.txt"
budget_again_stderr="$TMP_DIR/budget-again.stderr.txt"
budget_again_code="$(run_stop_hook "$budget_again_stdout" "$budget_again_stderr")"

[[ "$budget_again_code" == "0" ]] || die "already-budget-limited Stop hook exited $budget_again_code"
assert_empty_file "$budget_again_stdout" "already-budget-limited stdout"
assert_empty_file "$budget_again_stderr" "already-budget-limited stderr"
jq -e '.status == "budget_limited" and .turns_used == 1 and .turn_budget == 1' "$GOAL_STATE_FILE" >/dev/null
echo "ok already budget-limited Stop hook allows stop quietly"

paused_stdout="$TMP_DIR/paused.stdout.txt"
paused_stderr="$TMP_DIR/paused.stderr.txt"
export GOAL_STATE_FILE="$TMP_DIR/paused-goal.json"

goal_create "stay paused" 3 >/dev/null
goal_update_status "paused" >/dev/null
paused_code="$(run_stop_hook "$paused_stdout" "$paused_stderr")"

[[ "$paused_code" == "0" ]] || die "paused Stop hook exited $paused_code"
assert_empty_file "$paused_stdout" "paused stdout"
assert_empty_file "$paused_stderr" "paused stderr"
jq -e '.status == "paused" and .turns_used == 0 and .turn_budget == 3' "$GOAL_STATE_FILE" >/dev/null
echo "ok paused Stop hook allows stop quietly"
