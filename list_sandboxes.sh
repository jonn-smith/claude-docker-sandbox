#!/usr/bin/env bash
# List all running claude-sandbox instances with their mount layout and the
# active Claude Code session (UUID, age, summary or first-prompt preview).
#
# Usage: ./list_sandboxes.sh

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    echo "Error: this script requires bash 4.2+ (running ${BASH_VERSION:-unknown})." >&2
    echo "On macOS the system bash is 3.2 — install a newer one (e.g. 'brew install bash')" >&2
    echo "and re-invoke with that interpreter, e.g.: /opt/homebrew/bin/bash $0" >&2
    exit 1
fi

set -euo pipefail
shopt -s globstar nullglob

# Shared helpers (sb_fmt_age, sb_session_description, sb_mtime_of, …).
__LS_SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=scripts/sandbox_lib.sh
source "$__LS_SCRIPT_DIR/scripts/sandbox_lib.sh"

CIDS=()
while IFS= read -r cid; do
    [ -n "$cid" ] && CIDS+=("$cid")
done < <(docker ps --filter ancestor=claude-sandbox --format '{{.ID}}')

if [ "${#CIDS[@]}" -eq 0 ]; then
    echo "No running claude-sandbox instances."
    exit 0
fi

echo "Found ${#CIDS[@]} running instance(s):"
echo

mount_source_for() {
    local cid=$1 dest=$2
    docker inspect --format \
        "{{range .Mounts}}{{if eq .Destination \"${dest}\"}}{{.Source}}{{end}}{{end}}" \
        "$cid"
}

# DinD is a named volume, not a bind mount. Surface .Name when it's a volume,
# .Source otherwise.
mount_volume_for() {
    local cid=$1 dest=$2
    docker inspect --format \
        "{{range .Mounts}}{{if eq .Destination \"${dest}\"}}{{if eq .Type \"volume\"}}{{.Name}}{{else}}{{.Source}}{{end}}{{end}}{{end}}" \
        "$cid"
}

# mtime_of, fmt_age, session_description now live in sandbox_lib.sh.

now=$(date +%s)

for cid in "${CIDS[@]}"; do
    raw_name=$(docker inspect --format '{{.Name}}' "$cid")
    raw_name="${raw_name#/}"
    if [[ "$raw_name" == claude-sandbox-* ]]; then
        instance="${raw_name#claude-sandbox-}"
    else
        instance="(unnamed: $raw_name)"
    fi
    status=$(docker ps --filter id="$cid" --format '{{.Status}}')
    image=$(docker inspect --format '{{.Config.Image}}' "$cid")

    workspace=$(mount_source_for "$cid" /workspace)
    context=$(mount_source_for "$cid" /context)
    home=$(mount_source_for "$cid" /home/claude/.claude)
    dind=$(mount_volume_for "$cid" /var/lib/docker)

    # Active session = most-recently-modified top-level .jsonl under projects/.
    # sb_latest_session_file skips subagent transcripts.
    session_uuid="(none)"
    session_age=""
    session_desc=""
    if [ -n "$home" ] && [ -d "$home/projects" ]; then
        latest=$(sb_latest_session_file "$home/projects")
        if [ -n "$latest" ]; then
            latest_mt=$(sb_mtime_of "$latest")
            session_uuid=$(basename "$latest" .jsonl)
            session_age=$(sb_fmt_age "$((now - latest_mt))")
            session_desc=$(sb_session_description "$latest" || true)
        fi
    fi

    printf "Instance: %s\n" "$instance"
    printf "  Container:   %s  (%s)\n" "${cid:0:12}" "$status"
    printf "  Image:       %s\n" "$image"
    printf "  Workspace:   %s\n" "${workspace:-<none>}"
    printf "  Context:     %s\n" "${context:-<none>}"
    printf "  State home:  %s\n" "${home:-<none>}"
    printf "  DinD volume: %s\n" "${dind:-<none>}"
    if [ -n "$session_age" ]; then
        printf "  Session:     %s  (%s)\n" "$session_uuid" "$session_age"
    else
        printf "  Session:     %s\n" "$session_uuid"
    fi
    if [ -n "$session_desc" ]; then
        printf "  Description: %s\n" "$session_desc"
    fi
    echo
done
