#!/usr/bin/env bash
# stop_hook.sh — The auto-continuation engine for goal-driven sessions.
#
# Ported from Codex CLI's goal lifecycle:
#   goals.rs: finish_thread_goal_turn()
#   goals.rs: maybe_continue_goal_if_idle_runtime()
#   goals.rs: goal_continuation_candidate_if_active()
#   goals.rs: build_continuation_items() / continuation_prompt()
#
# Claude Code Stop hook contract:
#   - Exit 0: allow Claude to stop normally.
#   - Exit 2: force continuation. The message on stderr becomes the
#     continuation prompt that Claude sees on its next turn.
#
# Flow:
#   1. Read goal state.
#   2. If no active/budget_limited goal -> exit 0.
#   3. Compute wall-clock time delta from updated_at to now, persist it.
#   4. Increment turn counter (goal_increment_turn).
#   5. If goal was active and remains active -> render continuation.md, exit 2.
#   6. If goal just transitioned to budget_limited (increment returned 2) ->
#      render budget_limit.md, exit 2 (one wrap-up turn).
#   7. If goal was already budget_limited before this call -> exit 0 (wrap-up
#      turn already happened).
#   8. If goal is complete or paused -> exit 0.

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
# Template rendering
# ---------------------------------------------------------------------------

# escape_xml_text — Escape XML special characters in the objective.
# Mirrors Codex's escape_xml_text() in goals.rs.
escape_xml_text() {
    local text="$1"
    text="${text//&/&amp;}"
    text="${text//</&lt;}"
    text="${text//>/&gt;}"
    printf '%s' "$text"
}

# render_template — Substitute placeholders in a template file.
# Placeholders are {{ variable_name }} (with spaces around the name).
#
# IMPORTANT: Uses awk for SINGLE-PASS substitution to prevent template
# injection. If sequential bash ${//} were used, an objective containing
# "{{ turns_used }}" would be re-substituted in the second pass. Codex's
# Rust template engine is inherently single-pass; this awk approach matches.
render_template() {
    local template_file="$1"
    local objective="$2"
    local turns_used="$3"
    local turn_budget="$4"
    local remaining_turns="$5"
    local time_used_seconds="$6"

    # Escape the objective for XML safety.
    local escaped_objective
    escaped_objective="$(escape_xml_text "$objective")"

    # Single-pass substitution via awk. Each placeholder is replaced exactly
    # once; values injected for one placeholder are never re-scanned.
    #
    # The objective is passed via ENVIRON (not -v) to avoid awk's -v flag
    # interpreting C-style backslash sequences (\n, \t, \\). ENVIRON
    # passes the raw string. Numeric values are safe with -v (no backslashes).
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
                else rep = placeholder  # unknown placeholder: leave as-is
                printf "%s%s", substr($0, 1, RSTART-1), rep
                $0 = substr($0, RSTART + RLENGTH)
            }
            print $0
        }' "$template_file"
}

# wrap_goal_context — Wrap a prompt in <goal_context> tags.
# Mirrors Codex's GoalContext struct and ContextualUserFragment impl.
wrap_goal_context() {
    local prompt="$1"
    printf '<goal_context>\n%s\n</goal_context>' "$prompt"
}

# ---------------------------------------------------------------------------
# Main logic
# ---------------------------------------------------------------------------

# Check if a goal exists.
if ! goal_exists; then
    exit 0
fi

# Read current state.
json="$(goal_read)"
status="$(echo "$json" | jq -r '.status')"
objective="$(echo "$json" | jq -r '.objective')"
goal_id="$(echo "$json" | jq -r '.goal_id')"
turns_used="$(echo "$json" | jq -r '.turns_used')"
turn_budget_raw="$(echo "$json" | jq -r '.turn_budget // "null"')"
time_used_seconds="$(echo "$json" | jq -r '.time_used_seconds')"
updated_at="$(echo "$json" | jq -r '.updated_at')"

# If goal is complete or paused, let Claude stop.
if [[ "$status" == "complete" || "$status" == "paused" ]]; then
    exit 0
fi

# If goal was already budget_limited BEFORE this call, the wrap-up turn
# has already happened (the budget_limit prompt was shown on the previous
# continuation). Let Claude stop now.
# This mirrors Codex: goal_continuation_candidate_if_active() returns None
# when status != Active.
if [[ "$status" == "budget_limited" ]]; then
    exit 0
fi

# Goal is active — account wall-clock time.
now_epoch="$(date -u +%s)"
if [[ -n "$updated_at" && "$updated_at" != "null" ]]; then
    # Parse updated_at ISO-8601 to epoch.
    # Try GNU date -d first, fall back to python3 for macOS/BSD, then to no-op.
    updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null \
        || python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('$updated_at'.replace('Z','+00:00')).timestamp()))" 2>/dev/null \
        || echo "$now_epoch")"
    time_delta=$(( now_epoch - updated_epoch ))
    if (( time_delta < 0 )); then
        time_delta=0
    fi
else
    time_delta=0
fi

if (( time_delta > 0 )); then
    goal_update_time "$time_delta" >/dev/null
fi

# Increment turn counter. This may transition status to budget_limited.
# goal_increment_turn returns exit 2 on budget_limited transition, which
# set -e would treat as a fatal error. Capture the exit code explicitly.
increment_exit=0
increment_output="$(goal_increment_turn "$goal_id")" || increment_exit=$?

# Re-read state after increment (the output of goal_increment_turn is the
# updated JSON).
json="$increment_output"
status="$(echo "$json" | jq -r '.status')"
turns_used="$(echo "$json" | jq -r '.turns_used')"
time_used_seconds="$(echo "$json" | jq -r '.time_used_seconds')"

# Compute display values.
if [[ "$turn_budget_raw" == "null" ]]; then
    turn_budget_display="none"
    remaining_turns_display="unbounded"
else
    turn_budget_display="$turn_budget_raw"
    remaining=$(( turn_budget_raw - turns_used ))
    if (( remaining < 0 )); then
        remaining=0
    fi
    remaining_turns_display="$remaining"
fi

# Decide whether to continue.
if (( increment_exit == 2 )); then
    # Just transitioned to budget_limited on this increment.
    # Give Claude one wrap-up turn with the budget_limit prompt.
    prompt="$(render_template \
        "$TEMPLATE_DIR/budget_limit.md" \
        "$objective" \
        "$turns_used" \
        "$turn_budget_display" \
        "$remaining_turns_display" \
        "$time_used_seconds")"
    wrapped="$(wrap_goal_context "$prompt")"
    echo "$wrapped" >&2
    exit 2
elif [[ "$status" == "active" ]]; then
    # Goal is still active — continue with the full continuation prompt.
    prompt="$(render_template \
        "$TEMPLATE_DIR/continuation.md" \
        "$objective" \
        "$turns_used" \
        "$turn_budget_display" \
        "$remaining_turns_display" \
        "$time_used_seconds")"
    wrapped="$(wrap_goal_context "$prompt")"
    echo "$wrapped" >&2
    exit 2
else
    # Status is something unexpected (complete/paused set externally during
    # the turn). Let Claude stop.
    exit 0
fi
