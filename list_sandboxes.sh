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

# Cross-platform mtime in seconds since epoch (BSD stat on macOS, GNU on Linux).
mtime_of() {
    stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

fmt_age() {
    local s=$1
    if   [ "$s" -lt 60 ];    then printf "%ds ago" "$s"
    elif [ "$s" -lt 3600 ];  then printf "%dm ago" "$((s/60))"
    elif [ "$s" -lt 86400 ]; then printf "%dh ago" "$((s/3600))"
    else                          printf "%dd ago" "$((s/86400))"
    fi
}

# Pull a description for the session: prefer the Claude-generated `summary`
# line; fall back to the first user-prompt text. Truncated to 80 chars.
# Skipped silently if python3 isn't available.
session_description() {
    local jsonl=$1
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$jsonl" <<'PY'
import json, sys
LIMIT = 80
def trim(s):
    s = ' '.join(s.split())
    return s if len(s) <= LIMIT else s[:LIMIT-1] + '…'
summary = None
first_user = None
try:
    with open(sys.argv[1], 'r', encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                o = json.loads(line)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            if summary is None and o.get('type') == 'summary':
                s = o.get('summary')
                if isinstance(s, str) and s.strip():
                    summary = s.strip()
                    break  # summary wins, stop scanning
            if first_user is None and o.get('type') == 'user':
                msg = o.get('message') or {}
                c = msg.get('content')
                if isinstance(c, str) and c.strip():
                    first_user = c.strip()
                elif isinstance(c, list):
                    for part in c:
                        if isinstance(part, dict) and part.get('type') == 'text':
                            t = (part.get('text') or '').strip()
                            if t:
                                first_user = t
                                break
except FileNotFoundError:
    pass
if summary:
    print(trim(summary))
elif first_user:
    print(trim(first_user))
PY
}

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

    # Active session = most-recently-modified .jsonl under projects/ on the host.
    session_uuid="(none)"
    session_age=""
    session_desc=""
    if [ -n "$home" ] && [ -d "$home/projects" ]; then
        latest=""
        latest_mt=0
        for f in "$home/projects"/**/*.jsonl; do
            mt=$(mtime_of "$f")
            [ -n "$mt" ] || continue
            if [ "$mt" -gt "$latest_mt" ]; then
                latest_mt=$mt
                latest=$f
            fi
        done
        if [ -n "$latest" ]; then
            session_uuid=$(basename "$latest" .jsonl)
            session_age=$(fmt_age "$((now - latest_mt))")
            session_desc=$(session_description "$latest" || true)
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
