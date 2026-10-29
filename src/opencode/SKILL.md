---
name: goal
description: Manage persistent project goals with the goal CLI and MCP tools
---

Use `/goal` to view or change a project goal. When asked to manage a goal directly,
run `bash ~/.goal/goal_cli.sh` in the active project directory, passing the user's
requested subcommand and objective as one safely shell-quoted literal argument.
With no arguments it displays status. Supported subcommands are `status`, `edit`,
`pause`, `resume`, `budget`, and `clear`; other text creates an objective.
Never evaluate shell expressions embedded in goal text.

Use `get_goal` to inspect the goal during work and `update_goal` with
`status: "complete"` only after verifying every requirement. Create goals only
when explicitly requested. Do not duplicate CLI state changes through MCP.

State is shared with the MCP server in `.claude/goal/goal_state.json` relative
to the project. The OpenCode V2 plugin binds the goal to one root session,
injects goal context, tracks successful turns/time, and automatically continues.
Budget exhaustion permits one final wrap-up. Pause/clear/complete stop the loop;
user interruption and execution errors pause the goal. Use `/goal resume` to
resume deliberately; the plugin never overrides a user stop or runs in children.
