#!/usr/bin/env bash
# start_sandbox.sh — interactive launcher for claude-sandbox instances.
#
# Flow:
#   1. fzf area picker — ASCII-table rows, side preview panel with workdir,
#      flag state, last session, running status.
#   2. Refuses if the chosen area is already running.
#   3. Combined session+flags picker — recent sessions (mtime-desc) with
#      "▶ NEW SESSION" at the bottom; Headroom / Vertex / FISS-writes flags
#      shown in the right preview pane and toggled live via Alt-H / Alt-V /
#      Alt-F. Flag changes persist back to env.<INSTANCE>.sh inside a managed
#      block (idempotent) when the user finally launches.
#   4. Sources the (possibly patched) env file and execs
#      ./run_claude_docker.sh --dangerously-skip-permissions [--resume <uuid>].
#
# Caching: every menu the user can navigate is built ONCE at startup. The area
# table, per-area preview panels, and per-area session lists are written to a
# per-process tempdir. ESC-ing backward through the flow re-uses those caches
# instead of re-forking docker / python, so navigation is instant.
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
# Dracula-ish purple palette (chosen interactively via palette_preview.sh)
# with a solid red bar for the current row.
#
# Palette uses xterm-256 indices, no style modifiers, and one attribute per
# --color flag. Hex colors (#rrggbb) require fzf 0.32+; `:bold` / `:italic`
# modifiers require fzf 0.31+. When fzf rejects any token in a bundled
# `--color=a:x,b:y` string it silently falls back to defaults — which is
# why earlier hex+modifier attempts produced a blue header and a grey
# selection bar. Splitting one attribute per flag means at most one entry
# gets dropped on older fzf instead of the whole theme.
#
# Selection contrast: bg+ uses red (124) with cream fg+ (230). fzf
# extends bg+ across the full terminal width for the current row, so the
# selection reads as a solid bar, not just bolded text.
FZF_THEME=(
    --border=rounded
    --pointer='▶'
    --marker='✓'
    --info=inline-right
    --layout=reverse
    --no-mouse
    --cycle
    --color=border:141
    --color=label:141
    --color=header:117
    --color=prompt:117
    --color=query:230
    --color=pointer:230
    --color=marker:230
    --color=info:240
    --color=spinner:141
    --color=fg:252
    --color=fg+:230
    --color=bg+:124
    --color=hl:141
    --color=hl+:230
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

# Build a single area's row + preview cache file. Echoes the row text on
# stdout so the caller can append it to AREA_ROWS. Side effect: writes
# "$PREVIEW_CACHE_DIR/<area>.txt".
#
# Split out from the all-areas builder so callers can refresh one area in
# place if needed (e.g. after persisting a toggle change). $running_set and
# $now are passed in so the caller batches them and we don't re-fork docker
# or re-read the clock for every area.
build_one_area() {
    local area=$1 running_set=$2 now=$3
    local envfile state_dir flags projects_dir hr fw vx badge
    local latest mt age sname desc uuid area_label status

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
        area_label="${area} *"; status="RUNNING"
    else
        area_label="$area"; status="not running"
    fi

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

    area_row "$area_label" "${projects_dir:-?}" "$badge" "$age" "${sname:-—}"
}

# Write the per-area session-list cache. Produces two parallel files:
#   $PREVIEW_CACHE_DIR/sessions.<area>.rows   - aligned table rows
#   $PREVIEW_CACHE_DIR/sessions.<area>.uuids  - matching UUIDs (or "NEW")
# Sessions are sorted newest-first; the "▶ NEW SESSION" sentinel is appended
# at the BOTTOM so the most recent history is what the user sees right after
# the table headers (matches how they'd typically scan: top = most recent).
build_session_cache() {
    local area=$1 now=$2
    local rows_file="$PREVIEW_CACHE_DIR/sessions.${area}.rows"
    local uuids_file="$PREVIEW_CACHE_DIR/sessions.${area}.uuids"
    : > "$rows_file"
    : > "$uuids_file"

    local state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}/.claude/projects"
    if [ -d "$state_dir" ]; then
        local mt f uuid age name desc
        while IFS=$'\t' read -r mt f; do
            uuid=$(basename "$f" .jsonl)
            age=$(sb_fmt_age $((now - mt)))
            IFS=$'\t' read -r name desc <<<"$(sb_session_meta "$f")"
            [ -z "$desc" ] && desc='(no summary)'
            [ -z "$name" ] && name='(unnamed)'
            session_row "$name" "$uuid" "$age" "$desc" >> "$rows_file"
            printf '%s\n' "$uuid" >> "$uuids_file"
        done < <(sb_list_sessions "$state_dir" | sort -rn | head -30)
    fi
    session_row "▶ NEW SESSION" "" "" "Start a fresh conversation" >> "$rows_file"
    printf 'NEW\n' >> "$uuids_file"
}

# Write the two toggle helper scripts once at startup. fzf preview/bind
# commands can only call shell strings, not bash functions, so we keep these
# on disk. Both read/write a tiny "h v f" state file that the launcher reads
# back after fzf exits.
write_toggle_helpers() {
    cat > "$PREVIEW_CACHE_DIR/flip.sh" <<'SH'
#!/usr/bin/env bash
# Flip one flag in the live state file. Args: <h|v|f> <state_file>
set -u
which=$1; sf=$2
read -r h v f < "$sf"
case "$which" in
    h) h=$((1-h)) ;;
    v) v=$((1-v)) ;;
    f) f=$((1-f)) ;;
esac
printf '%d %d %d\n' "$h" "$v" "$f" > "$sf"
SH
    chmod +x "$PREVIEW_CACHE_DIR/flip.sh"

    cat > "$PREVIEW_CACHE_DIR/render_toggles.sh" <<'SH'
#!/usr/bin/env bash
# Render the right-pane toggle UI. Args: <state_file>
set -u
read -r h v f < "$1"
ch() { [ "$1" = 1 ] && printf '✓' || printf ' '; }
H=$(ch "$h"); V=$(ch "$v"); F=$(ch "$f")
cat <<MENU

  Flags

    [$H] Headroom         token compression
    [$V] Vertex AI        paid GCP project
    [$F] FISS-MCP writes  agent can mutate Terra

  Toggle keys
    Alt-H   Headroom
    Alt-V   Vertex AI
    Alt-F   FISS writes

  Navigation
    ENTER   launch selected
    ESC     back to areas
    CTRL-C  quit
MENU
SH
    chmod +x "$PREVIEW_CACHE_DIR/render_toggles.sh"
}

# Build every menu cache the launcher will navigate. Called once before the
# state-machine loop starts; nothing in the loop refreshes these because
# (a) the user can't go back beyond `area` (top-level ESC = quit) and (b)
# sessions don't appear mid-script (claude only writes them after exec).
AREA_ROWS=()
AREA_INDEX=()
build_all_caches() {
    AREA_ROWS=()
    AREA_INDEX=()
    local now running_set area
    now=$(date +%s)
    running_set=" $(sb_running_areas | tr '\n' ' ') "
    for area in "${AREAS[@]}"; do
        AREA_ROWS+=("$(build_one_area "$area" "$running_set" "$now")")
        AREA_INDEX+=("$area")
        build_session_cache "$area" "$now"
    done
    write_toggle_helpers
}

# --- step 1: area picker -----------------------------------------------------
#
# Header lines: top border / column titles / separator. --header-lines=3 keeps
# them pinned and skips them during navigation.
#
# Returns 0 (sets CHOSEN_AREA), 10 (ESC, top-level so caller quits), or 130
# (Ctrl-C). Reads from caches populated by build_all_caches — re-entering
# pick_area via ESC from the session screen is therefore zero-cost.
pick_area() {
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
            --header=$'claude-sandbox  ·  area picker\n↑/↓ navigate  ·  ENTER select  ·  ESC quit  ·  CTRL-C quit\n"*" suffix = currently running' \
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

# Combined session + flags picker. Session list comes from the per-area
# cache file written by build_session_cache (newest first, "▶ NEW SESSION"
# at the bottom). Toggle state lives in $PREVIEW_CACHE_DIR/toggles.<area>
# — a three-int file mutated in place by flip.sh and rendered in fzf's
# right preview pane by render_toggles.sh.
#
# Returns 0 (sets CHOSEN_SESSION + HR/VX/FW + ENV_FILE + INITIAL_*),
# 10 (ESC → back to area picker), 130 (Ctrl-C).
pick_session() {
    ENV_FILE="$SCRIPT_DIR/env.${CHOSEN_AREA}.sh"
    local toggle_file="$PREVIEW_CACHE_DIR/toggles.${CHOSEN_AREA}"
    local sess_rows="$PREVIEW_CACHE_DIR/sessions.${CHOSEN_AREA}.rows"
    local sess_uuids="$PREVIEW_CACHE_DIR/sessions.${CHOSEN_AREA}.uuids"
    local flip_sh="$PREVIEW_CACHE_DIR/flip.sh"
    local render_sh="$PREVIEW_CACHE_DIR/render_toggles.sh"

    # Reset toggle state from the env file on every entry into this screen.
    # In-session flips that didn't end in a launch (the user ESC-ed out)
    # therefore evaporate, matching the "haven't committed yet" intuition.
    local flags _pd
    flags=$(sb_read_env_flags "$ENV_FILE")
    IFS='|' read -r _pd INITIAL_HR INITIAL_FW INITIAL_VX <<<"$flags"
    HR=$INITIAL_HR; VX=$INITIAL_VX; FW=$INITIAL_FW
    printf '%d %d %d\n' "$HR" "$VX" "$FW" > "$toggle_file"

    local row rc=0
    row=$(
        {
            session_header_top
            session_header_labels
            session_header_sep
            cat "$sess_rows"
        } | fzf_pick \
            --prompt='  Session  ' \
            --header="$(printf 'claude-sandbox  ·  %s  ·  pick session + flags\nENTER launch  ·  Alt-H/V/F flip flag  ·  ESC back  ·  CTRL-C quit' "${CHOSEN_AREA}")" \
            --header-lines=3 \
            --preview="$render_sh $toggle_file" \
            --preview-window='right,42%,wrap,border-rounded' \
            --bind="alt-h:execute-silent($flip_sh h $toggle_file)+refresh-preview" \
            --bind="alt-v:execute-silent($flip_sh v $toggle_file)+refresh-preview" \
            --bind="alt-f:execute-silent($flip_sh f $toggle_file)+refresh-preview" \
            --height=85% \
            "${FZF_THEME[@]}"
    ) || rc=$?

    # Slurp the (possibly flipped) toggle state regardless of rc — harmless
    # if the user ESC'd, and required if they pressed Enter.
    read -r HR VX FW < "$toggle_file"

    [ $rc -ne 0 ] && return $rc

    # Resolve the chosen row → UUID by walking the rows + uuids files in
    # parallel. fd 3 reads uuids while the main loop reads rows.
    local line uuid="" found=""
    while IFS= read -r line; do
        IFS= read -r uuid <&3 || true
        if [ "$line" = "$row" ]; then
            found=$uuid
            break
        fi
    done < "$sess_rows" 3< "$sess_uuids"

    if [ -z "$found" ]; then
        echo "ERROR: could not resolve session UUID." >&2
        return 130
    fi
    CHOSEN_SESSION=$found
    return 0
}

# --- main state machine ------------------------------------------------------
#
# Transitions: area → running_check → session → launch.
# Flags are now part of the session screen, so there's no separate toggle
# stage. ESC at any step goes back one step (area is top-level → quit).
# Ctrl-C anywhere: quit.

CHOSEN_AREA=""
CHOSEN_SESSION=""
ENV_FILE=""

# All menus are populated up-front so forward and ESC-backward navigation
# don't pay any docker / python costs.
build_all_caches

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
                0)  STAGE=session ;;
                10) STAGE=area ;;
                *)  exit $rc ;;
            esac
            ;;
        session)
            pick_session || rc=$?
            case $rc in
                0)   persist_toggles; break ;;
                10)  STAGE=area ;;
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
