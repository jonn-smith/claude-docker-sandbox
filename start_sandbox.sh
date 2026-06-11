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

# Portable SCRIPT_DIR resolution — BSD `readlink` (macOS) has no `-f`.
# Manually walk symlink chain so this works on Linux and macOS alike.
__resolve_dir() {
    local src=${BASH_SOURCE[0]}
    while [ -L "$src" ]; do
        local d
        d=$(cd -P "$(dirname "$src")" && pwd)
        src=$(readlink "$src")
        [[ $src != /* ]] && src=$d/$src
    done
    cd -P "$(dirname "$src")" && pwd
}
SCRIPT_DIR=$(__resolve_dir)
# shellcheck source=scripts/sandbox_lib.sh
source "$SCRIPT_DIR/scripts/sandbox_lib.sh"

MARK_BEGIN="# vvv start_sandbox managed block — regenerated, do not edit vvv"
MARK_END="# ^^^ start_sandbox managed block ^^^"

# Master workdir registry. Plain text, one absolute host path per line. Seeded
# from every env.<area>.sh `export CLAUDE_SANDBOX_PROJECTS_DIR=...` line (both
# active and commented out) on first run; thereafter every chosen workdir is
# unioned in. This is the "master coordinating location" — the list of paths
# this host knows it can mount at /workspace.
WORKDIRS_FILE="$SCRIPT_DIR/workdirs.txt"

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
    # ESCDELAY=25 is set hopefully — fzf's internal escape-disambiguation
    # timeout (waiting to see whether ESC is a lone press or the prefix of an
    # arrow-key CSI sequence) is the dominant remaining delay on older fzf
    # builds and not fully tunable from outside. Upgrading fzf to a recent
    # version is the only further fix.
    out=$(ESCDELAY=25 fzf --expect=esc "$@") || rc=$?
    if [ $rc -ne 0 ]; then
        return 130   # ctrl-c or other abort
    fi
    # Parse "<key>\n<row>" via bash param expansion — avoids two sed forks
    # per fzf invocation. Shaves a perceptible chunk off back-navigation.
    key=${out%%$'\n'*}
    sel=${out#*$'\n'}
    [ "$key" = "esc" ] && return 10
    printf '%s\n' "$sel"
    return 0
}

# --- styling -----------------------------------------------------------------
#
# Dracula-ish purple palette with a solid red bar for the current row.
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
# Session name lives in the right preview pane only — the table now stops
# at LAST so workdir + flags + last-touch can breathe.
W_AREA=10
W_WORKDIR=42
W_FLAGS=7
W_AGE=10

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

# --- workdir registry --------------------------------------------------------
#
# Maintain $WORKDIRS_FILE as union(existing file, env.<area>.sh parsed paths).
# Sorted, unique. Idempotent: running twice with no env changes produces no
# diff. Writes only if content changed (avoids meaningless mtime bumps).
sync_workdirs_registry() {
    local tmp existing parsed
    tmp=$(mktemp)
    existing=""
    [ -r "$WORKDIRS_FILE" ] && existing=$(cat "$WORKDIRS_FILE")
    parsed=$(sb_collect_env_workdirs "$SCRIPT_DIR")
    printf '%s\n%s\n' "$existing" "$parsed" \
        | awk 'NF && !seen[$0]++' \
        | sort > "$tmp"
    if ! [ -r "$WORKDIRS_FILE" ] || ! cmp -s "$tmp" "$WORKDIRS_FILE"; then
        mv "$tmp" "$WORKDIRS_FILE"
    else
        rm -f "$tmp"
    fi
}

# Add a single path to the registry. Idempotent.
register_workdir() {
    local path=$1
    [ -n "$path" ] || return 0
    if [ -r "$WORKDIRS_FILE" ] && grep -qxF "$path" "$WORKDIRS_FILE"; then
        return 0
    fi
    printf '%s\n' "$path" >> "$WORKDIRS_FILE"
    sort -u "$WORKDIRS_FILE" -o "$WORKDIRS_FILE"
}

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
    local area=$1 workdir=$2 flags=$3 age=$4
    printf '│ %-*s │ %-*s │ %-*s │ %-*s │\n' \
        "$W_AREA"    "$(trim_right "$area"    "$W_AREA")" \
        "$W_WORKDIR" "$(trim_left  "$workdir" "$W_WORKDIR")" \
        "$W_FLAGS"   "$flags" \
        "$W_AGE"     "$age"
}

area_header_top()   { printf '╭─%s─┬─%s─┬─%s─┬─%s─╮\n' "$(hrule $W_AREA)" "$(hrule $W_WORKDIR)" "$(hrule $W_FLAGS)" "$(hrule $W_AGE)"; }
area_header_sep()   { printf '├─%s─┼─%s─┼─%s─┼─%s─┤\n' "$(hrule $W_AREA)" "$(hrule $W_WORKDIR)" "$(hrule $W_FLAGS)" "$(hrule $W_AGE)"; }
area_header_labels(){ area_row "AREA" "WORKDIR" "FLAGS" "LAST"; }

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
    local envfile state_dir flags projects_dir hr fw vx ro_mounts badge
    local latest mt age sname desc uuid area_label status

    envfile="$SCRIPT_DIR/env.${area}.sh"
    state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}"
    flags=$(sb_read_env_flags "$envfile")
    IFS='|' read -r projects_dir hr fw vx ro_mounts <<<"$flags"
    badge=$(flag_badge "$hr" "$vx" "$fw")

    # Summarize RO mounts for the preview pane: count + up to 3 basenames.
    # We don't replay the launcher's collision-renaming here — that runs
    # at launch and the operator can scroll the launch log for the final
    # `/read-only-reference/<name>` lines if they need exact names.
    local ro_count=0 ro_summary='(none)'
    if [ -n "$ro_mounts" ]; then
        local -a _ro_arr
        # shellcheck disable=SC2206
        _ro_arr=($ro_mounts)
        ro_count=${#_ro_arr[@]}
        local _sample='' _i
        for (( _i = 0; _i < ro_count && _i < 3; _i++ )); do
            local _bn
            _bn=$(basename "${_ro_arr[_i]}")
            if [ -z "$_sample" ]; then _sample=$_bn; else _sample="$_sample, $_bn"; fi
        done
        if (( ro_count > 3 )); then
            ro_summary="${ro_count} dirs: ${_sample}, …"
        else
            ro_summary="${ro_count} dirs: ${_sample}"
        fi
    fi

    latest=$(sb_latest_session_file "$state_dir/.claude/projects")
    sname=""; desc=""; uuid=""; age='(none)'; desc_full=""
    if [ -n "$latest" ]; then
        mt=$(sb_mtime_of "$latest")
        age=$(sb_fmt_age $((now - mt)))
        uuid=$(basename "$latest" .jsonl)
        # Single fetch at limit=4000 — preview pane shows the full text,
        # short table fields are derived from it in bash. Halves python forks
        # versus calling sb_session_meta once for short + once for long.
        IFS=$'\t' read -r sname desc_full <<<"$(sb_session_meta "$latest" 4000)"
        [ -z "$sname" ] && sname=${desc_full:-'(unnamed)'}
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
        printf '│  RO mounts          %s\n' "$ro_summary"
        printf '╰─\n\n'
        # Box-less so fzf --preview-window=wrap wraps long lines cleanly.
        printf 'Last session summary\n\n'
        if [ -n "$latest" ]; then
            if [ -n "$desc_full" ]; then
                printf '%s\n' "$desc_full"
            else
                printf '(no summary)\n'
            fi
        else
            printf '(no sessions yet)\n'
        fi
    } > "$PREVIEW_CACHE_DIR/$area.txt"

    area_row "$area_label" "${projects_dir:-?}" "$badge" "$age"
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

    # Parallel file: workdir per session row, so the launcher can look it up
    # without re-reading the sidecar after the pick. NEW SESSION → empty line.
    local wdirs_file="$PREVIEW_CACHE_DIR/sessions.${area}.workdirs"
    : > "$wdirs_file"

    local state_dir="$SCRIPT_DIR/claude-sandbox-persistent-state-${area}/.claude/projects"
    if [ -d "$state_dir" ]; then
        local mt f uuid age name desc_full short workdir wd_short
        while IFS=$'\t' read -r mt f; do
            uuid=$(basename "$f" .jsonl)
            age=$(sb_fmt_age $((now - mt)))
            # One python call per session, full text. Short version trimmed
            # in bash so we don't pay a second fork for the preview pane.
            IFS=$'\t' read -r name desc_full <<<"$(sb_session_meta "$f" 4000)"
            [ -z "$desc_full" ] && desc_full='(no summary)'
            [ -z "$name" ] && name='(unnamed)'
            short=$desc_full
            [ ${#short} -gt 80 ] && short="${short:0:79}…"
            workdir=$(sb_session_workdir "$f")
            # Display: empty sidecar → "(unknown)" so the user can see which
            # sessions predate workdir tracking.
            wd_short=${workdir:-'(unknown)'}
            session_row "$wd_short" "$uuid" "$age" "$short" >> "$rows_file"
            printf '%s\n' "$uuid" >> "$uuids_file"
            printf '%s\n' "$workdir" >> "$wdirs_file"
            {
                printf 'Workdir:  %s\n' "${workdir:-(unknown — legacy session)}"
                printf 'Name:     %s\n' "$name"
                printf 'UUID:     %s\n' "$uuid"
                printf 'Age:      %s\n' "$age"
                printf '\nSummary\n\n'
                printf '%s\n' "$desc_full"
            } > "$PREVIEW_CACHE_DIR/session.${uuid:0:8}.txt"
        done < <(sb_list_sessions "$state_dir" | sort -rn | head -30)
    fi
    session_row "▶ NEW SESSION" "" "" "Start a fresh conversation" >> "$rows_file"
    printf 'NEW\n' >> "$uuids_file"
    printf '\n' >> "$wdirs_file"
}

# Two helper scripts that back the menu-2 list. They live on disk so the
# pick_session loop can re-exec view.sh on every reopen without re-quoting
# heredocs.
#
#   view.sh   emits the full menu-2 row list to stdout: pinned header lines,
#             session rows, separator, three flag rows with current state.
#   flip.sh   given a row text and the toggle state file, identifies which
#             flag the row corresponds to and flips it in place.
write_view_helpers() {
    mkdir -p "$PREVIEW_CACHE_DIR/bin"
    cat > "$PREVIEW_CACHE_DIR/bin/view.sh" <<'SH'
#!/usr/bin/env bash
# Args: <header_file> <session_rows_file> <toggle_state_file>
# Header file contains the 3 table-header lines (top / labels / separator);
# fzf pins them via --header-lines=3 so they stay frozen across reloads.
set -u
cat "$1"
cat "$2"
printf '\n'
printf '  ── Flags ──  (RIGHT to focus · ENTER to toggle · LEFT to go back)\n'
read -r h v f < "$3"
ch() { [ "$1" = 1 ] && printf '[✓]' || printf '[ ]'; }
printf '  %s  Headroom         token compression\n'    "$(ch "$h")"
printf '  %s  Vertex AI        paid GCP project\n'     "$(ch "$v")"
printf '  %s  FISS-MCP writes  agent can mutate Terra\n' "$(ch "$f")"
SH
    chmod +x "$PREVIEW_CACHE_DIR/bin/view.sh"

    cat > "$PREVIEW_CACHE_DIR/bin/flip.sh" <<'SH'
#!/usr/bin/env bash
# Args: <row_text> <toggle_state_file>
# Identifies the flag from the row's label and flips it in the state file.
set -u
row=$1; sf=$2
read -r h v f < "$sf"
case "$row" in
    *Headroom*)          h=$((1-h)) ;;
    *'Vertex AI'*)       v=$((1-v)) ;;
    *'FISS-MCP writes'*) f=$((1-f)) ;;
esac
printf '%d %d %d\n' "$h" "$v" "$f" > "$sf"
SH
    chmod +x "$PREVIEW_CACHE_DIR/bin/flip.sh"

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
    local now running_set area i n
    n=${#AREAS[@]}
    printf 'start_sandbox: indexing %d sandbox(es), this is slow because\n' "$n" >&2
    printf '  each docker check + per-session JSON parse is a fork...\n' >&2
    printf '  syncing workdir registry from env files...\n' >&2
    sync_workdirs_registry
    printf '  scanning docker for running containers...\n' >&2
    now=$(date +%s)
    running_set=" $(sb_running_areas | tr '\n' ' ') "
    i=0
    for area in "${AREAS[@]}"; do
        i=$((i+1))
        printf '  [%d/%d] indexing %s sessions...\n' "$i" "$n" "$area" >&2
        AREA_ROWS+=("$(build_one_area "$area" "$running_set" "$now")")
        AREA_INDEX+=("$area")
        build_session_cache "$area" "$now"
    done
    # Session table header is the same for every area (constant widths),
    # so write it once. view.sh emits it ahead of the data rows.
    {
        session_header_top
        session_header_labels
        session_header_sep
    } > "$PREVIEW_CACHE_DIR/sessions.header"
    write_view_helpers
    write_flag_previews
    printf '  ready.\n' >&2
}

# Per-flag preview text shown in menu-2's right pane when a flag row is
# highlighted. Source of truth for what each flag actually does at launch.
write_flag_previews() {
    cat > "$PREVIEW_CACHE_DIR/flag.headroom.txt" <<'TXT'
HEADROOM
token compression proxy

When ON:
  Container starts a local proxy that compresses the conversation
  context before it hits the Anthropic API. Saves input tokens on
  long sessions at the cost of some fidelity.

env var:
  HEADROOM=1
TXT

    cat > "$PREVIEW_CACHE_DIR/flag.vertex.txt" <<'TXT'
VERTEX AI
route Anthropic API calls through Google Cloud Vertex AI

When ON (sources SET_VERTEX_MODE.sh):
  CLAUDE_CODE_USE_VERTEX=1
  ANTHROPIC_VERTEX_PROJECT_ID=broad-dsde-methods
  CLOUD_ML_REGION=global
  ANTHROPIC_MODEL=claude-opus-4-7
  CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

Billing:
  Charges land on the broad-dsde-methods GCP project, NOT your
  personal Anthropic account. Use this when you want the spend on
  the lab budget instead of personal credits.

When OFF:
  CLAUDE_CODE_USE_VERTEX / ANTHROPIC_VERTEX_PROJECT_ID /
  CLOUD_ML_REGION are unset → SDK falls back to api.anthropic.com.
TXT

    cat > "$PREVIEW_CACHE_DIR/flag.fiss_writes.txt" <<'TXT'
FISS-MCP writes
allow the agent to mutate Terra / GCP state

When OFF (default):
  Host-side fiss-mcp server runs in read-only mode. Agent can
  read workspace metadata, list submissions, fetch logs — but
  cannot submit workflows, change workspace attributes, or
  otherwise spend money.

When ON:
  fiss-mcp launches with FISS_MCP_ALLOW_WRITES=1. Agent can:
    - submit/abort workflow runs in Terra
    - mutate workspace and data-table attributes
    - upload entities
  → real money on Terra / GCP. Red banners print on both host
    and container at startup as a reminder.

env var:
  FISS_MCP_ALLOW_WRITES=1
TXT
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
            --bind='enter:accept-non-empty' \
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

# Row columns. WORKDIR is the primary identifier (sessions are coupled to a
# workdir at launch time, recorded in a sidecar). NAME (custom-title) is
# rarely set in practice and would waste a column — surfaced in the preview
# pane instead.
SW_WORKDIR=28
SW_UUID=8
SW_AGE=10
SW_SUMMARY=40

session_row() {
    local workdir=$1 uuid=$2 age=$3 summary=$4
    printf '│ %-*s │ %-*s │ %-*s │ %-*s │\n' \
        "$SW_WORKDIR" "$(trim_left  "$workdir" "$SW_WORKDIR")" \
        "$SW_UUID"    "${uuid:0:SW_UUID}" \
        "$SW_AGE"     "$age" \
        "$SW_SUMMARY" "$(trim_right "$summary" "$SW_SUMMARY")"
}
session_header_top()   { printf '╭─%s─┬─%s─┬─%s─┬─%s─╮\n' "$(hrule $SW_WORKDIR)" "$(hrule $SW_UUID)" "$(hrule $SW_AGE)" "$(hrule $SW_SUMMARY)"; }
session_header_sep()   { printf '├─%s─┼─%s─┼─%s─┼─%s─┤\n' "$(hrule $SW_WORKDIR)" "$(hrule $SW_UUID)" "$(hrule $SW_AGE)" "$(hrule $SW_SUMMARY)"; }
session_header_labels(){ session_row "WORKDIR" "UUID" "LAST" "SUMMARY"; }

# Combined session + flags picker. The fzf list is a single column
# produced by view.sh: per-area session rows on top, a visual separator,
# then three flag rows reflecting the current toggle state. Navigation:
#
#   ↑/↓      step through the list
#   RIGHT    jump cursor to the first flag row     (pos -3)
#   LEFT     jump cursor to the first session row  (pos 1)
#   ENTER    flag row → flip state, reopen fzf (cursor jumps back to top)
#            separator → reopen (no-op)
#            session/NEW → accept, resolve UUID, return
#   ESC      back to area picker
#   CTRL-C   quit
#
# fzf reopen loop (not in-process transform) to stay compatible with older
# fzf versions that lack the transform action (added in 0.42).
#
# Returns 0 (sets CHOSEN_SESSION + HR/VX/FW + ENV_FILE + INITIAL_*),
# 10 (ESC → back to area picker), 130 (Ctrl-C).
pick_session() {
    ENV_FILE="$SCRIPT_DIR/env.${CHOSEN_AREA}.sh"
    local toggle_file="$PREVIEW_CACHE_DIR/toggles.${CHOSEN_AREA}"
    local sess_rows="$PREVIEW_CACHE_DIR/sessions.${CHOSEN_AREA}.rows"
    local sess_uuids="$PREVIEW_CACHE_DIR/sessions.${CHOSEN_AREA}.uuids"
    local sess_wdirs="$PREVIEW_CACHE_DIR/sessions.${CHOSEN_AREA}.workdirs"
    local hdr_file="$PREVIEW_CACHE_DIR/sessions.header"
    local view_sh="$PREVIEW_CACHE_DIR/bin/view.sh"
    local flip_sh="$PREVIEW_CACHE_DIR/bin/flip.sh"

    # Reset toggle state from the env file on entry. In-session flips that
    # don't end in a launch (user ESC-ed out) therefore evaporate.
    local flags _pd
    flags=$(sb_read_env_flags "$ENV_FILE")
    # Fifth field (RO mounts) ignored here — toggle screen doesn't expose
    # it. read into a sink var so it doesn't leak into INITIAL_VX.
    IFS='|' read -r _pd INITIAL_HR INITIAL_FW INITIAL_VX _ro_mounts <<<"$flags"
    HR=$INITIAL_HR; VX=$INITIAL_VX; FW=$INITIAL_FW
    printf '%d %d %d\n' "$HR" "$VX" "$FW" > "$toggle_file"

    # Drop any workdir picked on a prior pass through this menu — the next
    # selection sets it fresh (sidecar value for existing sessions, empty
    # for NEW SESSION → triggers pick_workdir).
    CHOSEN_WORKDIR=""

    # Right-pane preview: parse uuid8 from row column 2; cat the matching
    # per-session summary file. Non-session rows (flag rows / separator) have
    # no matching file → fallback hint.
    local preview_cmd
    preview_cmd='row={};
case "$row" in
    *Headroom*)            cat "$PREVIEW_CACHE_DIR/flag.headroom.txt"; exit 0 ;;
    *"Vertex AI"*)         cat "$PREVIEW_CACHE_DIR/flag.vertex.txt"; exit 0 ;;
    *"FISS-MCP writes"*)   cat "$PREVIEW_CACHE_DIR/flag.fiss_writes.txt"; exit 0 ;;
    *"── Flags ──"*|"")    printf "(separator)"; exit 0 ;;
esac
uuid=$(printf "%s" "$row" | sed -E "s/^│ [^│]+ │ +([^ ]+) +│.*/\1/")
[ -z "$uuid" ] || [ "$uuid" = "$row" ] && { printf "(no summary)"; exit 0; }
cat "$PREVIEW_CACHE_DIR/session.$uuid.txt" 2>/dev/null || printf "(no summary)"'

    # Reopen-on-toggle loop. fzf's `transform` action would do this in-process
    # (no flicker) but it's fzf 0.42+; this loop works on any version. Every
    # ENTER returns control to the shell: flag rows → flip + reloop, session
    # rows → resolve UUID + return, separator → reloop.
    local row rc
    while :; do
        rc=0
        row=$(
            "$view_sh" "$hdr_file" "$sess_rows" "$toggle_file" | fzf_pick \
                --prompt='  Session  ' \
                --header="$(printf 'claude-sandbox  ·  %s  ·  pick session + flags\n↑/↓ navigate  ·  RIGHT to flags  ·  LEFT to sessions  ·  ENTER act  ·  ESC back  ·  CTRL-C quit' "${CHOSEN_AREA}")" \
                --header-lines=3 \
                --bind='enter:accept-non-empty' \
                --bind="right:pos(-3)" \
                --bind="left:pos(1)" \
                --preview="$preview_cmd" \
                --preview-window='right,55%,wrap,border-rounded' \
                --height=90% \
                "${FZF_THEME[@]}"
        ) || rc=$?

        read -r HR VX FW < "$toggle_file"
        [ $rc -ne 0 ] && return $rc

        case "$row" in
            *Headroom*|*'Vertex AI'*|*'FISS-MCP writes'*)
                "$flip_sh" "$row" "$toggle_file"
                continue
                ;;
            *'── Flags ──'*|'')
                continue
                ;;
        esac

        # Session row — resolve to UUID + workdir via parallel walk of three
        # cache files (rows / uuids / workdirs). Workdir is empty for the
        # NEW SESSION sentinel row and for any legacy session without a
        # sidecar; both cases trigger pick_workdir() downstream.
        local line uuid="" workdir="" found=""
        while IFS= read -r line; do
            IFS= read -r uuid <&3 || true
            IFS= read -r workdir <&4 || true
            if [ "$line" = "$row" ]; then
                found=$uuid
                break
            fi
        done < "$sess_rows" 3< "$sess_uuids" 4< "$sess_wdirs"

        if [ -z "$found" ]; then
            echo "ERROR: could not resolve session UUID from row '$row'." >&2
            return 130
        fi
        CHOSEN_SESSION=$found
        CHOSEN_WORKDIR=$workdir
        return 0
    done
}

# --- step 4: workdir picker --------------------------------------------------
#
# Triggered after pick_session when the chosen row has no recorded workdir
# (NEW SESSION sentinel, or legacy session whose sidecar is missing). The
# user picks from the master registry $WORKDIRS_FILE; the "+ enter new path"
# sentinel drops to a free-text prompt so a one-off path can be used and
# unioned into the registry.
#
# Returns 0 with CHOSEN_WORKDIR set, 10 (ESC → back to session picker),
# 130 (Ctrl-C).
pick_workdir() {
    # Always refresh from disk — register_workdir() may have unioned an
    # entry between launches; the file is the source of truth.
    local -a entries=()
    if [ -r "$WORKDIRS_FILE" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && entries+=("$line")
        done < "$WORKDIRS_FILE"
    fi
    # Sentinel appended at bottom: same convention as ▶ NEW SESSION.
    local NEW_SENTINEL="▶ enter new path"

    local row rc=0
    row=$(
        {
            printf '%s\n' "${entries[@]}"
            printf '%s\n' "$NEW_SENTINEL"
        } | fzf_pick \
            --prompt='  Workdir  ' \
            --header=$'claude-sandbox  ·  pick workdir for new session\n↑/↓ navigate  ·  ENTER select  ·  ESC back  ·  CTRL-C quit\nworkdirs.txt is union of env files + every previous launch' \
            --bind='enter:accept-non-empty' \
            --preview='echo "Mount this host path at /workspace inside the sandbox container."; echo; echo "Path: {}"; echo; if [ -d "{}" ]; then echo "(exists)"; ls -A "{}" 2>/dev/null | head -20; else echo "(does not exist yet — will be created on launch if writable)"; fi' \
            --preview-window='right,55%,wrap,border-rounded' \
            --height=90% \
            "${FZF_THEME[@]}"
    ) || rc=$?
    [ $rc -ne 0 ] && return $rc

    if [ "$row" = "$NEW_SENTINEL" ]; then
        # Free-text entry. Read from /dev/tty so it works inside the
        # state-machine subshell context.
        local path=""
        printf 'Enter new workdir host path (absolute): ' >&2
        IFS= read -r path </dev/tty || return 10
        # Tilde expansion for ergonomics.
        path=${path/#\~/$HOME}
        if [ -z "$path" ] || [[ "$path" != /* ]]; then
            echo "ERROR: must be a non-empty absolute path." >&2
            return 10
        fi
        CHOSEN_WORKDIR=$path
    else
        CHOSEN_WORKDIR=$row
    fi
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
CHOSEN_WORKDIR=""
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
                0)
                    # NEW SESSION or legacy session with no sidecar → ask
                    # for the workdir. Existing tracked session: workdir
                    # came from the sidecar already, skip the picker.
                    if [ -z "$CHOSEN_WORKDIR" ]; then
                        STAGE=workdir
                    else
                        persist_toggles; break
                    fi
                    ;;
                10)  STAGE=area ;;
                130) echo "Aborted."; exit 130 ;;
                *)   exit $rc ;;
            esac
            ;;
        workdir)
            pick_workdir || rc=$?
            case $rc in
                0)   persist_toggles; break ;;
                10)  STAGE=session ;;
                130) echo "Aborted."; exit 130 ;;
                *)   exit $rc ;;
            esac
            ;;
    esac
done

# --- launch ------------------------------------------------------------------

# shellcheck source=/dev/null
source "$ENV_FILE"

# Workdir choice from the menu overrides whatever the env file's stacked
# `export CLAUDE_SANDBOX_PROJECTS_DIR=...` lines settled on. The env file is
# now purely for flags + base config; the workdir lives in workdirs.txt and
# per-session sidecars.
export CLAUDE_SANDBOX_PROJECTS_DIR="$CHOSEN_WORKDIR"

# Make sure the choice ends up in the master registry. Idempotent — if it's
# already there (came from the picker list), this is a no-op write.
register_workdir "$CHOSEN_WORKDIR"

STATE_PROJECTS_DIR="$SCRIPT_DIR/claude-sandbox-persistent-state-${CHOSEN_AREA}/.claude/projects"

LAUNCH_ARGS=(--dangerously-skip-permissions)
if [ "$CHOSEN_SESSION" != "NEW" ]; then
    LAUNCH_ARGS+=(--resume "$CHOSEN_SESSION")
    # Existing session: sidecar may already exist (no-op) or be missing
    # (legacy backfill). Either way, stamp it now so the next launcher run
    # sees the workdir in the session row.
    if [ -d "$STATE_PROJECTS_DIR" ]; then
        # Find the jsonl for this UUID across all project subdirs (almost
        # always just "-workspace", but tolerate other names).
        found_jsonl=""
        shopt -s nullglob
        for cand in "$STATE_PROJECTS_DIR"/*/"$CHOSEN_SESSION".jsonl; do
            found_jsonl=$cand
            break
        done
        shopt -u nullglob
        if [ -n "$found_jsonl" ]; then
            sb_write_session_workdir "$found_jsonl" "$CHOSEN_WORKDIR"
        fi
    fi
fi

# For a NEW SESSION the UUID won't exist until claude writes the jsonl
# inside the container. Capture a pre-launch timestamp so we can reconcile
# afterwards: any jsonl created later than this with no sidecar belongs to
# this launch and gets stamped with CHOSEN_WORKDIR.
PRE_LAUNCH_TS=$(date +%s)

echo
echo "Launching sandbox '${CHOSEN_AREA}'..."
echo "  Workdir: $CLAUDE_SANDBOX_PROJECTS_DIR"
echo "  Args:    ${LAUNCH_ARGS[*]}"
echo

# No `exec` — we need control back after claude exits so we can write the
# sidecar for the new session. The overhead is one shell frame; the user
# won't notice.
"$SCRIPT_DIR/run_claude_docker.sh" "${LAUNCH_ARGS[@]}"
LAUNCH_RC=$?

# Post-launch reconcile: stamp sidecars for any jsonl created during this
# run that doesn't have one yet. Bounded to files newer than PRE_LAUNCH_TS
# so we never overwrite an older session's data.
if [ -d "$STATE_PROJECTS_DIR" ]; then
    shopt -s nullglob
    for jsonl in "$STATE_PROJECTS_DIR"/*/*.jsonl; do
        sidecar="${jsonl%.jsonl}.workdir"
        [ -e "$sidecar" ] && continue
        mt=$(sb_mtime_of "$jsonl")
        [ -z "$mt" ] && continue
        if [ "$mt" -ge "$PRE_LAUNCH_TS" ]; then
            sb_write_session_workdir "$jsonl" "$CHOSEN_WORKDIR"
        fi
    done
    shopt -u nullglob
fi

exit "$LAUNCH_RC"
