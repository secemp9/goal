#!/usr/bin/env bash
# goal_lib.sh — Shared shell library for goal state persistence.
#
# Ported from Codex CLI's Rust state layer:
#   codex-rs/state/src/model/thread_goal.rs   (ThreadGoal, ThreadGoalStatus)
#   codex-rs/state/src/runtime/goals.rs       (insert, update, delete, accounting)
#   codex-rs/protocol/src/protocol.rs         (MAX_THREAD_GOAL_OBJECTIVE_CHARS = 4000)
#
# Data model mapping:
#   Codex (SQLite)              ->  Claude Code (JSON file)
#   -------------------------------------------------------
#   thread_id (PK, TEXT)        ->  (implicit — one goal per project)
#   goal_id (TEXT, UUID)        ->  goal_id (string, UUID for optimistic concurrency)
#   objective (TEXT)            ->  objective (string, max 4000 chars)
#   status (TEXT, enum)         ->  status (string: active|paused|budget_limited|complete)
#   token_budget (INTEGER|NULL) ->  turn_budget (integer|null — turns, not tokens)
#   tokens_used (INTEGER)       ->  tokens_used (integer, placeholder 0)
#   time_used_seconds (INTEGER) ->  time_used_seconds (integer)
#   created_at_ms (INTEGER)     ->  created_at (ISO-8601 string)
#   updated_at_ms (INTEGER)     ->  updated_at (ISO-8601 string)
#   (n/a)                       ->  turns_used (integer — primary budget metric)
#
# Dependencies: jq, uuidgen (or /proc/sys/kernel/random/uuid fallback)
# Usage: source this file, then call goal_* functions.
#
# NOTE: This is a library meant to be sourced. It does NOT set shell options
# (set -e/-u/-o pipefail) to avoid altering the caller's environment.
# Callers are responsible for their own error handling.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# State file path: overridable via env, defaults to project-relative location.
GOAL_STATE_FILE="${GOAL_STATE_FILE:-${CLAUDE_PROJECT_DIR:-.}/.claude/goal/goal_state.json}"

# Maximum objective length (matches Codex MAX_THREAD_GOAL_OBJECTIVE_CHARS).
MAX_OBJECTIVE_CHARS=4000

# Valid statuses (matches Codex ThreadGoalStatus enum).
VALID_STATUSES="active paused budget_limited complete"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_goal_ensure_dir() {
    local dir
    dir="$(dirname "$GOAL_STATE_FILE")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
    fi
}

_goal_generate_uuid() {
    # Prefer uuidgen if available, otherwise fall back to kernel random UUID.
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Last resort: pseudo-random via $RANDOM (not cryptographically secure).
        printf '%04x%04x-%04x-%04x-%04x-%04x%04x%04x\n' \
            $RANDOM $RANDOM $RANDOM \
            $(( ($RANDOM & 0x0FFF) | 0x4000 )) \
            $(( ($RANDOM & 0x3FFF) | 0x8000 )) \
            $RANDOM $RANDOM $RANDOM
    fi
}

_goal_now_iso() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_goal_now_epoch() {
    date -u +%s
}

_goal_validate_status() {
    local status="$1"
    local s
    for s in $VALID_STATUSES; do
        if [[ "$s" == "$status" ]]; then
            return 0
        fi
    done
    echo "goal_lib: invalid status '$status' (valid: $VALID_STATUSES)" >&2
    return 1
}

_goal_validate_objective() {
    local objective="$1"
    # Reject empty or whitespace-only objectives (Codex trims before validating).
    if [[ -z "$objective" || "$objective" =~ ^[[:space:]]*$ ]]; then
        echo "goal_lib: objective must not be empty" >&2
        return 1
    fi
    local char_count
    char_count="${#objective}"
    if (( char_count > MAX_OBJECTIVE_CHARS )); then
        echo "goal_lib: objective must be at most $MAX_OBJECTIVE_CHARS characters (got $char_count)" >&2
        return 1
    fi
    return 0
}

# Read the raw JSON from the state file. Returns "{}" if file is missing or empty.
_goal_read_raw() {
    if [[ -f "$GOAL_STATE_FILE" ]]; then
        local content
        content="$(cat "$GOAL_STATE_FILE")"
        if [[ -z "$content" || "$content" == "{}" ]]; then
            echo "{}"
        else
            echo "$content"
        fi
    else
        echo "{}"
    fi
}

# Atomically write JSON to the state file (write to temp, then mv).
_goal_write_raw() {
    local json="$1"
    _goal_ensure_dir
    local tmp="${GOAL_STATE_FILE}.tmp.$$"
    echo "$json" > "$tmp"
    mv -f "$tmp" "$GOAL_STATE_FILE"
}

# Check if the status should auto-transition to budget_limited.
# Mirrors Codex's status_after_budget_limit() function.
# For our port, we check turn_budget/turns_used instead of token_budget/tokens_used.
_goal_status_after_budget_limit() {
    local status="$1"
    local turns_used="$2"
    local turn_budget="$3"  # "null" or an integer

    if [[ "$status" == "active" && "$turn_budget" != "null" ]]; then
        if (( turns_used >= turn_budget )); then
            echo "budget_limited"
            return
        fi
    fi
    echo "$status"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# goal_read — Output the current goal state JSON to stdout.
# Returns "{}" if no goal exists.
goal_read() {
    _goal_read_raw
}

# goal_exists — Check if a goal currently exists.
# Returns 0 if a goal exists with a goal_id, 1 otherwise.
goal_exists() {
    local json
    json="$(_goal_read_raw)"
    local goal_id
    goal_id="$(echo "$json" | jq -r '.goal_id // empty')"
    if [[ -n "$goal_id" ]]; then
        return 0
    else
        return 1
    fi
}

# goal_create — Create a new goal (replaces any existing goal).
# Mirrors Codex's replace_thread_goal(): generates new goal_id, resets counters.
#
# Usage: goal_create <objective> [turn_budget]
#   objective   — The goal objective text (required, max 4000 chars).
#   turn_budget — Optional max turns. Omit or pass "" for unlimited.
#
# Outputs the new goal JSON to stdout.
goal_create() {
    local objective="${1:?goal_create: objective required}"
    local turn_budget="${2:-}"

    _goal_validate_objective "$objective" || return 1

    local goal_id now status turn_budget_json
    goal_id="$(_goal_generate_uuid)"
    now="$(_goal_now_iso)"

    if [[ -z "$turn_budget" ]]; then
        turn_budget_json="null"
    else
        # Validate it is a positive integer.
        if ! [[ "$turn_budget" =~ ^[0-9]+$ ]]; then
            echo "goal_lib: turn_budget must be a non-negative integer" >&2
            return 1
        fi
        turn_budget_json="$turn_budget"
    fi

    # Apply immediate budget limit check (mirrors Codex: budget=0 means instant limit).
    status="$(_goal_status_after_budget_limit "active" 0 "$turn_budget_json")"

    local json
    json="$(jq -n \
        --arg goal_id "$goal_id" \
        --arg objective "$objective" \
        --arg status "$status" \
        --argjson turn_budget "$turn_budget_json" \
        --arg created_at "$now" \
        --arg updated_at "$now" \
        '{
            goal_id: $goal_id,
            objective: $objective,
            status: $status,
            turn_budget: $turn_budget,
            turns_used: 0,
            tokens_used: 0,
            time_used_seconds: 0,
            created_at: $created_at,
            updated_at: $updated_at
        }'
    )"

    _goal_write_raw "$json"
    echo "$json"
}

# goal_update_status — Update the goal's status field.
# Mirrors Codex's update logic with budget-limit guardrails:
#   - Cannot downgrade from budget_limited to paused.
#   - Setting to active when already over budget keeps budget_limited.
#
# Usage: goal_update_status <new_status> [expected_goal_id]
# Outputs updated goal JSON, or returns 1 if no goal / goal_id mismatch.
goal_update_status() {
    local new_status="${1:?goal_update_status: status required}"
    local expected_goal_id="${2:-}"

    _goal_validate_status "$new_status" || return 1

    local json
    json="$(_goal_read_raw)"
    if ! echo "$json" | jq -e '.goal_id' &>/dev/null; then
        echo "goal_lib: no goal exists" >&2
        return 1
    fi

    # Optimistic concurrency: if expected_goal_id is set, verify it matches.
    if [[ -n "$expected_goal_id" ]]; then
        local current_id
        current_id="$(echo "$json" | jq -r '.goal_id')"
        if [[ "$current_id" != "$expected_goal_id" ]]; then
            echo "goal_lib: goal_id mismatch (expected=$expected_goal_id, current=$current_id)" >&2
            return 1
        fi
    fi

    local current_status turns_used turn_budget now effective_status
    current_status="$(echo "$json" | jq -r '.status')"
    turns_used="$(echo "$json" | jq -r '.turns_used')"
    turn_budget="$(echo "$json" | jq -r '.turn_budget // "null"')"
    now="$(_goal_now_iso)"

    # Codex rule: pausing a budget_limited goal preserves budget_limited.
    if [[ "$current_status" == "budget_limited" && "$new_status" == "paused" ]]; then
        effective_status="budget_limited"
    else
        # Check if trying to set active but already over budget.
        effective_status="$(_goal_status_after_budget_limit "$new_status" "$turns_used" "$turn_budget")"
    fi

    local updated
    updated="$(echo "$json" | jq \
        --arg status "$effective_status" \
        --arg updated_at "$now" \
        '. + {status: $status, updated_at: $updated_at}'
    )"

    _goal_write_raw "$updated"
    echo "$updated"
}

# goal_update_objective — Update the goal's objective text.
# Preserves all other fields (usage, created_at, etc.) exactly like Codex.
#
# Usage: goal_update_objective <new_objective> [expected_goal_id]
# Outputs updated goal JSON, or returns 1 if no goal / goal_id mismatch.
goal_update_objective() {
    local new_objective="${1:?goal_update_objective: objective required}"
    local expected_goal_id="${2:-}"

    _goal_validate_objective "$new_objective" || return 1

    local json
    json="$(_goal_read_raw)"
    if ! echo "$json" | jq -e '.goal_id' &>/dev/null; then
        echo "goal_lib: no goal exists" >&2
        return 1
    fi

    # Optimistic concurrency check.
    if [[ -n "$expected_goal_id" ]]; then
        local current_id
        current_id="$(echo "$json" | jq -r '.goal_id')"
        if [[ "$current_id" != "$expected_goal_id" ]]; then
            echo "goal_lib: goal_id mismatch (expected=$expected_goal_id, current=$current_id)" >&2
            return 1
        fi
    fi

    local now updated
    now="$(_goal_now_iso)"
    updated="$(echo "$json" | jq \
        --arg objective "$new_objective" \
        --arg updated_at "$now" \
        '. + {objective: $objective, updated_at: $updated_at}'
    )"

    _goal_write_raw "$updated"
    echo "$updated"
}

# goal_increment_turn — Increment turns_used by 1, check budget, auto-transition.
# Mirrors Codex's account_thread_goal_usage() for the turn dimension.
# Only increments if goal status is active (or budget_limited with ActiveOnly mode
# to account for in-flight usage, matching Codex's ActiveOnly filter).
#
# Usage: goal_increment_turn [expected_goal_id]
# Outputs updated goal JSON.
# Returns 0 on success, 1 if no goal or goal_id mismatch.
# Sets exit status 2 if the goal transitioned to budget_limited on this call.
goal_increment_turn() {
    local expected_goal_id="${1:-}"

    local json
    json="$(_goal_read_raw)"
    if ! echo "$json" | jq -e '.goal_id' &>/dev/null; then
        echo "goal_lib: no goal exists" >&2
        return 1
    fi

    # Optimistic concurrency check.
    if [[ -n "$expected_goal_id" ]]; then
        local current_id
        current_id="$(echo "$json" | jq -r '.goal_id')"
        if [[ "$current_id" != "$expected_goal_id" ]]; then
            echo "goal_lib: goal_id mismatch (expected=$expected_goal_id, current=$current_id)" >&2
            return 1
        fi
    fi

    local current_status
    current_status="$(echo "$json" | jq -r '.status')"

    # Matching Codex's ActiveOnly mode: update active or budget_limited goals.
    # (budget_limited goals still need to account for in-flight turns.)
    if [[ "$current_status" != "active" && "$current_status" != "budget_limited" ]]; then
        # Goal is paused or complete — do not increment, just return current state.
        echo "$json"
        return 0
    fi

    local turns_used turn_budget now new_turns new_status
    turns_used="$(echo "$json" | jq -r '.turns_used')"
    turn_budget="$(echo "$json" | jq -r '.turn_budget // "null"')"
    now="$(_goal_now_iso)"
    new_turns=$(( turns_used + 1 ))

    # Check if this increment crosses the budget threshold.
    # Only transition active -> budget_limited (not budget_limited -> budget_limited again).
    new_status="$current_status"
    local did_transition=0
    if [[ "$current_status" == "active" && "$turn_budget" != "null" ]]; then
        if (( new_turns >= turn_budget )); then
            new_status="budget_limited"
            did_transition=1
        fi
    fi

    local updated
    updated="$(echo "$json" | jq \
        --argjson turns_used "$new_turns" \
        --arg status "$new_status" \
        --arg updated_at "$now" \
        '. + {turns_used: $turns_used, status: $status, updated_at: $updated_at}'
    )"

    _goal_write_raw "$updated"
    echo "$updated"

    if (( did_transition )); then
        return 2
    fi
    return 0
}

# goal_update_time — Update time_used_seconds (add a delta or set absolute).
# Mirrors Codex's account_thread_goal_usage() for the time dimension.
#
# Usage: goal_update_time <seconds_delta>
#   seconds_delta — seconds to ADD to current time_used_seconds (must be >= 0).
# Outputs updated goal JSON.
goal_update_time() {
    local seconds_delta="${1:?goal_update_time: seconds_delta required}"

    if ! [[ "$seconds_delta" =~ ^[0-9]+$ ]]; then
        echo "goal_lib: seconds_delta must be a non-negative integer" >&2
        return 1
    fi

    # Codex clamps negative deltas to 0.
    if (( seconds_delta <= 0 )); then
        _goal_read_raw
        return 0
    fi

    local json
    json="$(_goal_read_raw)"
    if ! echo "$json" | jq -e '.goal_id' &>/dev/null; then
        echo "goal_lib: no goal exists" >&2
        return 1
    fi

    local current_time now new_time
    current_time="$(echo "$json" | jq -r '.time_used_seconds')"
    now="$(_goal_now_iso)"
    new_time=$(( current_time + seconds_delta ))

    local updated
    updated="$(echo "$json" | jq \
        --argjson time_used_seconds "$new_time" \
        --arg updated_at "$now" \
        '. + {time_used_seconds: $time_used_seconds, updated_at: $updated_at}'
    )"

    _goal_write_raw "$updated"
    echo "$updated"
}

# goal_clear — Delete/reset the goal (mirrors Codex's delete_thread_goal).
# Writes an empty object to the state file.
#
# Usage: goal_clear
# Returns 0 if a goal was cleared, 1 if no goal existed.
goal_clear() {
    local json
    json="$(_goal_read_raw)"

    local had_goal=0
    if echo "$json" | jq -e '.goal_id' &>/dev/null; then
        had_goal=1
    fi

    _goal_write_raw "{}"

    if (( had_goal )); then
        return 0
    else
        return 1
    fi
}

# goal_get_field — Get a specific field value from the current goal.
# Uses jq raw output, so strings come without quotes.
#
# Usage: goal_get_field <field_name>
# Outputs the field value to stdout. Returns 1 if no goal or field is null/missing.
goal_get_field() {
    local field="${1:?goal_get_field: field name required}"

    local json
    json="$(_goal_read_raw)"
    if ! echo "$json" | jq -e '.goal_id' &>/dev/null; then
        return 1
    fi

    local value
    value="$(echo "$json" | jq -r --arg f "$field" '.[$f] // empty')"
    if [[ -z "$value" ]]; then
        return 1
    fi
    echo "$value"
}

# goal_update_turn_budget — Update the turn_budget field.
# Mirrors Codex's update with token_budget: checks if the new budget
# causes an immediate transition to budget_limited.
#
# Usage: goal_update_turn_budget <new_turn_budget> [expected_goal_id]
#   new_turn_budget — new budget value, or "" to remove the budget (set null).
# Outputs updated goal JSON.
goal_update_turn_budget() {
    local new_turn_budget="${1:-}"
    local expected_goal_id="${2:-}"

    local json
    json="$(_goal_read_raw)"
    if ! echo "$json" | jq -e '.goal_id' &>/dev/null; then
        echo "goal_lib: no goal exists" >&2
        return 1
    fi

    # Optimistic concurrency check.
    if [[ -n "$expected_goal_id" ]]; then
        local current_id
        current_id="$(echo "$json" | jq -r '.goal_id')"
        if [[ "$current_id" != "$expected_goal_id" ]]; then
            echo "goal_lib: goal_id mismatch (expected=$expected_goal_id, current=$current_id)" >&2
            return 1
        fi
    fi

    local turn_budget_json
    if [[ -z "$new_turn_budget" ]]; then
        turn_budget_json="null"
    else
        if ! [[ "$new_turn_budget" =~ ^[0-9]+$ ]]; then
            echo "goal_lib: turn_budget must be a non-negative integer" >&2
            return 1
        fi
        turn_budget_json="$new_turn_budget"
    fi

    local current_status turns_used now effective_status
    current_status="$(echo "$json" | jq -r '.status')"
    turns_used="$(echo "$json" | jq -r '.turns_used')"
    now="$(_goal_now_iso)"

    # Codex: lowering the budget below current usage immediately triggers budget_limited.
    effective_status="$current_status"
    if [[ "$current_status" == "active" && "$turn_budget_json" != "null" ]]; then
        if (( turns_used >= turn_budget_json )); then
            effective_status="budget_limited"
        fi
    fi

    local updated
    updated="$(echo "$json" | jq \
        --argjson turn_budget "$turn_budget_json" \
        --arg status "$effective_status" \
        --arg updated_at "$now" \
        '. + {turn_budget: $turn_budget, status: $status, updated_at: $updated_at}'
    )"

    _goal_write_raw "$updated"
    echo "$updated"
}
