#!/usr/bin/env bash
# start_sandbox.sh — interactive launcher for claude-sandbox instances.
#
# Flow:
#   1. fzf area picker — ASCII-table rows, side preview panel with workdir,
#      flag state, last session, running status.
#   2. Refuses if the chosen area is already running.
#   3. Toggle loop — flip Headroom / Vertex / FISS-writes. Selections persist
#      back to env.<INSTANCE>.sh inside a managed block (idempotent).
#   4. fzf session picker — NEW + recent sessions (mtime-sorted). Each row
#      shows the session's custom title (claude --name), short UUID, age,
#      and summary.
#   5. Sources the (possibly patched) env file and execs
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

# --- styling -----------------------------------------------------------------
#
# Claude-CLI-ish amber palette + rounded borders. fzf does full-row highlight
# by default (bg+); we just lean into it with a contrasting selected bg and an
# arrow pointer. ANSI hex colors work in any 24-bit terminal; older terms get
# the closest 256-color fallback automatically.

# Common fzf flags shared by every picker so they look like a set.
FZF_THEME=(
    --border=rounded
    --pointer='▶'
    --marker='✓'
    --info=inline-right
    --layout=reverse
    --no-mouse
    --cycle
    --color='border:#d97757,header:#d97757,prompt:#d97757,pointer:#d97757,marker:#d97757,info:#7f7f7f,fg:#cdd6f4,fg+:#ffffff:bold,bg+:#3a3a3a,hl:#d97757,hl+:#ffd49a,spinner:#d97757,label:#d97757'
)

# Column widths (so the area-picker rows align as a real ASCII table).
W_AREA=10
W_WORKDIR=32
W_FLAGS=7
W_AGE=10
W_NAME=24

# Truncate a string with a leading ellipsis if it overflows the target width.
# Right-aligned tail makes the suffix (the meaningful basename of a workdir)
# always visible — opposite of the default left-truncate.
trim_left() {
    local s=$1 w=$2
    if (( ${#s} > w )); then
        printf '…%s' "${s: -$((w-1))}"
    else
        printf '%s' "$s"
    fi
}

# Truncate from the right when the head is the interesting part (summaries).
trim_right() {
    local s=$1 w=$2
    if (( ${#s} > w )); then
        printf '%s…' "${s:0:w-1}"
    else
        printf '%s' "$s"
    fi
}

# Compact flag badge: uppercase letter = on, lowercase = off. e.g. "[Hvf]".
flag_badge() {
    local hr=$1 vx=$2 fw=$3
    local h v f
    [ "$hr" = 1 ] && h='H' || h='h'
    [ "$vx" = 1 ] && v='V' || v='v'
    [ "$fw" = 1 ] && f='F' || f='f'
    printf '[%s%s%s]' "$h" "$v" "$f"
}

# Render a horizontal rule of n cells using a given char (e.g. '─').
hrule() { local w=$1 ch=${2:-─}; printf '%*s' "$w" '' | tr ' ' "$ch"; }

# --- area discovery ----------------------------------------------------------

shopt -s nullglob
ENV_FILES=("$SCRIPT_DIR"/env.*.sh)
shopt -u nullglob

declare -a AREAS=()
for f in "${ENV_FILES[@]}"; do
    base="$(basename "$f" .sh)"
    name="${base#env.}"
    [[ "$name" == "example" || -z "$name" || "$base" == "env" ]] && continue
    AREAS+=("$name")
done

[[ ${#AREAS[@]} -gt 0 ]] || {
    echo "No env.<NAME>.sh files found in ${SCRIPT_DIR}." >&2
    echo "Copy env.example.sh to env.<NAME>.sh first." >&2
    exit 1
}

# --- area table rows ---------------------------------------------------------
#
# Build a real ASCII table. First three rows = header line + separator. Then
# one row per area. fzf treats the first three as a frozen header so the
# user only navigates data rows.

area_row() {
    local area=$1 workdir=$2 flags=$3 age=$4 name=$5
    printf '│ %-*s │ %-*s │ %-*s │ %-*s │ %-*s │\n' \
        "$W_AREA"    "$(trim_right "$area"    "$W_AREA")" \
        "$W_WORKDIR" "$(trim_left  "$workdir" "$W_WORKDIR")" \
        "$W_FLAGS"   "$flags" \
        "$W_AGE"     "$age" \
        "$W_NAME"    "$(trim_right "$name" "$W_NAME")"
}

area_header_top()   { printf '╭─%s─┬─%s─┬─%s─┬─%s─┬─%s─╮\n' "$(hrule $W_AREA)" "$(hrule $W_WORKDIR)" "$(hrule $W_FLAGS)" "$(hrule $W_AGE)" "$(hrule $W_NAME)"; }
area_header_sep()   { printf '├─%s─┼─%s─┼─%s─┼─%s─┼─%s─┤\n' "$(hrule $W_AREA)" "$(hrule $W_WORKDIR)" "$(hrule $W_FLAGS)" "$(hrule $W_AGE)" "$(hrule $W_NAME)"; }
area_header_labels(){ area_row "AREA" "WORKDIR" "FLAGS" "LAST" "SESSION NAME"; }

# Build the array of pretty rows + a parallel array of the bare area names
# (for parsing the fzf selection later).
AREA_ROWS=()
AREA_INDEX=()
for area in "${AREAS[@]}"; do
    envfile="$SCRIPT_DIR/env.${area}.sh"
    state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}"
    flags=$(sb_read_env_flags "$envfile")
    IFS='|' read -r projects_dir hr fw vx <<<"$flags"

    badge=$(flag_badge "$hr" "$vx" "$fw")

    latest=$(sb_latest_session_file "$state_dir/.claude/projects")
    if [ -n "$latest" ]; then
        mt=$(sb_mtime_of "$latest")
        age=$(sb_fmt_age $(($(date +%s) - mt)))
        sname=$(sb_session_name "$latest")
        if [ -z "$sname" ]; then
            sname=$(sb_session_description "$latest" || true)
            [ -z "$sname" ] && sname='(unnamed)'
        fi
    else
        age='(none)'
        sname='—'
    fi

    cid=$(sb_running_cid "$area")
    [ -n "$cid" ] && area_label="${area} *" || area_label="$area"

    AREA_ROWS+=("$(area_row "$area_label" "${projects_dir:-?}" "$badge" "$age" "$sname")")
    AREA_INDEX+=("$area")
done

# --- area preview ------------------------------------------------------------
#
# Side panel shown for the highlighted row. Box-drawn sections for sandbox
# identity, flags, and last session. Re-sources sandbox_lib because fzf invokes
# this in a fresh child shell.
preview_area() {
    local area=$1
    local envfile="$SCRIPT_DIR/env.${area}.sh"
    local state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}"

    local flags projects_dir hr fw vx
    flags=$(sb_read_env_flags "$envfile")
    IFS='|' read -r projects_dir hr fw vx <<<"$flags"

    local cid status
    cid=$(sb_running_cid "$area")
    if [ -n "$cid" ]; then
        status="RUNNING (container ${cid:0:12})"
    else
        status="not running"
    fi

    printf '╭─ Sandbox %s\n' "$area"
    printf '│  Env file   env.%s.sh\n' "$area"
    printf '│  Workdir    %s\n' "${projects_dir:-?}"
    printf '│  State dir  %s\n' "$state_dir"
    printf '│  Status     %s\n' "$status"
    printf '╰─\n\n'

    printf '╭─ Flags (from env file)\n'
    printf '│  [%s] Headroom         token compression\n' \
        "$([ "$hr" = 1 ] && echo '✓' || echo ' ')"
    printf '│  [%s] Vertex AI        paid GCP project\n' \
        "$([ "$vx" = 1 ] && echo '✓' || echo ' ')"
    printf '│  [%s] FISS-MCP writes  agent can mutate Terra state\n' \
        "$([ "$fw" = 1 ] && echo '✓' || echo ' ')"
    printf '╰─\n\n'

    local latest
    latest=$(sb_latest_session_file "$state_dir/.claude/projects")
    printf '╭─ Last session\n'
    if [ -n "$latest" ]; then
        local mt age uuid sname desc
        mt=$(sb_mtime_of "$latest")
        age=$(sb_fmt_age $(($(date +%s) - mt)))
        uuid=$(basename "$latest" .jsonl)
        sname=$(sb_session_name "$latest")
        desc=$(sb_session_description "$latest" || true)
        printf '│  Name     %s\n' "${sname:-(unnamed)}"
        printf '│  UUID     %s\n' "${uuid:0:8}"
        printf '│  Updated  %s\n' "$age"
        [ -n "$desc" ] && printf '│  Summary  %s\n' "$desc"
    else
        printf '│  (no sessions yet)\n'
    fi
    printf '╰─\n'
}
export -f preview_area
export SCRIPT_DIR
preview_area_wrapped() {
    # shellcheck source=sandbox_lib.sh
    source "$SCRIPT_DIR/sandbox_lib.sh"
    preview_area "$1"
}
export -f preview_area_wrapped sb_mtime_of sb_fmt_age sb_session_description \
          sb_session_name sb_read_env_flags sb_latest_session_file \
          sb_list_sessions sb_running_cid

# --- step 1: area picker -----------------------------------------------------
#
# Header lines: top border / column titles / separator. --header-lines=3 keeps
# them pinned and skips them during navigation.

# fzf preview command needs the area NAME, not the whole table row. Extract
# the second column (after "│ ") — strip surrounding whitespace.
PREVIEW_CMD='area=$(printf "%s" {} | sed -E "s/^│ +([^ │]+).*/\1/; s/ \*$//"); preview_area_wrapped "$area"'

CHOSEN_ROW=$(
    {
        area_header_top
        area_header_labels
        area_header_sep
        printf '%s\n' "${AREA_ROWS[@]}"
    } | fzf \
        --prompt='  Sandbox  ' \
        --header='claude-sandbox launcher · ↑/↓ navigate · ENTER select · ESC quit · "*" = running' \
        --header-lines=3 \
        --preview="$PREVIEW_CMD" \
        --preview-window='right,55%,wrap,border-rounded' \
        --height=90% \
        "${FZF_THEME[@]}" \
    || true
)

[[ -z "$CHOSEN_ROW" ]] && { echo "Cancelled."; exit 0; }

# Parse the area name out of "│ B       │ …" — second column after the leading "│".
CHOSEN_AREA=$(printf '%s' "$CHOSEN_ROW" | sed -E 's/^│ +([^ │]+).*/\1/; s/ \*$//')

# Sanity check: make sure the parsed name is in AREA_INDEX.
found=0
for a in "${AREA_INDEX[@]}"; do
    [ "$a" = "$CHOSEN_AREA" ] && { found=1; break; }
done
[ "$found" = 1 ] || { echo "ERROR: could not parse area name from row '$CHOSEN_ROW'." >&2; exit 1; }

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

TW=58   # toggle table width

toggle_top()  { printf '╭─%s─╮\n' "$(hrule $TW)"; }
toggle_sep()  { printf '├─%s─┤\n' "$(hrule $TW)"; }
toggle_bot()  { printf '╰─%s─╯\n' "$(hrule $TW)"; }
toggle_row()  {
    local on=$1 short=$2 label=$3 hint=$4
    local box
    [ "$on" = 1 ] && box='[✓]' || box='[ ]'
    printf '│ %s %-1s %-16s %-*s │\n' "$box" "$short" "$label" $((TW - 26)) "$hint"
}

render_toggle_menu() {
    toggle_top
    printf '│ %-*s │\n' "$TW" "Flags for sandbox '${CHOSEN_AREA}'"
    toggle_sep
    toggle_row "$HR" "H" "Headroom"        "token compression proxy"
    toggle_row "$VX" "V" "Vertex AI"       "route via host GCP project (paid)"
    toggle_row "$FW" "F" "FISS-MCP writes" "agent can mutate Terra state"
    toggle_sep
    printf '│ %-*s │\n' "$TW" "▶  Launch sandbox"
    toggle_bot
}

# Build a list of selectable labels parallel to render_toggle_menu (only the
# rows that the user can act on — toggles + Launch). The decorative box lines
# are pinned as header.
while true; do
    PICK=$(
        {
            render_toggle_menu | head -3   # top border + title + separator
            toggle_row "$HR" "H" "Headroom"        "token compression proxy"
            toggle_row "$VX" "V" "Vertex AI"       "route via host GCP project (paid)"
            toggle_row "$FW" "F" "FISS-MCP writes" "agent can mutate Terra state"
            toggle_sep
            printf '│ %-*s │\n' "$TW" "▶  Launch sandbox"
            toggle_bot
        } | fzf \
            --prompt='  Toggle  ' \
            --header="claude-sandbox · ${CHOSEN_AREA} · ENTER to flip / launch · ESC to cancel" \
            --header-lines=3 \
            --no-multi \
            --height=50% \
            "${FZF_THEME[@]}" \
        || echo '__CANCEL__'
    )

    case "$PICK" in
        '__CANCEL__'|'')                    echo "Cancelled."; exit 0 ;;
        *Headroom*)                         HR=$((1 - HR)) ;;
        *'Vertex AI'*)                      VX=$((1 - VX)) ;;
        *'FISS-MCP writes'*)                FW=$((1 - FW)) ;;
        *'Launch sandbox'*)                 break ;;
        *)                                  : ;;   # decorative line, ignore
    esac
done

# --- persist toggles via managed block (only if changed) ---------------------

if [[ "$HR" != "$INITIAL_HR" || "$VX" != "$INITIAL_VX" || "$FW" != "$INITIAL_FW" ]]; then
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

    TMP="$(mktemp)"
    awk -v B="$MARK_BEGIN" -v E="$MARK_END" '
        $0 == B { skip = 1; next }
        $0 == E { skip = 0; next }
        !skip
    ' "$ENV_FILE" > "$TMP"

    awk 'BEGIN{n=0} { lines[NR]=$0; if($0!="") last=NR } END{ for(i=1;i<=last;i++) print lines[i] }' \
        "$TMP" > "${TMP}.2"
    mv "${TMP}.2" "$TMP"

    {
        cat "$TMP"
        echo
        echo "$NEW_BLOCK"
    } > "$ENV_FILE"
    rm -f "$TMP"

    echo "Updated env.${CHOSEN_AREA}.sh: Headroom=$HR Vertex=$VX FISS_writes=$FW"
fi

# --- step 3: session picker --------------------------------------------------

STATE_DIR="$SCRIPT_DIR/claude-sandbox-persistent-state-${CHOSEN_AREA}/.claude/projects"

# Column widths.
SW_NAME=22
SW_UUID=8
SW_AGE=10
SW_SUMMARY=44

session_row() {
    local name=$1 uuid=$2 age=$3 summary=$4
    printf '│ %-*s │ %-*s │ %-*s │ %-*s │\n' \
        "$SW_NAME"    "$(trim_right "$name"    "$SW_NAME")" \
        "$SW_UUID"    "${uuid:0:SW_UUID}" \
        "$SW_AGE"     "$age" \
        "$SW_SUMMARY" "$(trim_right "$summary" "$SW_SUMMARY")"
}
session_header_top()   { printf '╭─%s─┬─%s─┬─%s─┬─%s─╮\n' "$(hrule $SW_NAME)" "$(hrule $SW_UUID)" "$(hrule $SW_AGE)" "$(hrule $SW_SUMMARY)"; }
session_header_sep()   { printf '├─%s─┼─%s─┼─%s─┼─%s─┤\n' "$(hrule $SW_NAME)" "$(hrule $SW_UUID)" "$(hrule $SW_AGE)" "$(hrule $SW_SUMMARY)"; }
session_header_labels(){ session_row "NAME" "UUID" "LAST" "SUMMARY"; }

# Parallel arrays: pretty row + full session uuid (or sentinel "NEW").
SESSION_ROWS=()
SESSION_UUIDS=()

SESSION_ROWS+=("$(session_row "▶ NEW SESSION" "" "" "Start a fresh conversation")")
SESSION_UUIDS+=("NEW")

if [ -d "$STATE_DIR" ]; then
    NOW=$(date +%s)
    while IFS=$'\t' read -r mt f; do
        uuid=$(basename "$f" .jsonl)
        age=$(sb_fmt_age $((NOW - mt)))
        name=$(sb_session_name "$f")
        desc=$(sb_session_description "$f" || true)
        [ -z "$desc" ] && desc='(no summary)'
        [ -z "$name" ] && name='(unnamed)'
        SESSION_ROWS+=("$(session_row "$name" "$uuid" "$age" "$desc")")
        SESSION_UUIDS+=("$uuid")
    done < <(sb_list_sessions "$STATE_DIR" | sort -rn | head -30)
fi

# fzf with header lines pinned. Map back to the chosen UUID by row index — we
# get fzf to emit "{n} <row>" via --with-nth and parse the index. But easier:
# print rows prefixed with their array index, hide the index column via
# --with-nth, then take it back via --bind on enter? Simpler still: re-walk
# the array by matching the full row string.

CHOSEN_ROW=$(
    {
        session_header_top
        session_header_labels
        session_header_sep
        printf '%s\n' "${SESSION_ROWS[@]}"
    } | fzf \
        --prompt='  Session  ' \
        --header="claude-sandbox · ${CHOSEN_AREA} · pick NEW or a session to resume · ESC to cancel" \
        --header-lines=3 \
        --height=80% \
        "${FZF_THEME[@]}" \
    || true
)

[[ -z "$CHOSEN_ROW" ]] && { echo "Cancelled."; exit 0; }

# Resolve the row back to its UUID by scanning the parallel arrays.
CHOSEN_SESSION=""
for i in "${!SESSION_ROWS[@]}"; do
    if [ "${SESSION_ROWS[$i]}" = "$CHOSEN_ROW" ]; then
        CHOSEN_SESSION="${SESSION_UUIDS[$i]}"
        break
    fi
done
[ -n "$CHOSEN_SESSION" ] || { echo "ERROR: could not resolve session UUID from row." >&2; exit 1; }

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
