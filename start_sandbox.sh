#!/usr/bin/env bash
# start_sandbox.sh — interactive launcher for claude-sandbox instances.
#
# Flow:
#   1. fzf area picker — preview shows workdir, current flag state, last
#      session, running status.
#   2. Refuses if the area is already running.
#   3. Toggle loop — flip Headroom / Vertex / FISS-writes via fzf. Selections
#      persist back to env.<INSTANCE>.sh inside a managed block.
#   4. fzf session picker — NEW + recent sessions (mtime-sorted).
#   5. Sources the (now possibly patched) env file and execs
#      ./run_claude_docker.sh --dangerously-skip-permissions [--resume <uuid>].
#
# Managed block convention: env.<INSTANCE>.sh may contain a block bracketed by
# the markers below. start_sandbox.sh regenerates that block from current
# toggle state; everything outside the markers is preserved verbatim.
#
#   # vvv start_sandbox managed block — regenerated, do not edit vvv
#   ...
#   # ^^^ start_sandbox managed block ^^^

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=sandbox_lib.sh
source "$SCRIPT_DIR/sandbox_lib.sh"

MARK_BEGIN="# vvv start_sandbox managed block — regenerated, do not edit vvv"
MARK_END="# ^^^ start_sandbox managed block ^^^"

command -v fzf >/dev/null 2>&1 || {
    echo "fzf is required. Install: sudo apt-get install -y fzf" >&2
    exit 1
}
command -v docker >/dev/null 2>&1 || {
    echo "docker is required." >&2
    exit 1
}

# --- area discovery ----------------------------------------------------------

shopt -s nullglob
ENV_FILES=("$SCRIPT_DIR"/env.*.sh)
shopt -u nullglob

declare -a AREAS=()
for f in "${ENV_FILES[@]}"; do
    base="$(basename "$f" .sh)"
    name="${base#env.}"
    # Skip env.sh (no instance) and env.example.sh (the template).
    [[ "$name" == "example" || -z "$name" || "$base" == "env" ]] && continue
    AREAS+=("$name")
done

[[ ${#AREAS[@]} -gt 0 ]] || {
    echo "No env.<NAME>.sh files found in ${SCRIPT_DIR}." >&2
    echo "Copy env.example.sh to env.<NAME>.sh first." >&2
    exit 1
}

# --- preview generator for the area picker -----------------------------------
#
# fzf calls a child shell per highlighted row. Keep this fast and self-contained
# — re-source sandbox_lib so the child has the helpers.
preview_area() {
    local area=$1
    local envfile="$SCRIPT_DIR/env.${area}.sh"
    local state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}"

    local flags projects_dir hr fw vx
    flags=$(sb_read_env_flags "$envfile")
    IFS='|' read -r projects_dir hr fw vx <<<"$flags"

    echo "Area:        ${area}"
    echo "Env file:    env.${area}.sh"
    echo "Workdir:     ${projects_dir:-(not set)}"
    echo "State dir:   ${state_dir}"
    echo

    echo "Flags (from env file):"
    printf "  [%s] Headroom        (HEADROOM=1)\n"            "$([ "$hr" = 1 ] && echo '✓' || echo ' ')"
    printf "  [%s] Vertex AI       (CLAUDE_CODE_USE_VERTEX=1)\n" "$([ "$vx" = 1 ] && echo '✓' || echo ' ')"
    printf "  [%s] FISS write mode (FISS_MCP_ALLOW_WRITES=1)\n" "$([ "$fw" = 1 ] && echo '✓' || echo ' ')"
    echo

    local cid
    cid=$(sb_running_cid "$area")
    if [ -n "$cid" ]; then
        echo "Status:      RUNNING (container ${cid:0:12})"
    else
        echo "Status:      not running"
    fi

    local latest
    latest=$(sb_latest_session_file "$state_dir/.claude/projects")
    if [ -n "$latest" ]; then
        local mt now age desc
        mt=$(sb_mtime_of "$latest")
        now=$(date +%s)
        age=$(sb_fmt_age $((now - mt)))
        desc=$(sb_session_description "$latest" || true)
        echo "Last session: ${age}"
        [ -n "$desc" ] && echo "Summary:     ${desc}"
    else
        echo "Last session: (none)"
    fi
}
export -f preview_area
export SCRIPT_DIR
# fzf's preview command needs the helpers available in its child shell. Easiest:
# re-source sandbox_lib at preview time via an exported wrapper.
preview_area_wrapped() {
    # shellcheck source=sandbox_lib.sh
    source "$SCRIPT_DIR/sandbox_lib.sh"
    preview_area "$1"
}
export -f preview_area_wrapped sb_mtime_of sb_fmt_age sb_session_description \
          sb_read_env_flags sb_latest_session_file sb_list_sessions sb_running_cid

# --- step 1: area picker -----------------------------------------------------

CHOSEN_AREA=$(printf '%s\n' "${AREAS[@]}" | \
    fzf \
        --prompt='Sandbox area> ' \
        --header='↑/↓ to navigate, ENTER to select, ESC to cancel' \
        --preview='preview_area_wrapped {}' \
        --preview-window='right,60%,wrap' \
        --height=80% --border --layout=reverse \
    || true)

[[ -z "$CHOSEN_AREA" ]] && { echo "Cancelled."; exit 0; }

# --- block if already running ------------------------------------------------

RUNNING_CID=$(sb_running_cid "$CHOSEN_AREA")
if [ -n "$RUNNING_CID" ]; then
    echo "ERROR: sandbox '${CHOSEN_AREA}' is already running (container ${RUNNING_CID:0:12})." >&2
    echo "       Use 'docker exec -it claude-sandbox-${CHOSEN_AREA} bash' to attach," >&2
    echo "       or stop it first with 'docker stop claude-sandbox-${CHOSEN_AREA}'." >&2
    exit 1
fi

# --- step 2: toggle loop -----------------------------------------------------

ENV_FILE="$SCRIPT_DIR/env.${CHOSEN_AREA}.sh"
FLAGS_LINE=$(sb_read_env_flags "$ENV_FILE")
IFS='|' read -r INITIAL_PROJECTS_DIR INITIAL_HR INITIAL_FW INITIAL_VX <<<"$FLAGS_LINE"

HR=$INITIAL_HR
VX=$INITIAL_VX
FW=$INITIAL_FW

render_toggle_menu() {
    printf '%s\n' \
        "[$([ "$HR" = 1 ] && echo 'X' || echo ' ')] Headroom (token compression)" \
        "[$([ "$VX" = 1 ] && echo 'X' || echo ' ')] Vertex AI (paid GCP project)" \
        "[$([ "$FW" = 1 ] && echo 'X' || echo ' ')] FISS-MCP write mode" \
        "─── Launch ───"
}

while true; do
    HEADER="[${CHOSEN_AREA}] Toggle flags. Pick a row to flip, or '── Launch ──' to continue."
    PICK=$(render_toggle_menu | \
        fzf \
            --prompt='Flag> ' \
            --header="$HEADER" \
            --no-multi --height=40% --border --layout=reverse \
        || echo '__CANCEL__')

    case "$PICK" in
        '__CANCEL__'|'')
            echo "Cancelled."; exit 0 ;;
        *Headroom*)         HR=$((1 - HR)) ;;
        *'Vertex AI'*)      VX=$((1 - VX)) ;;
        *'FISS-MCP'*)       FW=$((1 - FW)) ;;
        *'Launch'*)         break ;;
    esac
done

# --- persist toggles via managed block (only if changed) ---------------------

if [[ "$HR" != "$INITIAL_HR" || "$VX" != "$INITIAL_VX" || "$FW" != "$INITIAL_FW" ]]; then
    # Build the new managed block.
    NEW_BLOCK=$(
        echo "$MARK_BEGIN"
        echo "# Managed by start_sandbox.sh — toggle via the menu, not by hand."
        if [ "$HR" = 1 ]; then echo "export HEADROOM=1"; else echo "export HEADROOM=0"; fi
        echo "export FISS_MCP=1"
        if [ "$FW" = 1 ]; then echo "export FISS_MCP_ALLOW_WRITES=1"; else echo "export FISS_MCP_ALLOW_WRITES=0"; fi
        if [ "$VX" = 1 ]; then
            printf 'source "%s/SET_VERTEX_MODE.sh"\n' "$SCRIPT_DIR"
        else
            echo "unset CLAUDE_CODE_USE_VERTEX ANTHROPIC_VERTEX_PROJECT_ID CLOUD_ML_REGION"
        fi
        echo "$MARK_END"
    )

    # Strip any existing managed block, then append the new one.
    TMP="$(mktemp)"
    awk -v B="$MARK_BEGIN" -v E="$MARK_END" '
        $0 == B { skip = 1; next }
        $0 == E { skip = 0; next }
        !skip
    ' "$ENV_FILE" > "$TMP"

    # Drop trailing blank lines so the block always sits flush at EOF.
    awk 'BEGIN{n=0} { lines[NR]=$0; if($0!="") last=NR } END{ for(i=1;i<=last;i++) print lines[i] }' \
        "$TMP" > "${TMP}.2"
    mv "${TMP}.2" "$TMP"

    {
        cat "$TMP"
        echo
        echo "$NEW_BLOCK"
    } > "$ENV_FILE"
    rm -f "$TMP"

    echo "Updated env.${CHOSEN_AREA}.sh managed block:"
    printf '  Headroom=%s  Vertex=%s  FISS_writes=%s\n' "$HR" "$VX" "$FW"
fi

# --- step 3: session picker --------------------------------------------------

STATE_DIR="$SCRIPT_DIR/claude-sandbox-persistent-state-${CHOSEN_AREA}/.claude/projects"

# Build session list: "NEW" + up to 30 newest jsonl files. Fixed-width columns
# so fzf rows align without depending on bsdmainutils `column`.
#   UUID (36)  AGE (10)  SUMMARY
SESSION_LINES=()
printf -v new_row '%-36s  %-10s  %s' "NEW" "" "Start a fresh session"
SESSION_LINES+=("$new_row")
if [ -d "$STATE_DIR" ]; then
    NOW=$(date +%s)
    while IFS=$'\t' read -r mt f; do
        uuid=$(basename "$f" .jsonl)
        age=$(sb_fmt_age $((NOW - mt)))
        desc=$(sb_session_description "$f" || true)
        [ -z "$desc" ] && desc='(no summary)'
        printf -v row '%-36s  %-10s  %s' "$uuid" "$age" "$desc"
        SESSION_LINES+=("$row")
    done < <(sb_list_sessions "$STATE_DIR" | sort -rn | head -30)
fi

CHOSEN_SESSION_LINE=$(printf '%s\n' "${SESSION_LINES[@]}" | \
    fzf \
        --prompt="[${CHOSEN_AREA}] Session> " \
        --header='Pick NEW or an existing session UUID to resume.' \
        --height=60% --border --layout=reverse \
    || true)

[[ -z "$CHOSEN_SESSION_LINE" ]] && { echo "Cancelled."; exit 0; }

# First whitespace-delimited token is either "NEW" or the session UUID.
CHOSEN_SESSION=$(awk '{print $1}' <<<"$CHOSEN_SESSION_LINE")

# --- step 4: source env, exec launcher ---------------------------------------

# shellcheck source=/dev/null
source "$ENV_FILE"

LAUNCH_ARGS=(--dangerously-skip-permissions)
if [ "$CHOSEN_SESSION" != "NEW" ]; then
    LAUNCH_ARGS+=(--resume "$CHOSEN_SESSION")
fi

echo
echo "Launching sandbox '${CHOSEN_AREA}'..."
echo "  Workdir: ${CLAUDE_SANDBOX_PROJECTS_DIR:-?}"
echo "  Args:    ${LAUNCH_ARGS[*]}"
echo

exec "$SCRIPT_DIR/run_claude_docker.sh" "${LAUNCH_ARGS[@]}"
