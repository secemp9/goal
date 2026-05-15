#!/usr/bin/env bash
# install.sh — Install goal for Claude Code, Cursor, and/or OpenCode.
#
# Usage:
#   ./install.sh            — auto-detect or prompt
#   ./install.sh --claude   — Claude Code only
#   ./install.sh --cursor   — Cursor only
#   ./install.sh --opencode — OpenCode only
#   ./install.sh --all      — all supported agents

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INSTALL_DIR="$HOME/.goal"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/src"

# Agents to install for (populated by flag parsing or auto-detect).
declare -a AGENTS=()

# ---------------------------------------------------------------------------
# Colors / output helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { printf "${BLUE}[info]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[ok]${NC}   %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
error()   { printf "${RED}[err]${NC}  %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------

check_prerequisites() {
    local missing=0

    # bash 4+ (for associative arrays, though we don't use them here, it's a
    # good baseline for modern bash features).
    if (( BASH_VERSINFO[0] < 4 )); then
        error "bash 4+ is required (found ${BASH_VERSION})"
        missing=1
    fi

    # jq — used by goal_lib.sh and install.sh for JSON manipulation.
    if ! command -v jq &>/dev/null; then
        error "jq is required but not found. Install it: https://jqlang.github.io/jq/download/"
        missing=1
    fi

    # python3 — used by the MCP server.
    if ! command -v python3 &>/dev/null; then
        error "python3 is required but not found."
        missing=1
    fi

    # pip mcp module — required by goal_server.py.
    if command -v python3 &>/dev/null; then
        if ! python3 -c "import mcp" &>/dev/null 2>&1; then
            warn "Python 'mcp' package not found. Installing..."
            if python3 -m pip install mcp &>/dev/null 2>&1; then
                success "Installed Python 'mcp' package."
            else
                error "Failed to install Python 'mcp' package. Run: pip install mcp"
                missing=1
            fi
        fi
    fi

    if (( missing )); then
        error "Missing prerequisites. Please install them and retry."
        exit 1
    fi

    success "All prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Agent detection
# ---------------------------------------------------------------------------

detect_agents() {
    local detected=()

    # Claude Code: look for ~/.claude or .claude/ in CWD
    if [[ -d "$HOME/.claude" ]] || [[ -d ".claude" ]]; then
        detected+=("claude")
    fi

    # Cursor: look for ~/.cursor or .cursor/ in CWD
    if [[ -d "$HOME/.cursor" ]] || [[ -d ".cursor" ]]; then
        detected+=("cursor")
    fi

    # OpenCode: look for opencode.json in CWD or ~/.config/opencode/
    if [[ -f "opencode.json" ]] || [[ -f ".opencode.json" ]] || [[ -d "$HOME/.config/opencode" ]]; then
        detected+=("opencode")
    fi

    if (( ${#detected[@]} == 0 )); then
        echo ""
    else
        printf '%s\n' "${detected[@]}"
    fi
}

prompt_agent_selection() {
    info "No agent flag specified. Detected agents:"
    local detected
    detected="$(detect_agents)"

    if [[ -z "$detected" ]]; then
        warn "No agents detected. Please specify one: --claude, --cursor, --opencode, or --all"
        exit 1
    fi

    local i=1
    local -a options=()
    while IFS= read -r agent; do
        case "$agent" in
            claude)   printf "  %d) Claude Code\n" "$i" ;;
            cursor)   printf "  %d) Cursor\n" "$i" ;;
            opencode) printf "  %d) OpenCode\n" "$i" ;;
        esac
        options+=("$agent")
        ((i++))
    done <<< "$detected"
    printf "  %d) All detected\n" "$i"

    printf "\nSelect agent(s) to install for [1-%d]: " "$i"
    read -r choice

    if [[ "$choice" == "$i" ]]; then
        AGENTS=("${options[@]}")
    elif (( choice >= 1 && choice < i )); then
        AGENTS=("${options[$((choice-1))]}")
    else
        error "Invalid selection."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Core install: copy src/ to ~/.goal/
# ---------------------------------------------------------------------------

install_core() {
    info "Installing goal to $INSTALL_DIR ..."

    # Create directory structure.
    mkdir -p "$INSTALL_DIR"/{hooks,mcp-server,templates,skill}

    # Copy all source files.
    cp "$SRC_DIR/goal_lib.sh"                   "$INSTALL_DIR/goal_lib.sh"
    cp "$SRC_DIR/goal_cli.sh"                   "$INSTALL_DIR/goal_cli.sh"
    cp "$SRC_DIR/hooks/stop_hook.sh"            "$INSTALL_DIR/hooks/stop_hook.sh"
    cp "$SRC_DIR/hooks/post_tool_batch_hook.sh" "$INSTALL_DIR/hooks/post_tool_batch_hook.sh"
    cp "$SRC_DIR/hooks/user_prompt_submit_hook.sh" "$INSTALL_DIR/hooks/user_prompt_submit_hook.sh"
    cp "$SRC_DIR/mcp-server/goal_server.py"     "$INSTALL_DIR/mcp-server/goal_server.py"
    cp "$SRC_DIR/mcp-server/run.sh"             "$INSTALL_DIR/mcp-server/run.sh"
    cp "$SRC_DIR/mcp-server/requirements.txt"   "$INSTALL_DIR/mcp-server/requirements.txt"
    cp "$SRC_DIR/templates/continuation.md"     "$INSTALL_DIR/templates/continuation.md"
    cp "$SRC_DIR/templates/budget_limit.md"     "$INSTALL_DIR/templates/budget_limit.md"
    cp "$SRC_DIR/templates/objective_updated.md" "$INSTALL_DIR/templates/objective_updated.md"
    cp "$SRC_DIR/skill/SKILL.md"                "$INSTALL_DIR/skill/SKILL.md"
    cp "$SRC_DIR/claude-md-fragment.md"         "$INSTALL_DIR/claude-md-fragment.md"
    cp "$SRC_DIR/agents-md-fragment.md"         "$INSTALL_DIR/agents-md-fragment.md"

    # Make shell scripts executable.
    chmod +x "$INSTALL_DIR/goal_lib.sh"
    chmod +x "$INSTALL_DIR/goal_cli.sh"
    chmod +x "$INSTALL_DIR/hooks/stop_hook.sh"
    chmod +x "$INSTALL_DIR/hooks/post_tool_batch_hook.sh"
    chmod +x "$INSTALL_DIR/hooks/user_prompt_submit_hook.sh"
    chmod +x "$INSTALL_DIR/mcp-server/run.sh"

    success "Core files installed to $INSTALL_DIR"
}

# ---------------------------------------------------------------------------
# JSON config helpers (using jq)
# ---------------------------------------------------------------------------

# strip_jsonc — Strip // and /* */ comments from JSONC content.
# Required because jq cannot parse JSONC. OpenCode uses .jsonc files.
strip_jsonc() {
    # String-aware JSONC comment stripper. Preserves // inside quoted strings
    # (e.g., URLs like "https://example.com"). Uses perl alternation: match
    # quoted strings first (and keep them), then match comments (and remove).
    perl -0777 -pe '
        s{ ("(?:[^"\\\\]|\\\\.)*") | (//[^\n]*) | (/\*.*?\*/) }
         { defined($1) ? $1 : "" }gsxe
    ' 2>/dev/null || cat
}

# read_json_file — Read a JSON or JSONC file, stripping comments if needed.
read_json_file() {
    local filepath="$1"
    if [[ ! -f "$filepath" ]]; then
        echo '{}'
        return
    fi
    if [[ "$filepath" == *.jsonc ]]; then
        strip_jsonc < "$filepath"
    else
        cat "$filepath"
    fi
}

# ensure_json_file — Create a JSON file with {} if it doesn't exist.
ensure_json_file() {
    local filepath="$1"
    local dir
    dir="$(dirname "$filepath")"
    mkdir -p "$dir"
    if [[ ! -f "$filepath" ]]; then
        echo '{}' > "$filepath"
    fi
}

# json_has_key — Check if a top-level key or nested key exists.
# Usage: json_has_key <file> <jq_path>
json_has_key() {
    local filepath="$1"
    local jq_path="$2"
    jq -e "$jq_path" "$filepath" &>/dev/null
}

# ---------------------------------------------------------------------------
# Agent-specific installers
# ---------------------------------------------------------------------------

install_claude() {
    info "Configuring Claude Code..."

    local settings_file="$HOME/.claude/settings.json"
    ensure_json_file "$settings_file"

    local server_path="$INSTALL_DIR/mcp-server/goal_server.py"

    # Register MCP server.
    local tmp
    tmp="$(mktemp)"
    jq --arg path "$server_path" \
        '.mcpServers = (.mcpServers // {}) | .mcpServers.goal = {"command": "python3", "args": [$path]}' \
        "$settings_file" > "$tmp"
    mv -f "$tmp" "$settings_file"
    success "Registered MCP server in $settings_file"

    # Register hooks.
    local stop_hook="$INSTALL_DIR/hooks/stop_hook.sh"
    local post_tool_hook="$INSTALL_DIR/hooks/post_tool_batch_hook.sh"
    local user_prompt_hook="$INSTALL_DIR/hooks/user_prompt_submit_hook.sh"

    # Claude Code hooks use a matcher + hooks array format:
    # {"EventName": [{"matcher": "", "hooks": [{"type": "command", "command": "..."}]}]}
    tmp="$(mktemp)"
    jq --arg stop "$stop_hook" \
       --arg post "$post_tool_hook" \
       --arg user "$user_prompt_hook" \
        '
        # Ensure a hook command exists inside the matcher+hooks structure.
        # Each event is an array of {matcher, hooks[]} objects.
        def ensure_hook_entry($cmd):
            . as $arr |
            if ($arr == null) then
                [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
            elif ([$arr[] | .hooks[]? | select(.command == $cmd)] | length) > 0 then
                $arr
            else
                # Append to existing matcher="" entry, or create one
                if ([$arr[] | select(.matcher == "")] | length) > 0 then
                    [$arr[] | if .matcher == "" then .hooks += [{"type": "command", "command": $cmd}] else . end]
                else
                    $arr + [{"matcher": "", "hooks": [{"type": "command", "command": $cmd}]}]
                end
            end;

        .hooks = (.hooks // {})
        | .hooks.Stop = (.hooks.Stop | ensure_hook_entry($stop))
        | .hooks.PostToolUse = (.hooks.PostToolUse | ensure_hook_entry($post))
        | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit | ensure_hook_entry($user))
        ' "$settings_file" > "$tmp"
    mv -f "$tmp" "$settings_file"
    success "Registered hooks in $settings_file"

    # Install skill.
    local skill_dir="$HOME/.claude/skills"
    mkdir -p "$skill_dir"
    cp "$INSTALL_DIR/skill/SKILL.md" "$skill_dir/goal.md"
    success "Installed /goal skill to $skill_dir/goal.md"

    # Inject CLAUDE.md fragment.
    # Look for project CLAUDE.md first, then create/append.
    local claude_md="CLAUDE.md"
    local fragment="$INSTALL_DIR/claude-md-fragment.md"
    local marker="<!-- goal-system -->"

    if [[ -f "$claude_md" ]]; then
        # Check if already injected.
        if ! grep -qF "$marker" "$claude_md" 2>/dev/null; then
            printf '\n%s\n' "$marker" >> "$claude_md"
            cat "$fragment" >> "$claude_md"
            printf '\n%s\n' "<!-- /goal-system -->" >> "$claude_md"
            success "Appended goal system docs to $claude_md"
        else
            success "Goal system docs already present in $claude_md (skipped)"
        fi
    else
        printf '%s\n' "$marker" > "$claude_md"
        cat "$fragment" >> "$claude_md"
        printf '\n%s\n' "<!-- /goal-system -->" >> "$claude_md"
        success "Created $claude_md with goal system docs"
    fi

    success "Claude Code configuration complete."
}

install_cursor() {
    info "Configuring Cursor..."

    local config_file=".cursor/mcp.json"
    ensure_json_file "$config_file"

    local server_path="$INSTALL_DIR/mcp-server/goal_server.py"

    local tmp
    tmp="$(mktemp)"
    jq --arg path "$server_path" \
        '.mcpServers = (.mcpServers // {}) | .mcpServers.goal = {"command": "python3", "args": [$path]}' \
        "$config_file" > "$tmp"
    mv -f "$tmp" "$config_file"

    success "Registered MCP server in $config_file"
    success "Cursor configuration complete."
}

install_opencode() {
    info "Configuring OpenCode..."

    # Prefer project-level opencode config, fall back to global.
    local config_file=""
    for candidate in "opencode.json" "opencode.jsonc" ".opencode.json" ".opencode.jsonc"; do
        if [[ -f "$candidate" ]]; then
            config_file="$candidate"
            break
        fi
    done
    if [[ -z "$config_file" ]] && [[ -f "$HOME/.config/opencode/opencode.json" ]]; then
        config_file="$HOME/.config/opencode/opencode.json"
    fi
    if [[ -z "$config_file" ]]; then
        # Create project-level config.
        config_file="opencode.json"
    fi
    ensure_json_file "$config_file"

    local server_path="$INSTALL_DIR/mcp-server/goal_server.py"

    # Read config (strip JSONC comments if needed), merge, write back.
    local tmp
    tmp="$(mktemp)"
    read_json_file "$config_file" | jq --arg path "$server_path" \
        '.mcp = (.mcp // {}) | .mcp.goal = {"type": "local", "command": ["python3", $path], "enabled": true}' \
        > "$tmp"
    mv -f "$tmp" "$config_file"

    success "Registered MCP server in $config_file"

    # Install skill to .agents/skills/goal/ (OpenCode reads this directory).
    local skill_dir=".agents/skills/goal"
    mkdir -p "$skill_dir"
    cp "$INSTALL_DIR/skill/SKILL.md" "$skill_dir/SKILL.md"
    success "Installed /goal skill to $skill_dir/SKILL.md"

    # Inject AGENTS.md fragment (OpenCode reads AGENTS.md like Claude Code reads CLAUDE.md).
    local agents_md="AGENTS.md"
    local fragment="$INSTALL_DIR/agents-md-fragment.md"
    local marker="<!-- goal-system -->"

    if [[ -f "$agents_md" ]]; then
        # Check if already injected.
        if ! grep -qF "$marker" "$agents_md" 2>/dev/null; then
            printf '\n%s\n' "$marker" >> "$agents_md"
            cat "$fragment" >> "$agents_md"
            printf '\n%s\n' "<!-- /goal-system -->" >> "$agents_md"
            success "Appended goal system docs to $agents_md"
        else
            success "Goal system docs already present in $agents_md (skipped)"
        fi
    else
        printf '%s\n' "$marker" > "$agents_md"
        cat "$fragment" >> "$agents_md"
        printf '\n%s\n' "<!-- /goal-system -->" >> "$agents_md"
        success "Created $agents_md with goal system docs"
    fi

    success "OpenCode configuration complete."
}

# ---------------------------------------------------------------------------
# Parse flags
# ---------------------------------------------------------------------------

parse_args() {
    while (( $# )); do
        case "$1" in
            --claude)   AGENTS+=("claude") ;;
            --cursor)   AGENTS+=("cursor") ;;
            --opencode) AGENTS+=("opencode") ;;
            --all)      AGENTS=("claude" "cursor" "opencode") ;;
            -h|--help)
                echo "Usage: ./install.sh [--claude] [--cursor] [--opencode] [--all]"
                echo ""
                echo "Install goal for one or more coding agents."
                echo ""
                echo "Flags:"
                echo "  --claude     Install for Claude Code (MCP + hooks + skill + CLAUDE.md)"
                echo "  --cursor     Install for Cursor (MCP only)"
                echo "  --opencode   Install for OpenCode (MCP + skill + AGENTS.md)"
                echo "  --all        Install for all supported agents"
                echo "  -h, --help   Show this help message"
                echo ""
                echo "With no flags, auto-detects installed agents and prompts."
                exit 0
                ;;
            *)
                error "Unknown flag: $1"
                error "Run ./install.sh --help for usage."
                exit 1
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo ""
    printf "${BOLD}goal${NC} — Persistent, multi-turn goal tracking with auto-continuation\n"
    echo ""

    parse_args "$@"

    # Check prerequisites first.
    check_prerequisites

    # If no agents specified, auto-detect or prompt.
    if (( ${#AGENTS[@]} == 0 )); then
        prompt_agent_selection
    fi

    # Install core files.
    install_core

    echo ""

    # Install per-agent configs.
    for agent in "${AGENTS[@]}"; do
        case "$agent" in
            claude)   install_claude ;;
            cursor)   install_cursor ;;
            opencode) install_opencode ;;
            *)        warn "Unknown agent: $agent (skipped)" ;;
        esac
        echo ""
    done

    # Summary.
    printf "${GREEN}${BOLD}Installation complete!${NC}\n"
    echo ""
    info "Installed agents: ${AGENTS[*]}"
    info "Core files: $INSTALL_DIR"
    echo ""

    for agent in "${AGENTS[@]}"; do
        case "$agent" in
            claude)
                info "Claude Code: restart Claude Code or run 'claude' to pick up changes."
                info "  Use /goal <objective> to set a goal."
                ;;
            cursor)
                info "Cursor: restart Cursor to pick up the MCP server."
                info "  Use the create_goal / get_goal / update_goal tools."
                ;;
            opencode)
                info "OpenCode: restart OpenCode to pick up the MCP server."
                info "  Use the create_goal / get_goal / update_goal tools, /goal skill, or AGENTS.md context."
                ;;
        esac
    done

    echo ""
    info "Note: Auto-continuation (hooks) is only available in Claude Code."
    info "Other editors get MCP tools (create_goal, get_goal, update_goal) only."
    echo ""
}

main "$@"
