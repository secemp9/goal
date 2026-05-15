---
name: goal
description: Set, view, pause, resume, edit, or clear a long-running goal
user-invocable: true
arguments: [args]
---

# /goal — Goal Management

Manage long-running, multi-turn goals with auto-continuation.

## Current State

!`bash ~/.goal/goal_cli.sh $ARGUMENTS 2>&1`

## Instructions

Present the output above to the user clearly. Follow these rules:

- If the user ran bare `/goal` (no arguments), display the goal summary as shown.
- If the user set a new goal (`/goal <text>`), confirm it was created. The hooks will now auto-continue this goal between turns.
- If the user ran `/goal clear`, confirm the goal was cleared.
- If the user ran `/goal pause`, confirm the goal was paused. Auto-continuation stops while paused.
- If the user ran `/goal resume`, confirm the goal was resumed. Auto-continuation will restart.
- If the user ran `/goal edit <text>`, confirm the objective was updated.
- If the user ran `/goal budget <N>`, confirm the budget was updated. Budget of 0 removes the limit.
- If the output starts with "WARNING:", inform the user of the conflict and suggest next steps.
- If the output starts with "ERROR:", explain the error clearly.

Do not create, modify, or complete goals through MCP tools in response to this command — the CLI script already handled the state change. Only use MCP tools (`create_goal`, `update_goal`) during active goal work, not during `/goal` command handling.
