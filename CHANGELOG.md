# Changelog

## v0.1.0 (2025-05-15)

Initial release.

### Features

- **Goal state management** -- create, read, update, pause, resume, clear goals with JSON persistence
- **MCP server** -- `get_goal`, `create_goal`, `update_goal` tools via stdio for any MCP-compatible editor
- **Auto-continuation hooks** (Claude Code) -- Stop, PostToolBatch, and UserPromptSubmit hooks for autonomous multi-turn execution
- **Turn budgets** -- cap agent turns with automatic budget-limited transitions and wrap-up prompts
- **Completion audits** -- continuation prompt enforces evidence-based verification before marking goals complete
- **`/goal` slash command** (Claude Code) -- full CLI for goal lifecycle management
- **Multi-agent installer** -- `install.sh` with `--claude`, `--cursor`, `--opencode`, `--all` flags
- **Idempotent install/uninstall** -- safe to re-run without duplicating config entries

### Supported Agents

- **Claude Code** -- full experience (MCP + hooks + skill + CLAUDE.md)
- **Cursor** -- MCP tools only
- **OpenCode** -- MCP tools + skill + AGENTS.md

### Heritage

Ported from Codex CLI's Rust goal system (`thread_goal.rs`, `goals.rs`, `goal_spec.rs`, `goal_menu.rs`).
