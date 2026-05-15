#!/usr/bin/env bash
# user_prompt_submit_hook.sh — Turn-start goal context injection.
#
# Ported from Codex CLI's goal lifecycle:
#   goals.rs: mark_thread_goal_turn_started()
#   goals.rs: restore_thread_goal_runtime_after_resume()
#
# Claude Code UserPromptSubmit hook contract:
#   - Output JSON to stdout with hookSpecificOutput.additionalContext
#     to inject context into the conversation at the start of a turn.
#   - Exit 0 always.
#
# Flow:
#   1. Read goal state.
#   2. If no active goal -> exit 0 silently.
#   3. If active goal exists -> output a brief goal reminder (objective +
#      budget status) as additionalContext.
#   4. This is intentionally brief. The full continuation prompt is
#      delivered by the Stop hook between turns. This reminder ensures
#      the model is aware of the goal context at the start of user-
#      initiated turns (not just auto-continuation turns).

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the shared library.
# shellcheck source=../goal_lib.sh
source "$GOAL_DIR/goal_lib.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

escape_xml_text() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    printf '%s' "$text"
}

# output_hook_json — Output the UserPromptSubmit hook response JSON.
output_hook_json() {
    local context="$1"
    jq -n \
        --arg ctx "$context" \
        '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

# Check if a goal exists.
if ! goal_exists; then
    echo '{}'
    exit 0
fi

# Read current state.
json="$(goal_read)"
status="$(echo "$json" | jq -r '.status')"

# Only inject context for active or budget_limited goals.
if [[ "$status" != "active" && "$status" != "budget_limited" ]]; then
    echo '{}'
    exit 0
fi

objective="$(echo "$json" | jq -r '.objective')"
turns_used="$(echo "$json" | jq -r '.turns_used')"
turn_budget_raw="$(echo "$json" | jq -r '.turn_budget // "null"')"
time_used_seconds="$(echo "$json" | jq -r '.time_used_seconds')"

# Build budget status string.
if [[ "$turn_budget_raw" == "null" ]]; then
    budget_info="no turn budget (unlimited)"
else
    remaining=$(( turn_budget_raw - turns_used ))
    if (( remaining < 0 )); then
        remaining=0
    fi
    budget_info="${turns_used}/${turn_budget_raw} turns used, ${remaining} remaining"
fi

escaped_objective="$(escape_xml_text "$objective")"

# Build the brief reminder context.
context="Active goal [${status}]: <objective>${escaped_objective}</objective> "
context+="| Budget: ${budget_info} | Time: ${time_used_seconds}s"

output_hook_json "$context"

exit 0
