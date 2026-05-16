#!/usr/bin/env bash
# goal_cli.sh — CLI dispatcher for the /goal skill.
#
# Parses subcommands and calls goal_lib.sh functions.
# Outputs human-readable results matching Codex's goal_menu.rs display format.
#
# Usage: goal_cli.sh [subcommand] [args...]
#   (no args)          — show goal summary
#   <objective text>   — create a new goal
#   clear              — clear the current goal
#   pause              — pause the current goal
#   resume             — resume a paused goal
#   edit <objective>   — update the objective of an existing goal
#   status             — show detailed goal status (same as bare)
#   budget <N>         — set/update turn budget

set -euo pipefail

# ---------------------------------------------------------------------------
# Resolve paths & source library
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=goal_lib.sh
source "$SCRIPT_DIR/goal_lib.sh"

# ---------------------------------------------------------------------------
# Display helpers (ported from goal_display.rs and goal_menu.rs)
# ---------------------------------------------------------------------------

# format_elapsed — Convert seconds to compact human-readable format.
# Matches Codex's format_goal_elapsed_seconds() exactly.
format_elapsed() {
    local seconds="$1"
    if (( seconds < 0 )); then
        seconds=0
    fi
    if (( seconds < 60 )); then
        echo "${seconds}s"
        return
    fi
    local minutes=$(( seconds / 60 ))
    if (( minutes < 60 )); then
        echo "${minutes}m"
        return
    fi
    local hours=$(( minutes / 60 ))
    local remaining_minutes=$(( minutes % 60 ))
    if (( hours >= 24 )); then
        local days=$(( hours / 24 ))
        local remaining_hours=$(( hours % 24 ))
        echo "${days}d ${remaining_hours}h ${remaining_minutes}m"
        return
    fi
    if (( remaining_minutes == 0 )); then
        echo "${hours}h"
    else
        echo "${hours}h ${remaining_minutes}m"
    fi
}

# goal_status_label — Map status enum to display string.
# Matches Codex's goal_status_label() in goal_display.rs.
goal_status_label() {
    local status="$1"
    case "$status" in
        active)         echo "active" ;;
        paused)         echo "paused" ;;
        budget_limited) echo "limited by budget" ;;
        complete)       echo "complete" ;;
        *)              echo "$status" ;;
    esac
}

# show_summary — Display goal summary matching Codex's goal_summary_lines().
show_summary() {
    local json="$1"
    local status objective time_used turns_used turn_budget

    status="$(echo "$json" | jq -r '.status')"
    objective="$(echo "$json" | jq -r '.objective')"
    time_used="$(echo "$json" | jq -r '.time_used_seconds')"
    turns_used="$(echo "$json" | jq -r '.turns_used')"
    turn_budget="$(echo "$json" | jq -r '.turn_budget // "null"')"

    local status_label
    status_label="$(goal_status_label "$status")"

    local elapsed
    elapsed="$(format_elapsed "$time_used")"

    echo "Goal"
    echo "Status: ${status_label}"
    echo "Objective: ${objective}"
    echo "Time used: ${elapsed}"
    echo "Turns used: ${turns_used}"

    if [[ "$turn_budget" != "null" ]]; then
        local remaining=$(( turn_budget - turns_used ))
        if (( remaining < 0 )); then
            remaining=0
        fi
        echo "Turn budget: ${turn_budget} (${remaining} remaining)"
    fi

    echo ""
    case "$status" in
        active)
            echo "Commands: /goal edit <text>, /goal pause, /goal clear"
            ;;
        paused)
            echo "Commands: /goal edit <text>, /goal resume, /goal clear"
            ;;
        budget_limited|complete)
            echo "Commands: /goal edit <text>, /goal clear"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------

cmd_show() {
    if ! goal_exists; then
        echo "No goal is currently set."
        echo ""
        echo "Usage: /goal <objective>"
        echo "Example: /goal improve benchmark coverage"
        return 0
    fi
    local json
    json="$(goal_read)"
    show_summary "$json"
}

cmd_create() {
    local objective="$1"

    if [[ -z "$objective" ]]; then
        echo "ERROR: Goal objective must not be empty."
        echo ""
        echo "Usage: /goal <objective>"
        echo "Example: /goal improve benchmark coverage"
        return 1
    fi

    # Validate objective length.
    local char_count="${#objective}"
    if (( char_count > MAX_OBJECTIVE_CHARS )); then
        echo "ERROR: Objective must be at most ${MAX_OBJECTIVE_CHARS} characters (got ${char_count})."
        return 1
    fi

    # Check if a goal already exists.
    if goal_exists; then
        local existing_json
        existing_json="$(goal_read)"
        local existing_objective existing_status
        existing_objective="$(echo "$existing_json" | jq -r '.objective')"
        existing_status="$(echo "$existing_json" | jq -r '.status')"
        local status_label
        status_label="$(goal_status_label "$existing_status")"

        echo "WARNING: A goal already exists."
        echo "Current goal (${status_label}): ${existing_objective}"
        echo ""
        echo "To replace it, first run: /goal clear"
        echo "Then set the new goal: /goal ${objective}"
        return 1
    fi

    local result
    result="$(goal_create "$objective")"
    local new_status
    new_status="$(echo "$result" | jq -r '.status')"
    local status_label
    status_label="$(goal_status_label "$new_status")"

    echo "Goal ${status_label}"
    echo "Objective: ${objective}"
}

cmd_clear() {
    if goal_clear; then
        echo "Goal cleared."
    else
        echo "No goal to clear."
        echo "This thread does not currently have a goal."
    fi
}

cmd_pause() {
    if ! goal_exists; then
        echo "ERROR: No goal exists to pause."
        return 1
    fi

    local json
    json="$(goal_read)"
    local status
    status="$(echo "$json" | jq -r '.status')"

    if [[ "$status" == "paused" ]]; then
        echo "Goal is already paused."
        return 0
    fi

    if [[ "$status" == "complete" ]]; then
        echo "ERROR: Cannot pause a completed goal."
        return 1
    fi

    local result
    result="$(goal_update_status "paused")"
    local new_status
    new_status="$(echo "$result" | jq -r '.status')"
    local status_label
    status_label="$(goal_status_label "$new_status")"

    echo "Goal ${status_label}"
    local objective
    objective="$(echo "$result" | jq -r '.objective')"
    echo "Objective: ${objective}"
}

cmd_resume() {
    if ! goal_exists; then
        echo "ERROR: No goal exists to resume."
        return 1
    fi

    local json
    json="$(goal_read)"
    local status
    status="$(echo "$json" | jq -r '.status')"

    if [[ "$status" == "active" ]]; then
        echo "Goal is already active."
        return 0
    fi

    if [[ "$status" == "complete" ]]; then
        echo "ERROR: Cannot resume a completed goal. Use /goal clear and set a new one."
        return 1
    fi

    local result
    result="$(goal_update_status "active")"
    local new_status
    new_status="$(echo "$result" | jq -r '.status')"
    local status_label
    status_label="$(goal_status_label "$new_status")"

    echo "Goal ${status_label}"
    local objective
    objective="$(echo "$result" | jq -r '.objective')"
    echo "Objective: ${objective}"
}

cmd_edit() {
    local new_objective="$1"

    if [[ -z "$new_objective" ]]; then
        echo "ERROR: New objective must not be empty."
        echo "Usage: /goal edit <new objective text>"
        return 1
    fi

    if ! goal_exists; then
        echo "ERROR: No goal is currently set."
        echo "Usage: /goal <objective>"
        echo "Create a goal before editing it."
        return 1
    fi

    local char_count="${#new_objective}"
    if (( char_count > MAX_OBJECTIVE_CHARS )); then
        echo "ERROR: Objective must be at most ${MAX_OBJECTIVE_CHARS} characters (got ${char_count})."
        return 1
    fi

    local result
    result="$(goal_update_objective "$new_objective")"
    local status
    status="$(echo "$result" | jq -r '.status')"

    # Codex edited_goal_status(): reactivate budget_limited/complete goals on edit.
    local new_status="$status"
    case "$status" in
        budget_limited|complete)
            new_status="active"
            ;;
        active|paused)
            # Keep as-is.
            ;;
    esac

    if [[ "$new_status" != "$status" ]]; then
        result="$(goal_update_status "$new_status")"
        # Read effective status from result (may differ if still over budget).
        status="$(echo "$result" | jq -r '.status')"
    fi

    local status_label
    status_label="$(goal_status_label "$status")"

    # Read updated state for template rendering.
    local turns_used turn_budget_raw turn_budget_display remaining_turns_display time_used_seconds
    turns_used="$(echo "$result" | jq -r '.turns_used')"
    turn_budget_raw="$(echo "$result" | jq -r '.turn_budget // "null"')"
    time_used_seconds="$(echo "$result" | jq -r '.time_used_seconds')"

    if [[ "$turn_budget_raw" == "null" ]]; then
        turn_budget_display="none"
        remaining_turns_display="unbounded"
    else
        turn_budget_display="$turn_budget_raw"
        local remaining=$(( turn_budget_raw - turns_used ))
        if (( remaining < 0 )); then
            remaining=0
        fi
        remaining_turns_display="$remaining"
    fi

    echo "Goal objective updated."
    echo "Status: ${status_label}"
    echo "New objective: ${new_objective}"
    echo ""

    # Render objective_updated.md template so Claude sees steering instructions.
    # Mirrors Codex's inject of objective_updated_steering_item on edit.
    # Uses awk for single-pass substitution to prevent template injection.
    local template_dir
    template_dir="$(cd "$SCRIPT_DIR/templates" 2>/dev/null && pwd)" || template_dir="$SCRIPT_DIR/templates"
    local template_file="$template_dir/objective_updated.md"
    if [[ -f "$template_file" ]]; then
        local escaped_objective
        escaped_objective="${new_objective//&/&amp;}"
        escaped_objective="${escaped_objective//</&lt;}"
        escaped_objective="${escaped_objective//>/&gt;}"

        # Objective via ENVIRON to avoid awk -v backslash interpretation.
        _AWK_OBJ="$escaped_objective" awk \
            -v tu="$turns_used" \
            -v tb="$turn_budget_display" \
            -v rt="$remaining_turns_display" \
            'BEGIN { obj = ENVIRON["_AWK_OBJ"] }
            {
                while (match($0, /\{\{ [a-z_]+ \}\}/)) {
                    placeholder = substr($0, RSTART, RLENGTH)
                    if      (placeholder == "{{ objective }}")        rep = obj
                    else if (placeholder == "{{ turns_used }}")       rep = tu
                    else if (placeholder == "{{ turn_budget }}")      rep = tb
                    else if (placeholder == "{{ remaining_turns }}")  rep = rt
                    else rep = placeholder
                    printf "%s%s", substr($0, 1, RSTART-1), rep
                    $0 = substr($0, RSTART + RLENGTH)
                }
                print $0
            }' "$template_file"
    fi
}

cmd_budget() {
    local budget_value="$1"

    if [[ -z "$budget_value" ]]; then
        echo "ERROR: Turn budget value required."
        echo "Usage: /goal budget <N>"
        echo "Provide a positive integer for the turn budget, or 0 to remove the budget."
        return 1
    fi

    if ! [[ "$budget_value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Turn budget must be a non-negative integer."
        return 1
    fi

    if ! goal_exists; then
        echo "ERROR: No goal exists. Set a goal first with /goal <objective>."
        return 1
    fi

    local budget_arg="$budget_value"
    if (( budget_value == 0 )); then
        # 0 means remove the budget (set to null/unlimited).
        budget_arg=""
    fi

    local result
    result="$(goal_update_turn_budget "$budget_arg")"
    local new_status turn_budget_display
    new_status="$(echo "$result" | jq -r '.status')"
    local status_label
    status_label="$(goal_status_label "$new_status")"

    local turn_budget_raw
    turn_budget_raw="$(echo "$result" | jq -r '.turn_budget // "null"')"
    if [[ "$turn_budget_raw" == "null" ]]; then
        turn_budget_display="none (unlimited)"
    else
        turn_budget_display="$turn_budget_raw"
    fi

    echo "Turn budget updated."
    echo "Status: ${status_label}"
    echo "Turn budget: ${turn_budget_display}"
}

# ---------------------------------------------------------------------------
# Main dispatcher
# ---------------------------------------------------------------------------

main() {
    # When called from a skill with "$ARGUMENTS", all args arrive as a single
    # string in $1. When called directly, args are separate. Normalize by
    # joining all args then extracting the first word as the subcommand.
    local full_args="$*"

    # Bare /goal — show summary.
    if [[ -z "$full_args" ]]; then
        cmd_show
        return
    fi

    # Extract first word as potential subcommand.
    local first_word rest
    first_word="${full_args%% *}"
    if [[ "$full_args" == *" "* ]]; then
        rest="${full_args#* }"
    else
        rest=""
    fi

    # Normalize to lowercase for matching.
    local subcmd_lower
    subcmd_lower="$(echo "$first_word" | tr '[:upper:]' '[:lower:]')"

    case "$subcmd_lower" in
        clear)
            cmd_clear
            ;;
        pause)
            cmd_pause
            ;;
        resume)
            cmd_resume
            ;;
        status)
            cmd_show
            ;;
        edit)
            cmd_edit "$rest"
            ;;
        budget)
            cmd_budget "$rest"
            ;;
        *)
            # Everything else is treated as an objective to create a goal.
            cmd_create "$full_args"
            ;;
    esac
}

main "$@"
