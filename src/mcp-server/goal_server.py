"""
MCP server for goal tools — Layer 3 of the Claude Code /goal system.

Provides get_goal, create_goal, and update_goal tools that read/write the
same goal_state.json file used by the hook layer.

Ported from Codex CLI:
  codex-rs/core/src/tools/handlers/goal_spec.rs   (tool definitions)
  codex-rs/core/src/tools/handlers/goal.rs         (response formatting)
  codex-rs/core/src/tools/handlers/goal/*.rs       (handler logic)
  codex-rs/core/src/goals.rs                       (runtime lifecycle)
"""

import asyncio
import json
import os
import uuid
from datetime import datetime, timezone
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.shared.exceptions import McpError
import mcp.types as types

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

GOAL_STATE_FILE = os.environ.get(
    "GOAL_STATE_FILE",
    os.path.join(os.environ.get("CLAUDE_PROJECT_DIR", "."), ".claude", "goal", "goal_state.json"),
)

MAX_OBJECTIVE_CHARS = 4000

# ---------------------------------------------------------------------------
# State helpers (mirror goal_lib.sh)
# ---------------------------------------------------------------------------


def _ensure_dir() -> None:
    parent = os.path.dirname(GOAL_STATE_FILE)
    if parent:
        os.makedirs(parent, exist_ok=True)


def _read_raw() -> dict:
    """Read goal state, returning {} if no file or empty."""
    try:
        with open(GOAL_STATE_FILE, "r") as f:
            content = f.read().strip()
            if not content or content == "{}":
                return {}
            return json.loads(content)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _write_raw(data: dict) -> None:
    """Atomically write goal state JSON."""
    _ensure_dir()
    tmp = GOAL_STATE_FILE + f".tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    os.replace(tmp, GOAL_STATE_FILE)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _goal_exists(state: dict) -> bool:
    return bool(state.get("goal_id"))


def _status_after_budget_limit(status: str, turns_used: int, turn_budget) -> str:
    """Mirror goal_lib.sh _goal_status_after_budget_limit."""
    if status == "active" and turn_budget is not None:
        if turns_used >= turn_budget:
            return "budget_limited"
    return status


# ---------------------------------------------------------------------------
# Response formatting (mirrors goal.rs GoalToolResponse)
# ---------------------------------------------------------------------------

# Codex uses camelCase for GoalToolResponse fields and the protocol ThreadGoal
# uses snake_case internally but is serialised with camelCase via serde.
# Our JSON file uses snake_case (goal_lib.sh). We build the response to match
# what the Codex model sees: camelCase wrapper with the goal object inside.


def _format_goal_response(goal: dict | None, include_completion_report: bool = False) -> str:
    """
    Build the JSON response the model sees, matching Codex's GoalToolResponse.

    Codex response shape (camelCase):
      { goal, remainingTokens, completionBudgetReport }

    Our port adapts token fields to turn fields while keeping the same shape.
    """
    response: dict = {}

    if goal and _goal_exists(goal):
        # Build the goal object the model sees.
        # Adapt field names: our state uses turn_budget/turns_used, Codex uses
        # token_budget/tokens_used.  We expose BOTH so the model understands
        # the turn-based budget AND sees the Codex-shaped fields it expects.
        goal_obj = {
            "objective": goal.get("objective", ""),
            "status": goal.get("status", "active"),
            "turnBudget": goal.get("turn_budget"),
            "turnsUsed": goal.get("turns_used", 0),
            "tokensUsed": goal.get("tokens_used", 0),
            "timeUsedSeconds": goal.get("time_used_seconds", 0),
            "createdAt": goal.get("created_at", ""),
            "updatedAt": goal.get("updated_at", ""),
        }
        response["goal"] = goal_obj

        # remainingTurns (analogous to Codex remainingTokens)
        turn_budget = goal.get("turn_budget")
        if turn_budget is not None:
            response["remainingTurns"] = max(0, turn_budget - goal.get("turns_used", 0))
        else:
            response["remainingTurns"] = None

        # completionBudgetReport — only for update_goal marking complete
        if include_completion_report and goal.get("status") == "complete":
            report = _completion_budget_report(goal)
            if report:
                response["completionBudgetReport"] = report
    else:
        response["goal"] = None
        response["remainingTurns"] = None

    return json.dumps(response, indent=2)


def _completion_budget_report(goal: dict) -> str | None:
    """
    Mirror Codex completion_budget_report(): produce a human-readable summary
    of budget usage for completed goals.
    """
    parts: list[str] = []
    turn_budget = goal.get("turn_budget")
    if turn_budget is not None:
        parts.append(f"turns used: {goal.get('turns_used', 0)} of {turn_budget}")
    time_used = goal.get("time_used_seconds", 0)
    if time_used > 0:
        parts.append(f"time used: {time_used} seconds")
    if not parts:
        return None
    return f"Goal achieved. Report final budget usage to the user: {'; '.join(parts)}."


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------

server = Server("goal-server")


@server.list_tools()
async def list_tools() -> list[types.Tool]:
    return [
        # get_goal — mirrors create_get_goal_tool() in goal_spec.rs
        types.Tool(
            name="get_goal",
            description=(
                "Get the current goal for this thread, including status, budgets, "
                "turn and elapsed-time usage, and remaining turn budget."
            ),
            inputSchema={
                "type": "object",
                "properties": {},
                "required": [],
                "additionalProperties": False,
            },
        ),
        # create_goal — mirrors create_create_goal_tool() in goal_spec.rs
        types.Tool(
            name="create_goal",
            description=(
                "Create a goal only when explicitly requested by the user or "
                "system/developer instructions; do not infer goals from ordinary tasks.\n"
                "Set turn_budget only when an explicit turn budget is requested. "
                "Fails if a goal exists; use update_goal only for status."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "objective": {
                        "type": "string",
                        "description": (
                            "Required. The concrete objective to start pursuing. "
                            "This starts a new active goal only when no goal is "
                            "currently defined; if a goal already exists, this tool fails."
                        ),
                    },
                    "turn_budget": {
                        "type": "integer",
                        "description": (
                            "Optional positive turn budget for the new active goal."
                        ),
                    },
                },
                "required": ["objective"],
                "additionalProperties": False,
            },
        ),
        # update_goal — mirrors create_update_goal_tool() in goal_spec.rs
        types.Tool(
            name="update_goal",
            description=(
                "Update the existing goal.\n"
                "Use this tool only to mark the goal achieved.\n"
                "Set status to `complete` only when the objective has actually been "
                "achieved and no required work remains.\n"
                "Do not mark a goal complete merely because its budget is nearly "
                "exhausted or because you are stopping work.\n"
                "You cannot use this tool to pause, resume, or budget-limit a goal; "
                "those status changes are controlled by the user or system.\n"
                "When marking a budgeted goal achieved with status `complete`, "
                "report the final turn usage from the tool result to the user."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "status": {
                        "type": "string",
                        "enum": ["complete"],
                        "description": (
                            "Required. Set to complete only when the objective is "
                            "achieved and no required work remains."
                        ),
                    },
                },
                "required": ["status"],
                "additionalProperties": False,
            },
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict):
    if name == "get_goal":
        return _handle_get_goal()
    elif name == "create_goal":
        return _handle_create_goal(arguments)
    elif name == "update_goal":
        return _handle_update_goal(arguments)
    else:
        raise McpError(
            types.ErrorData(code=types.INVALID_PARAMS, message=f"Unknown tool: {name}")
        )


# ---------------------------------------------------------------------------
# Tool handlers
# ---------------------------------------------------------------------------


def _handle_get_goal() :
    """
    Mirror GetGoalHandler::handle in get_goal.rs.
    Returns current goal state or a message if no goal exists.
    """
    state = _read_raw()
    if not _goal_exists(state):
        text = _format_goal_response(None)
    else:
        text = _format_goal_response(state, include_completion_report=False)
    return [types.TextContent(type="text", text=text)]


def _handle_create_goal(arguments: dict) :
    """
    Mirror CreateGoalHandler::handle in create_goal.rs.
    Creates a new goal. FAILS if a goal already exists.
    """
    objective = arguments.get("objective")
    if not objective or not isinstance(objective, str):
        raise McpError(
            types.ErrorData(
                code=types.INVALID_PARAMS,
                message="objective is required and must be a non-empty string",
            )
        )

    objective = objective.strip()
    if not objective:
        raise McpError(
            types.ErrorData(
                code=types.INVALID_PARAMS,
                message="objective must not be empty",
            )
        )

    if len(objective) > MAX_OBJECTIVE_CHARS:
        raise McpError(
            types.ErrorData(
                code=types.INVALID_PARAMS,
                message=f"objective must be at most {MAX_OBJECTIVE_CHARS} characters (got {len(objective)})",
            )
        )

    turn_budget = arguments.get("turn_budget")
    if turn_budget is not None:
        if isinstance(turn_budget, bool) or not isinstance(turn_budget, int) or turn_budget <= 0:
            raise McpError(
                types.ErrorData(
                    code=types.INVALID_PARAMS,
                    message="turn_budget must be a positive integer when provided",
                )
            )

    # Check if a goal already exists — create_goal fails if so.
    # Mirrors Codex insert_thread_goal which returns None when a goal exists.
    state = _read_raw()
    if _goal_exists(state):
        # Mirror the exact error from create_goal.rs.
        # Return CallToolResult directly so isError propagates at the protocol level.
        return types.CallToolResult(
            content=[
                types.TextContent(
                    type="text",
                    text=(
                        "cannot create a new goal because this thread already has a goal; "
                        "use update_goal only when the existing goal is complete"
                    ),
                )
            ],
            isError=True,
        )

    now = _now_iso()
    goal_id = str(uuid.uuid4())

    # Determine initial status (budget=0 means instant limit, matching Codex).
    status = _status_after_budget_limit("active", 0, turn_budget)

    new_state = {
        "goal_id": goal_id,
        "objective": objective,
        "status": status,
        "turn_budget": turn_budget,
        "turns_used": 0,
        "tokens_used": 0,
        "time_used_seconds": 0,
        "created_at": now,
        "updated_at": now,
    }

    _write_raw(new_state)
    text = _format_goal_response(new_state, include_completion_report=False)
    return [types.TextContent(type="text", text=text)]


def _handle_update_goal(arguments: dict) :
    """
    Mirror UpdateGoalHandler::handle in update_goal.rs.
    Only accepts status="complete". Returns final usage stats.
    """
    status = arguments.get("status")

    # Validate status is exactly "complete".
    # Mirrors the explicit check in update_goal.rs.
    if status != "complete":
        return types.CallToolResult(
            content=[
                types.TextContent(
                    type="text",
                    text=(
                        "update_goal can only mark the existing goal complete; "
                        "pause, resume, and budget-limited status changes are "
                        "controlled by the user or system"
                    ),
                )
            ],
            isError=True,
        )

    state = _read_raw()
    if not _goal_exists(state):
        return types.CallToolResult(
            content=[
                types.TextContent(
                    type="text",
                    text="cannot update goal: no goal exists",
                )
            ],
            isError=True,
        )

    # Mark goal complete. Mirror goal_lib.sh goal_update_status.
    now = _now_iso()
    state["status"] = "complete"
    state["updated_at"] = now
    _write_raw(state)

    # Return with CompletionBudgetReport::Include (matching update_goal.rs).
    text = _format_goal_response(state, include_completion_report=True)
    return [types.TextContent(type="text", text=text)]


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options(),
        )


if __name__ == "__main__":
    asyncio.run(main())
