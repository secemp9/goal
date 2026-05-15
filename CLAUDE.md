<!-- goal-system -->
# Goal System

This project has a goal system (ported from Codex CLI) for long-running, multi-turn tasks.

## How it works
- Goals persist in `.claude/goal/goal_state.json` with status, objective, turn/time accounting.
- Hooks auto-continue active goals between turns — you do not manage the continuation loop.
- The `/goal` slash command is the user interface. Users set, view, pause, resume, edit, and clear goals through it.

## MCP tools (goal-server)
- `get_goal` — read current goal state (status, objective, budget, usage).
- `create_goal` — create a new goal. Only call when the user explicitly requests a goal. Do not infer goals from ordinary tasks. Fails if a goal already exists.
- `update_goal` — mark a goal complete. Only accepts `status: "complete"`. Only call when the objective is fully achieved and no required work remains. Do not mark complete merely because the budget is nearly exhausted or because you are stopping.

## Completion standard
Before marking a goal complete, perform the completion audit defined in the continuation prompt:
- Derive concrete requirements from the objective.
- For every requirement, inspect authoritative evidence (files, test output, runtime state).
- Treat uncertain or indirect evidence as not achieved.
- Only mark complete when every requirement is proven satisfied.

## What you should NOT do
- Do not create goals unless the user explicitly asks (via `/goal <objective>` or direct instruction).
- Do not call `update_goal` with status "complete" unless the objective is truly done.
- Do not pause, resume, or clear goals — those are user-controlled via `/goal pause`, `/goal resume`, `/goal clear`.
- Do not redefine success around a smaller or easier task to claim completion.

## Budget
- Goals may have a turn budget. The hooks track turns and transition to `budget_limited` automatically.
- When budget-limited, wrap up and summarize rather than starting new work.
- If a budgeted goal is completed, report final turn usage to the user.

<!-- /goal-system -->
