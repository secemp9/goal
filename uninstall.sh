#!/usr/bin/env bash
# uninstall.sh — Remove goal from Claude Code, Cursor, and/or OpenCode.
#
# Usage:
#   ./uninstall.sh            — auto-detect or prompt
#   ./uninstall.sh --claude   — Claude Code only
#   ./uninstall.sh --cursor   — Cursor only
#   ./uninstall.sh --opencode — OpenCode only
#   ./uninstall.sh --all      — all agents + remove ~/.goal/

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

INSTALL_DIR="$HOME/.goal"

# Agents to uninstall from (populated by flag parsing).
declare -a AGENTS=()
REMOVE_CORE=0

# ---------------------------------------------------------------------------
# Colors / output helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${BLUE}[info]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[ok]${NC}   %s\n" "$*"; }
warn()    { printf "${YELLOW}[warn]${NC} %s\n" "$*"; }
error()   { printf "${RED}[err]${NC}  %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# JSON config helpers
# ---------------------------------------------------------------------------

# strip_jsonc — Strip comments from JSONC, preserving // inside quoted strings.
strip_jsonc() {
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

# remove_json_key — Remove a key from a JSON/JSONC file using jq.
# Usage: remove_json_key <file> <jq_delete_path>
remove_json_key() {
    local filepath="$1"
    local jq_path="$2"

    if [[ ! -f "$filepath" ]]; then
        return 1
    fi

    local tmp
    tmp="$(mktemp)"
    if read_json_file "$filepath" | jq "$jq_path" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$filepath"
        return 0
    else
        rm -f "$tmp"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Agent-specific uninstallers
# ---------------------------------------------------------------------------

uninstall_claude() {
    info "Removing Claude Code configuration..."

    local settings_file="$HOME/.claude/settings.json"
    if [[ -f "$settings_file" ]]; then
        # Remove MCP server entry.
        if jq -e '.mcpServers.goal' "$settings_file" &>/dev/null; then
            remove_json_key "$settings_file" 'del(.mcpServers.goal)'
            success "Removed MCP server from $settings_file"

            # Clean up empty mcpServers.
            if jq -e '.mcpServers == {}' "$settings_file" &>/dev/null; then
                remove_json_key "$settings_file" 'del(.mcpServers)'
            fi
        else
            info "No MCP server entry found in $settings_file (skipped)"
        fi

        # Remove hook entries from the matcher+hooks format:
        # {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "..."}]}]}
        local hook_path="$INSTALL_DIR/hooks"
        local tmp
        tmp="$(mktemp)"
        jq --arg hp "$hook_path" '
            # Remove goal hook commands from inside {matcher, hooks[]} entries.
            def remove_goal_hooks($prefix):
                if . == null then null
                elif type == "array" then
                    [.[] |
                        if .hooks and (.hooks | type) == "array" then
                            .hooks = [.hooks[] | select(.command | startswith($prefix) | not)]
                        else . end
                    ] | [.[] | select(.hooks | length > 0)]
                else .
                end;

            if .hooks then
                .hooks.Stop = (.hooks.Stop | remove_goal_hooks($hp))
                | .hooks.PostToolUse = (.hooks.PostToolUse | remove_goal_hooks($hp))
                | .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit | remove_goal_hooks($hp))
                | if (.hooks.Stop // [] | length) == 0 then del(.hooks.Stop) else . end
                | if (.hooks.PostToolUse // [] | length) == 0 then del(.hooks.PostToolUse) else . end
                | if (.hooks.UserPromptSubmit // [] | length) == 0 then del(.hooks.UserPromptSubmit) else . end
                | if (.hooks | keys | length) == 0 then del(.hooks) else . end
            else .
            end
        ' "$settings_file" > "$tmp" 2>/dev/null && mv -f "$tmp" "$settings_file"
        success "Removed hooks from $settings_file"
    else
        info "No settings file found at $settings_file (skipped)"
    fi

    # Remove skill. Claude Code expects skills/<name>/SKILL.md structure.
    local skill_dir="$HOME/.claude/skills/goal"
    if [[ -d "$skill_dir" ]]; then
        rm -rf "$skill_dir"
        success "Removed skill directory $skill_dir"
    elif [[ -f "$HOME/.claude/skills/goal.md" ]]; then
        # Legacy flat file cleanup.
        rm -f "$HOME/.claude/skills/goal.md"
        success "Removed legacy skill file"
    fi

    # Remove CLAUDE.md fragment.
    local claude_md="CLAUDE.md"
    if [[ -f "$claude_md" ]] && grep -qF "<!-- goal-system -->" "$claude_md" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        # Remove everything between the markers (inclusive).
        awk '
            /<!-- goal-system -->/ { skip=1; next }
            /<!-- \/goal-system -->/ { skip=0; next }
            !skip { print }
        ' "$claude_md" > "$tmp"
        # Remove trailing blank lines left behind.
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$claude_md"
        success "Removed goal system docs from $claude_md"
    fi

    success "Claude Code configuration removed."
}

uninstall_cursor() {
    info "Removing Cursor configuration..."

    local config_file=".cursor/mcp.json"
    if [[ -f "$config_file" ]]; then
        if jq -e '.mcpServers.goal' "$config_file" &>/dev/null; then
            remove_json_key "$config_file" 'del(.mcpServers.goal)'
            success "Removed MCP server from $config_file"

            # Clean up empty mcpServers.
            if jq -e '.mcpServers == {}' "$config_file" &>/dev/null; then
                remove_json_key "$config_file" 'del(.mcpServers)'
            fi
        else
            info "No MCP server entry found in $config_file (skipped)"
        fi
    else
        info "No config file found at $config_file (skipped)"
    fi

    success "Cursor configuration removed."
}

uninstall_opencode() {
    info "Removing OpenCode configuration..."

    # Check multiple possible locations.
    local config_file=""
    for candidate in "opencode.json" "opencode.jsonc" ".opencode.json" ".opencode.jsonc" "$HOME/.config/opencode/opencode.json"; do
        if [[ -f "$candidate" ]]; then
            config_file="$candidate"
            break
        fi
    done

    if [[ -n "$config_file" ]]; then
        # Use read_json_file to handle JSONC comment stripping for .jsonc files.
        if read_json_file "$config_file" | jq -e '.mcp.goal' &>/dev/null; then
            remove_json_key "$config_file" 'del(.mcp.goal)'
            success "Removed MCP server from $config_file"

            # Clean up empty mcp.
            if read_json_file "$config_file" | jq -e '.mcp == {}' &>/dev/null; then
                remove_json_key "$config_file" 'del(.mcp)'
            fi
        else
            info "No MCP server entry found in $config_file (skipped)"
        fi
    else
        info "No OpenCode config file found (skipped)"
    fi

    # Remove skill from .agents/skills/goal/.
    local skill_dir=".agents/skills/goal"
    if [[ -d "$skill_dir" ]]; then
        rm -rf "$skill_dir"
        success "Removed skill directory $skill_dir"
        # Clean up empty parent dirs.
        rmdir ".agents/skills" 2>/dev/null || true
        rmdir ".agents" 2>/dev/null || true
    fi

    # Remove AGENTS.md fragment.
    local agents_md="AGENTS.md"
    if [[ -f "$agents_md" ]] && grep -qF "<!-- goal-system -->" "$agents_md" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        # Remove everything between the markers (inclusive).
        awk '
            /<!-- goal-system -->/ { skip=1; next }
            /<!-- \/goal-system -->/ { skip=0; next }
            !skip { print }
        ' "$agents_md" > "$tmp"
        # Remove trailing blank lines left behind.
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp" 2>/dev/null || true
        mv -f "$tmp" "$agents_md"
        success "Removed goal system docs from $agents_md"
    fi

    success "OpenCode configuration removed."
}

# ---------------------------------------------------------------------------
# Remove core files
# ---------------------------------------------------------------------------

remove_core() {
    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        success "Removed $INSTALL_DIR"
    else
        info "No install directory found at $INSTALL_DIR (skipped)"
    fi
}

# ---------------------------------------------------------------------------
# Agent detection (for prompt)
# ---------------------------------------------------------------------------

detect_agents() {
    local detected=()
    if [[ -d "$HOME/.claude" ]] || [[ -d ".claude" ]]; then detected+=("claude"); fi
    if [[ -d "$HOME/.cursor" ]] || [[ -d ".cursor" ]]; then detected+=("cursor"); fi
    if [[ -f "opencode.json" ]] || [[ -f ".opencode.json" ]] || [[ -d "$HOME/.config/opencode" ]]; then detected+=("opencode"); fi

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
        warn "No agents detected. Removing core files only."
        REMOVE_CORE=1
        return
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
    printf "  %d) All + remove core files\n" "$i"

    printf "\nSelect agent(s) to uninstall from [1-%d]: " "$i"
    read -r choice

    if [[ "$choice" == "$i" ]]; then
        AGENTS=("${options[@]}")
        REMOVE_CORE=1
    elif (( choice >= 1 && choice < i )); then
        AGENTS=("${options[$((choice-1))]}")
    else
        error "Invalid selection."
        exit 1
    fi
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
            --all)      AGENTS=("claude" "cursor" "opencode"); REMOVE_CORE=1 ;;
            -h|--help)
                echo "Usage: ./uninstall.sh [--claude] [--cursor] [--opencode] [--all]"
                echo ""
                echo "Remove goal from one or more coding agents."
                echo ""
                echo "Flags:"
                echo "  --claude     Remove from Claude Code"
                echo "  --cursor     Remove from Cursor"
                echo "  --opencode   Remove from OpenCode"
                echo "  --all        Remove from all agents + delete ~/.goal/"
                echo "  -h, --help   Show this help message"
                exit 0
                ;;
            *)
                error "Unknown flag: $1"
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
    printf "${BOLD}goal${NC} — Uninstaller\n"
    echo ""

    parse_args "$@"

    # If no agents specified, prompt.
    if (( ${#AGENTS[@]} == 0 && REMOVE_CORE == 0 )); then
        prompt_agent_selection
    fi

    # Uninstall per-agent configs.
    for agent in "${AGENTS[@]}"; do
        case "$agent" in
            claude)   uninstall_claude ;;
            cursor)   uninstall_cursor ;;
            opencode) uninstall_opencode ;;
            *)        warn "Unknown agent: $agent (skipped)" ;;
        esac
        echo ""
    done

    # Remove core files if requested.
    if (( REMOVE_CORE )); then
        remove_core
        echo ""
    fi

    printf "${GREEN}${BOLD}Uninstallation complete.${NC}\n"
    echo ""
}

main "$@"
