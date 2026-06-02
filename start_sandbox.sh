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

# Preview pane content is precomputed into one file per area (see
# build_area_rows). Without this cache, every cursor move would re-spawn
# `docker ps` + two python3 invocations per highlight — ~150–300ms of lag
# that makes the picker feel sluggish.
PREVIEW_CACHE_DIR="$(mktemp -d -t claude-sandbox-preview.XXXXXX)"
export PREVIEW_CACHE_DIR
trap 'rm -rf "$PREVIEW_CACHE_DIR"' EXIT

# --- fzf wrapper that distinguishes Enter / ESC / Ctrl-C --------------------
#
# Echoes the selected row to stdout. Return codes:
#   0   Enter pressed → stdout has row
#   10  ESC pressed   → caller goes back one menu level
#   130 Ctrl-C        → caller quits entirely
#
# Trick: `--expect=esc` keeps ESC from aborting fzf; fzf instead prints the
# key name as the first stdout line ("" for Enter, "esc" for ESC), then the
# selected row on line 2. Ctrl-C still aborts → exit 130 → distinguishable.
fzf_pick() {
    local out rc=0 key sel
    out=$(fzf --expect=esc "$@") || rc=$?
    if [ $rc -ne 0 ]; then
        return 130   # ctrl-c or other abort
    fi
    key=$(printf '%s\n' "$out" | sed -n '1p')
    sel=$(printf '%s\n' "$out" | sed -n '2p')
    if [ "$key" = "esc" ]; then
        return 10
    fi
    printf '%s\n' "$sel"
    return 0
}

# --- styling -----------------------------------------------------------------
#
# Claude-CLI-ish amber palette + rounded borders. fzf does full-row highlight
# by default (bg+); we just lean into it with a contrasting selected bg and an
# arrow pointer. ANSI hex colors work in any 24-bit terminal; older terms get
# the closest 256-color fallback automatically.

# Common fzf flags shared by every picker so they look like a set.
#
# Palette uses xterm-256 indices, no style modifiers, and one
# attribute per --color flag. Hex colors (#rrggbb) require fzf 0.32+;
# `:bold` / `:italic` modifiers require fzf 0.31+. When fzf rejects any
# token in a bundled `--color=a:x,b:y` string it silently falls back to
# its defaults — which is why earlier attempts produced a blue header
# and a grey selection bar. Splitting one attribute per flag means at
# most one entry gets dropped on older fzf instead of the whole theme.
#
# Selection contrast: bg+ uses bright orange (208) with near-black fg+
# (232) — the current row should be unmissable, not merely bold.
FZF_THEME=(
    --border=rounded
    --pointer='▶'
    --marker='✓'
    --info=inline-right
    --layout=reverse
    --no-mouse
    --cycle
    --color=border:214
    --color=label:214
    --color=header:215
    --color=prompt:214
    --color=query:230
    --color=pointer:232
    --color=marker:232
    --color=info:240
    --color=spinner:214
    --color=fg:230
    --color=fg+:232
    --color=bg+:208
    --color=hl:215
    --color=hl+:88
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

# Build AREA_ROWS / AREA_INDEX from the on-disk env state, and populate
# $PREVIEW_CACHE_DIR/<area>.txt so the fzf preview command can just `cat`.
# Re-runnable so the area picker sees fresh badges + ages every time we go
# back to it.
#
# Performance notes (kept rough but the win is real):
#   - One docker call total via sb_running_areas, not N (was the dominant cost).
#   - One python3 fork per area via sb_session_meta, not two.
#   - Preview content is rendered INLINE from the locals we already gathered,
#     not by re-calling preview_area() which would re-fork docker+python.
AREA_ROWS=()
AREA_INDEX=()
build_area_rows() {
    AREA_ROWS=()
    AREA_INDEX=()

    # Batched running-area lookup. Format as a space-padded string so the
    # membership test below is a single substring match, no inner loop.
    local running_set
    running_set=" $(sb_running_areas | tr '\n' ' ') "

    local area envfile state_dir flags projects_dir hr fw vx badge
    local latest mt age sname desc uuid area_label status now
    now=$(date +%s)
    for area in "${AREAS[@]}"; do
        envfile="$SCRIPT_DIR/env.${area}.sh"
        state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}"
        flags=$(sb_read_env_flags "$envfile")
        IFS='|' read -r projects_dir hr fw vx <<<"$flags"

        badge=$(flag_badge "$hr" "$vx" "$fw")

        latest=$(sb_latest_session_file "$state_dir/.claude/projects")
        sname=""; desc=""; uuid=""; age='(none)'
        if [ -n "$latest" ]; then
            mt=$(sb_mtime_of "$latest")
            age=$(sb_fmt_age $((now - mt)))
            uuid=$(basename "$latest" .jsonl)
            IFS=$'\t' read -r sname desc <<<"$(sb_session_meta "$latest")"
            [ -z "$sname" ] && sname=${desc:-'(unnamed)'}
        fi

        if [[ "$running_set" == *" $area "* ]]; then
            area_label="${area} *"
            status="RUNNING"
        else
            area_label="$area"
            status="not running"
        fi

        AREA_ROWS+=("$(area_row "$area_label" "${projects_dir:-?}" "$badge" "$age" "${sname:-—}")")
        AREA_INDEX+=("$area")

        # Inline preview render. All data already in locals — zero extra forks.
        {
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
            printf '╭─ Last session\n'
            if [ -n "$latest" ]; then
                printf '│  Name     %s\n' "${sname:-(unnamed)}"
                printf '│  UUID     %s\n' "${uuid:0:8}"
                printf '│  Updated  %s\n' "$age"
                [ -n "$desc" ] && printf '│  Summary  %s\n' "$desc"
            else
                printf '│  (no sessions yet)\n'
            fi
            printf '╰─\n'
        } > "$PREVIEW_CACHE_DIR/$area.txt"
    done
}

# --- step 1: area picker -----------------------------------------------------
#
# Header lines: top border / column titles / separator. --header-lines=3 keeps
# them pinned and skips them during navigation.
#
# Returns 0 (sets CHOSEN_AREA), 10 (ESC, top-level so caller quits), or 130
# (Ctrl-C). build_area_rows is re-run on each call so flag badges and ages
# reflect any in-session env edits.
pick_area() {
    build_area_rows

    # fzf preview command needs the area NAME, not the whole table row.
    # Extract the second column (after "│ ") — strip surrounding whitespace
    # and the optional " *" running marker. Content is already on disk;
    # preview just cats the cache file, so cursor motion is near-instant.
    local preview_cmd
    preview_cmd='area=$(printf "%s" {} | sed -E "s/^│ +([^ │]+).*/\1/; s/ \*$//"); cat "$PREVIEW_CACHE_DIR/$area.txt" 2>/dev/null'

    local row rc=0
    row=$(
        {
            area_header_top
            area_header_labels
            area_header_sep
            printf '%s\n' "${AREA_ROWS[@]}"
        } | fzf_pick \
            --prompt='  Sandbox  ' \
            --header='claude-sandbox · ↑/↓ navigate · ENTER select · ESC quit · CTRL-C quit · "*" = running' \
            --header-lines=3 \
            --preview="$preview_cmd" \
            --preview-window='right,55%,wrap,border-rounded' \
            --height=90% \
            "${FZF_THEME[@]}"
    ) || rc=$?
    [ $rc -ne 0 ] && return $rc

    CHOSEN_AREA=$(printf '%s' "$row" | sed -E 's/^│ +([^ │]+).*/\1/; s/ \*$//')
    local a found=0
    for a in "${AREA_INDEX[@]}"; do
        [ "$a" = "$CHOSEN_AREA" ] && { found=1; break; }
    done
    [ $found = 1 ] || { echo "ERROR: could not parse area name from row '$row'." >&2; return 130; }
    return 0
}

# --- step 1.5: refuse if the area is already running -------------------------
# Returns 0 if free, 10 if running (caller goes back to area picker so the
# user can pick a different one without restarting the script).
check_not_running() {
    local cid
    cid=$(sb_running_cid "$CHOSEN_AREA")
    [ -z "$cid" ] && return 0
    echo "Sandbox '${CHOSEN_AREA}' is already running (container ${cid:0:12})." >&2
    echo "  Attach with:  docker exec -it claude-sandbox-${CHOSEN_AREA} bash" >&2
    echo "  Or stop:      docker stop claude-sandbox-${CHOSEN_AREA}" >&2
    echo "Returning to area picker." >&2
    return 10
}

# --- step 2: toggle loop -----------------------------------------------------

load_toggle_state() {
    ENV_FILE="$SCRIPT_DIR/env.${CHOSEN_AREA}.sh"
    local flags_line
    flags_line=$(sb_read_env_flags "$ENV_FILE")
    IFS='|' read -r INITIAL_PROJECTS_DIR INITIAL_HR INITIAL_FW INITIAL_VX <<<"$flags_line"
    HR=$INITIAL_HR; VX=$INITIAL_VX; FW=$INITIAL_FW
}

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

# Returns 0 = Launch chosen, 10 = ESC (back to area), 130 = Ctrl-C.
pick_toggles() {
    local pick rc
    while true; do
        rc=0
        pick=$(
            {
                toggle_top
                printf '│ %-*s │\n' "$TW" "Flags for sandbox '${CHOSEN_AREA}'"
                toggle_sep
                toggle_row "$HR" "H" "Headroom"        "token compression proxy"
                toggle_row "$VX" "V" "Vertex AI"       "route via host GCP project (paid)"
                toggle_row "$FW" "F" "FISS-MCP writes" "agent can mutate Terra state"
                toggle_sep
                printf '│ %-*s │\n' "$TW" "▶  Launch sandbox"
                toggle_bot
            } | fzf_pick \
                --prompt='  Toggle  ' \
                --header="claude-sandbox · ${CHOSEN_AREA} · ENTER flip/launch · ESC back · CTRL-C quit" \
                --header-lines=3 \
                --no-multi \
                --height=50% \
                "${FZF_THEME[@]}"
        ) || rc=$?

        case $rc in
            10|130) return $rc ;;
            0)
                case "$pick" in
                    *Headroom*)          HR=$((1 - HR)) ;;
                    *'Vertex AI'*)       VX=$((1 - VX)) ;;
                    *'FISS-MCP writes'*) FW=$((1 - FW)) ;;
                    *'Launch sandbox'*)  return 0 ;;
                    *) : ;;
                esac
                ;;
        esac
    done
}

# --- persist toggles via managed block (only if changed) ---------------------
persist_toggles() {
    [[ "$HR" = "$INITIAL_HR" && "$VX" = "$INITIAL_VX" && "$FW" = "$INITIAL_FW" ]] && return 0
    local NEW_BLOCK TMP
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
    # Sync baseline so a later round-trip through this menu doesn't re-write
    # the block when nothing further changed.
    INITIAL_HR=$HR; INITIAL_VX=$VX; INITIAL_FW=$FW
}

# --- step 3: session picker --------------------------------------------------

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

# Returns 0 (sets CHOSEN_SESSION), 10 (ESC back to toggle), 130 (Ctrl-C).
pick_session() {
    local state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${CHOSEN_AREA}/.claude/projects"

    SESSION_ROWS=()
    SESSION_UUIDS=()
    SESSION_ROWS+=("$(session_row "▶ NEW SESSION" "" "" "Start a fresh conversation")")
    SESSION_UUIDS+=("NEW")

    if [ -d "$state_dir" ]; then
        local now mt f uuid age name desc
        now=$(date +%s)
        while IFS=$'\t' read -r mt f; do
            uuid=$(basename "$f" .jsonl)
            age=$(sb_fmt_age $((now - mt)))
            IFS=$'\t' read -r name desc <<<"$(sb_session_meta "$f")"
            [ -z "$desc" ] && desc='(no summary)'
            [ -z "$name" ] && name='(unnamed)'
            SESSION_ROWS+=("$(session_row "$name" "$uuid" "$age" "$desc")")
            SESSION_UUIDS+=("$uuid")
        done < <(sb_list_sessions "$state_dir" | sort -rn | head -30)
    fi

    local row rc=0
    row=$(
        {
            session_header_top
            session_header_labels
            session_header_sep
            printf '%s\n' "${SESSION_ROWS[@]}"
        } | fzf_pick \
            --prompt='  Session  ' \
            --header="claude-sandbox · ${CHOSEN_AREA} · ENTER select · ESC back · CTRL-C quit" \
            --header-lines=3 \
            --height=80% \
            "${FZF_THEME[@]}"
    ) || rc=$?
    [ $rc -ne 0 ] && return $rc

    CHOSEN_SESSION=""
    local i
    for i in "${!SESSION_ROWS[@]}"; do
        if [ "${SESSION_ROWS[$i]}" = "$row" ]; then
            CHOSEN_SESSION="${SESSION_UUIDS[$i]}"
            break
        fi
    done
    [ -n "$CHOSEN_SESSION" ] || { echo "ERROR: could not resolve session UUID." >&2; return 130; }
    return 0
}

# --- main state machine ------------------------------------------------------
#
# Transitions: area → running_check → toggle → session → launch.
# ESC at any step: back one step (except area, which is top-level → quit).
# Ctrl-C anywhere: quit.

CHOSEN_AREA=""
CHOSEN_SESSION=""
ENV_FILE=""
STAGE=area
while true; do
    rc=0
    case "$STAGE" in
        area)
            pick_area || rc=$?
            case $rc in
                0)        STAGE=running_check ;;
                10|130|*) echo "Cancelled."; exit 0 ;;
            esac
            ;;
        running_check)
            check_not_running || rc=$?
            case $rc in
                0)  load_toggle_state; STAGE=toggle ;;
                10) STAGE=area ;;
                *)  exit $rc ;;
            esac
            ;;
        toggle)
            pick_toggles || rc=$?
            case $rc in
                0)   persist_toggles; STAGE=session ;;
                10)  STAGE=area ;;
                130) echo "Aborted."; exit 130 ;;
                *)   exit $rc ;;
            esac
            ;;
        session)
            pick_session || rc=$?
            case $rc in
                0)   break ;;
                10)  STAGE=toggle ;;
                130) echo "Aborted."; exit 130 ;;
                *)   exit $rc ;;
            esac
            ;;
    esac
done

# --- launch ------------------------------------------------------------------

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
