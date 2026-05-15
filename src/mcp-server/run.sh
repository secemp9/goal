#!/usr/bin/env bash
# Launcher for the goal MCP server.
# Sets GOAL_STATE_FILE if not already set, then runs the server via stdio.
export GOAL_STATE_FILE="${GOAL_STATE_FILE:-${CLAUDE_PROJECT_DIR:-.}/.claude/goal/goal_state.json}"
exec python3 "$(dirname "$0")/goal_server.py"
