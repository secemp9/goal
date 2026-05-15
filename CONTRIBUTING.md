# Contributing to goal

Thank you for your interest in contributing.

## Getting Started

1. Fork and clone the repository
2. Run `./install.sh --claude` (or your preferred agent) to test the install
3. Make your changes in `src/`
4. Test manually by setting a goal and verifying hooks/MCP tools work

## Project Structure

```
src/
  goal_lib.sh                 # Core state library (all state operations)
  goal_cli.sh                 # CLI dispatcher for /goal command
  hooks/                      # Claude Code hooks
    stop_hook.sh              # Auto-continuation engine
    post_tool_batch_hook.sh   # Mid-turn budget monitor
    user_prompt_submit_hook.sh # Turn-start context injection
  mcp-server/
    goal_server.py            # MCP server (Python, stdio)
    run.sh                    # Launcher script
    requirements.txt          # Python dependencies
  templates/                  # Prompt templates (Mustache-style placeholders)
    continuation.md
    budget_limit.md
    objective_updated.md
  skill/
    SKILL.md                  # /goal slash command definition
  claude-md-fragment.md       # CLAUDE.md content for Claude Code
  agents-md-fragment.md       # AGENTS.md content for OpenCode
install.sh                    # Multi-agent installer
uninstall.sh                  # Multi-agent uninstaller
```

## Development Guidelines

### State Layer (`goal_lib.sh`)

The state library is the source of truth. All state mutations go through `goal_*` functions. The MCP server (`goal_server.py`) reimplements the same logic in Python to avoid shell overhead in the MCP protocol path, but both must produce identical state transitions.

If you change state behavior in one, change it in both.

### Hooks

Hooks are Claude Code specific. They read state via `goal_lib.sh` (sourced) and communicate with Claude Code via:
- **Stop hook**: exit code 0 (stop) or 2 (continue, with stderr as the prompt)
- **PostToolUse**: JSON on stdout with `hookSpecificOutput.additionalContext`
- **UserPromptSubmit**: JSON on stdout with `hookSpecificOutput.additionalContext`

### Templates

Templates use `{{ variable_name }}` placeholders (with spaces). Substitution is single-pass via awk to prevent template injection (an objective containing `{{ turns_used }}` must not be re-substituted).

### MCP Server

The MCP server uses the Python `mcp` package and runs as a local stdio process. It reads/writes the same `goal_state.json` file as the hooks. Tool schemas mirror Codex CLI's `goal_spec.rs`.

### Testing

Currently manual. To test:

1. Install for Claude Code: `./install.sh --claude`
2. Start a Claude Code session
3. Run `/goal improve test coverage`
4. Verify auto-continuation works (hook forces another turn)
5. Run `/goal pause` and verify Claude stops
6. Run `/goal resume` and verify continuation resumes
7. Test budgets: `/goal budget 3` and verify budget_limited transition

## Codex CLI Alignment

This project is a port of Codex CLI's goal system. When making changes, refer to the original Rust sources:

- `codex-rs/state/src/model/thread_goal.rs` -- data model
- `codex-rs/state/src/runtime/goals.rs` -- runtime lifecycle
- `codex-rs/core/src/tools/handlers/goal_spec.rs` -- tool schemas
- `codex-rs/core/src/tools/handlers/goal.rs` -- response formatting
- `codex-rs/protocol/src/protocol.rs` -- constants (MAX_THREAD_GOAL_OBJECTIVE_CHARS)

Deviations from Codex should be documented and justified.

## Pull Requests

- Keep PRs focused on a single change
- Describe what changed and why
- If changing state behavior, update both `goal_lib.sh` and `goal_server.py`
- Test with at least one agent before submitting
