# goal

Persistent, multi-turn goal tracking with auto-continuation -- ported from [Codex CLI](https://github.com/openai/codex).

Works with **Claude Code**, **Cursor**, and **OpenCode**.

## Without goal

- Agent stops after one response -- you re-prompt manually to keep it going
- No persistent objective -- the agent forgets what it was working toward
- No budget tracking -- no way to limit or monitor turn usage
- No wrap-up behavior -- work just halts mid-task

## With goal

- Set a persistent objective that survives across turns
- Auto-continuation (Claude Code) -- the agent keeps working until the goal is done
- Turn budgets -- cap how many turns the agent gets, with automatic wrap-up
- Budget warnings -- the agent knows when to start summarizing
- Completion audits -- goals aren't marked done until evidence proves every requirement is met
- Pause/resume/edit -- full lifecycle control

## Quick Start

```bash
git clone https://github.com/anthropics/goal.git
cd goal
./install.sh
```

The installer auto-detects your coding agents and configures them. Use flags to target specific agents:

```bash
./install.sh --claude     # Claude Code only (full: MCP + hooks + skill + CLAUDE.md)
./install.sh --cursor     # Cursor only (MCP tools)
./install.sh --opencode   # OpenCode only (MCP + skill + AGENTS.md)
./install.sh --all        # All supported agents
```

### Prerequisites

- **bash 4+**
- **jq** -- [install](https://jqlang.github.io/jq/download/)
- **python3**
- **mcp** Python package -- `pip install mcp`

## Per-Editor Setup

### Claude Code

Claude Code gets the full experience: MCP tools, hooks for auto-continuation, the `/goal` slash command, and CLAUDE.md integration.

**Automatic:**
```bash
./install.sh --claude
```

**Manual:** Add to `~/.claude/settings.json`:
```json
{
  "mcpServers": {
    "goal": {
      "command": "python3",
      "args": ["/home/YOUR_USER/.goal/mcp-server/goal_server.py"]
    }
  },
  "hooks": {
    "Stop": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/home/YOUR_USER/.goal/hooks/stop_hook.sh"}]}
    ],
    "PostToolBatch": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/home/YOUR_USER/.goal/hooks/post_tool_batch_hook.sh"}]}
    ],
    "UserPromptSubmit": [
      {"matcher": "", "hooks": [{"type": "command", "command": "/home/YOUR_USER/.goal/hooks/user_prompt_submit_hook.sh"}]}
    ]
  }
}
```

Then copy `src/skill/SKILL.md` to `~/.claude/skills/goal.md` and append `src/claude-md-fragment.md` to your project's `CLAUDE.md`.

### Cursor

Cursor gets MCP tools only (no auto-continuation).

**Automatic:**
```bash
./install.sh --cursor
```

**Manual:** Add to `.cursor/mcp.json` in your project:
```json
{
  "mcpServers": {
    "goal": {
      "command": "python3",
      "args": ["/home/YOUR_USER/.goal/mcp-server/goal_server.py"]
    }
  }
}
```

### OpenCode

OpenCode gets MCP tools, a `/goal` skill, and AGENTS.md integration (no auto-continuation hooks).

**Automatic:**
```bash
./install.sh --opencode
```

This registers the MCP server, installs the `/goal` skill to `.agents/skills/goal/SKILL.md`, and injects goal system docs into `AGENTS.md` (OpenCode reads `AGENTS.md` like Claude Code reads `CLAUDE.md`).

**Manual:** Add to `opencode.json` (or `opencode.jsonc`, `.opencode.json`, `.opencode.jsonc`) in your project, or `~/.config/opencode/opencode.json` globally:
```json
{
  "mcp": {
    "goal": {
      "type": "local",
      "command": ["python3", "~/.goal/mcp-server/goal_server.py"],
      "enabled": true
    }
  }
}
```

Then copy `src/skill/SKILL.md` to `.agents/skills/goal/SKILL.md` and append `src/agents-md-fragment.md` to your project's `AGENTS.md` between `<!-- goal-system -->` and `<!-- /goal-system -->` markers.

> **Note:** OpenCode has a plugin system that could enable deeper integration (auto-continuation, hooks) in the future.

> **Note:** Replace `~/.goal` with the full path if your shell does not expand tilde in JSON values (`echo $HOME`).

## Usage

### Claude Code (full experience)

Claude Code users get the `/goal` slash command:

| Command | Description |
|---------|-------------|
| `/goal <objective>` | Set a new goal |
| `/goal` | Show current goal status |
| `/goal edit <text>` | Update the objective |
| `/goal pause` | Pause auto-continuation |
| `/goal resume` | Resume a paused goal |
| `/goal budget <N>` | Set turn budget (0 = unlimited) |
| `/goal clear` | Clear the current goal |

Once a goal is set, Claude Code auto-continues between turns until the goal is complete, paused, or budget-limited.

### All Editors (MCP tools)

All editors get these MCP tools:

| Tool | Description |
|------|-------------|
| `get_goal` | Read current goal state (status, objective, budget, usage) |
| `create_goal` | Create a new goal with an objective and optional turn budget |
| `update_goal` | Mark the goal complete (only when truly finished) |

**Important:** `create_goal` fails if a goal already exists. Use `update_goal` with `status: "complete"` only when the objective is fully achieved.

## How It Works

### Architecture

```
~/.goal/                          # Global install (shared by all editors)
  goal_lib.sh                     # Core state library (bash)
  goal_cli.sh                     # CLI dispatcher for /goal command
  hooks/
    stop_hook.sh                  # Auto-continuation engine (Claude Code)
    post_tool_batch_hook.sh       # Mid-turn budget monitor (Claude Code)
    user_prompt_submit_hook.sh    # Turn-start context injection (Claude Code)
  mcp-server/
    goal_server.py                # MCP server (stdio, python3)
    run.sh                        # Launcher script
    requirements.txt              # Python dependencies
  templates/
    continuation.md               # Continuation prompt template
    budget_limit.md               # Budget-limited wrap-up template
    objective_updated.md          # Objective edit notification template
  skill/
    SKILL.md                      # /goal slash command definition
  claude-md-fragment.md           # CLAUDE.md content for goal awareness
  agents-md-fragment.md           # AGENTS.md content for goal awareness (OpenCode)

.claude/goal/goal_state.json      # Per-project state file (created at runtime)
```

### State Model

Goal state is persisted as JSON (one goal per project):

| Field | Type | Description |
|-------|------|-------------|
| `goal_id` | UUID | Unique identifier (optimistic concurrency) |
| `objective` | string | The goal text (max 4000 chars) |
| `status` | enum | `active`, `paused`, `budget_limited`, `complete` |
| `turn_budget` | int/null | Max turns allowed (null = unlimited) |
| `turns_used` | int | Turns consumed so far |
| `tokens_used` | int | Placeholder (0, for Codex compatibility) |
| `time_used_seconds` | int | Wall-clock seconds spent |
| `created_at` | ISO-8601 | Creation timestamp |
| `updated_at` | ISO-8601 | Last update timestamp |

### Hook Lifecycle (Claude Code only)

1. **UserPromptSubmit** -- Injects a brief goal reminder at the start of each turn
2. **PostToolBatch** -- Monitors budget proximity mid-turn, warns when close
3. **Stop** -- The auto-continuation engine:
   - Accounts wall-clock time
   - Increments turn counter
   - If active and within budget: renders continuation prompt, forces another turn
   - If just hit budget limit: renders wrap-up prompt, gives one final turn
   - If already budget-limited, paused, or complete: lets Claude stop

### Codex CLI Heritage

This system is a faithful port of Codex CLI's goal architecture:

| Codex (Rust/SQLite) | goal (bash/JSON) |
|---------------------|-------------------|
| `ThreadGoal` struct | `goal_state.json` |
| `token_budget` / `tokens_used` | `turn_budget` / `turns_used` |
| `goal_spec.rs` tool definitions | `goal_server.py` MCP tools |
| `goals.rs` runtime lifecycle | Hook scripts |
| `goal_menu.rs` display | `goal_cli.sh` |

## Auto-Continuation Note

**Auto-continuation (hooks) is Claude Code only.** Other editors (Cursor, OpenCode) get the MCP tools (`get_goal`, `create_goal`, `update_goal`) but do not have hook support, so they cannot auto-continue between turns. Users of those editors need to manually prompt the agent to continue working toward the goal.

## Uninstalling

```bash
./uninstall.sh --all      # Remove from all agents + delete ~/.goal/
./uninstall.sh --claude   # Remove from Claude Code only
```

## License

MIT

## Credits

Ported from [Codex CLI](https://github.com/openai/codex) by OpenAI. The goal system architecture -- state model, continuation logic, budget accounting, and completion auditing -- originates from Codex CLI's Rust implementation.
