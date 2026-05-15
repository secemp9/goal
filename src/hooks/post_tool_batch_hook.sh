#!/usr/bin/env bash
# post_tool_batch_hook.sh — Mid-turn budget monitor for goal-driven sessions.
#
# Ported from Codex CLI's goal lifecycle:
#   goals.rs: account_thread_goal_progress() with BudgetLimitSteering::Allowed
#   goals.rs: inject_budget_limit_steering()
#
# Claude Code PostToolUse hook contract:
#   - Output JSON to stdout with hookSpecificOutput.additionalContext
#     to inject context into the conversation.
#   - Exit 0 always (this hook cannot force continuation).
#
# Flow:
#   1. Read goal state.
#   2. If no active goal or no turn budget -> exit 0 quietly.
#   3. If turns are approaching the budget (within 2 turns), inject a
#      budget warning as additionalContext.
#   4. This mirrors Codex's mid-turn budget-limit steering: when the
#      accounting detects a transition to budget_limited during a tool
#      call (not at turn-end), it injects a steering prompt.
#
# Note: Unlike Codex, which tracks exact token consumption per tool call,
# we approximate by checking proximity to the turn budget. The actual
# transition to budget_limited happens in the stop hook via goal_increment_turn.
# This hook provides an early warning so Claude can start wrapping up.

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$GOAL_DIR/templates"

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

# output_hook_json — Output the PostToolUse hook response JSON.
output_hook_json() {
    local context="$1"
    # Use jq to safely encode the context string into JSON.
    jq -n \
        --arg ctx "$context" \
        '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
}

# render_template — Substitute placeholders in a template file.
# Placeholders are {{ variable_name }} (with spaces around the name).
#
# Uses awk for SINGLE-PASS substitution to prevent template injection.
# See stop_hook.sh for detailed rationale.
render_template() {
    local template_file="$1"
    local objective="$2"
    local turns_used="$3"
    local turn_budget="$4"
    local remaining_turns="$5"
    local time_used_seconds="$6"

    local escaped_objective
    escaped_objective="$(escape_xml_text "$objective")"

    # Objective via ENVIRON to avoid awk -v backslash interpretation.
    _AWK_OBJ="$escaped_objective" awk \
        -v tu="$turns_used" \
        -v tb="$turn_budget" \
        -v rt="$remaining_turns" \
        -v ts="$time_used_seconds" \
        'BEGIN { obj = ENVIRON["_AWK_OBJ"] }
        {
            while (match($0, /\{\{ [a-z_]+ \}\}/)) {
                placeholder = substr($0, RSTART, RLENGTH)
                if      (placeholder == "{{ objective }}")        rep = obj
                else if (placeholder == "{{ turns_used }}")       rep = tu
                else if (placeholder == "{{ turn_budget }}")      rep = tb
                else if (placeholder == "{{ remaining_turns }}")  rep = rt
                else if (placeholder == "{{ time_used_seconds }}") rep = ts
                else rep = placeholder
                printf "%s%s", substr($0, 1, RSTART-1), rep
                $0 = substr($0, RSTART + RLENGTH)
            }
            print $0
        }' "$template_file"
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
turn_budget_raw="$(echo "$json" | jq -r '.turn_budget // "null"')"
turns_used="$(echo "$json" | jq -r '.turns_used')"

# Only act on active goals with a turn budget.
if [[ "$status" != "active" ]]; then
    echo '{}'
    exit 0
fi

if [[ "$turn_budget_raw" == "null" ]]; then
    echo '{}'
    exit 0
fi

turn_budget="$turn_budget_raw"

# Calculate proximity to budget.
# The stop hook increments turns_used at the END of each turn, so the
# current turn is not yet counted. We check if this turn (once counted)
# would put us within 2 turns of the budget.
effective_turns=$(( turns_used + 1 ))
remaining=$(( turn_budget - effective_turns ))

# Inject a warning when within 2 turns of the budget or over budget.
# This mirrors Codex's inject_budget_limit_steering() which fires when
# the accounting detects the goal has crossed into budget_limited territory.
objective="$(echo "$json" | jq -r '.objective')"
time_used_seconds="$(echo "$json" | jq -r '.time_used_seconds')"

if (( remaining <= 0 )); then
    # Over budget — render the full budget_limit.md template.
    # This is rare mid-turn (the stop hook normally transitions first),
    # but ensures correct steering if it happens.
    remaining_display=0
    prompt="$(render_template \
        "$TEMPLATE_DIR/budget_limit.md" \
        "$objective" \
        "$turns_used" \
        "$turn_budget" \
        "$remaining_display" \
        "$time_used_seconds")"
    output_hook_json "$prompt"
elif (( remaining <= 2 )); then
    # Approaching budget — plain-text warning referencing template key instructions.
    warning="Budget warning for active goal: ${remaining} turn(s) remaining out of ${turn_budget}. "
    warning+="Turns used so far: ${turns_used}. Time spent: ${time_used_seconds}s. "
    warning+="Wrap up soon: summarize useful progress, identify remaining work or blockers, and leave the user with a clear next step."

    output_hook_json "$warning"
else
    # No warning needed — output empty response.
    echo '{}'
fi

exit 0
