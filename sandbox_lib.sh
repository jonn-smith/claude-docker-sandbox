# shellcheck shell=bash
# sandbox_lib.sh — shared helpers for list_sandboxes.sh and start_sandbox.sh.
# Source, don't execute. No side effects on source.

# Cross-platform mtime in seconds since epoch.
# GNU stat first (Linux is the primary host); fall back to BSD stat (macOS).
# Note: `stat -f` on Linux means --file-system and exits 0 with garbage banner
# output, so it must NOT come first or the OR short-circuit returns junk.
sb_mtime_of() {
    stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# Human-friendly elapsed seconds.
sb_fmt_age() {
    local s=$1
    if   [ "$s" -lt 60 ];    then printf "%ds ago" "$s"
    elif [ "$s" -lt 3600 ];  then printf "%dm ago" "$((s/60))"
    elif [ "$s" -lt 86400 ]; then printf "%dh ago" "$((s/3600))"
    else                          printf "%dd ago" "$((s/86400))"
    fi
}

# Pull the session's custom title (set via `claude --name`). Empty string if
# the session was never named. Silent no-op if python3 missing.
#
# Format: session jsonl files contain rows like:
#   {"type":"custom-title","customTitle":"my-name","sessionId":"<uuid>"}
# The first such row wins (later rows are renames; we take the original).
sb_session_name() {
    local jsonl=$1
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$jsonl" <<'PY'
import json, sys
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
            if isinstance(o, dict) and o.get('type') == 'custom-title':
                t = o.get('customTitle')
                if isinstance(t, str) and t.strip():
                    print(t.strip())
                    break
except FileNotFoundError:
    pass
PY
}

# Combined name + description in a single python3 invocation. Cuts startup
# cost roughly in half versus calling sb_session_name + sb_session_description
# separately (each fork is ~30-40 ms; the launcher does this once per area
# and once per recent session). Prints one line: "<name>\t<desc>".
# Either field may be empty.
sb_session_meta() {
    local jsonl=$1
    command -v python3 >/dev/null 2>&1 || { printf '\t\n'; return 0; }
    python3 - "$jsonl" <<'PY'
import json, sys
LIMIT = 80
def trim(s):
    s = ' '.join(s.split())
    return s if len(s) <= LIMIT else s[:LIMIT-1] + '…'
name = None
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
            t = o.get('type')
            if name is None and t == 'custom-title':
                v = o.get('customTitle')
                if isinstance(v, str) and v.strip():
                    name = v.strip()
            elif summary is None and t == 'summary':
                v = o.get('summary')
                if isinstance(v, str) and v.strip():
                    summary = v.strip()
            elif first_user is None and t == 'user':
                msg = o.get('message') or {}
                c = msg.get('content')
                if isinstance(c, str) and c.strip():
                    first_user = c.strip()
                elif isinstance(c, list):
                    for part in c:
                        if isinstance(part, dict) and part.get('type') == 'text':
                            tx = (part.get('text') or '').strip()
                            if tx:
                                first_user = tx
                                break
            if name and summary:
                break  # both fields filled — no need to keep scanning
except FileNotFoundError:
    pass
desc = summary or first_user or ''
print((name or '') + '\t' + (trim(desc) if desc else ''))
PY
}

# Pull a description for a session jsonl: prefer Claude-generated `summary`
# line; fall back to first user-prompt text. Truncated to 80 chars.
# Silent no-op if python3 missing.
sb_session_description() {
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

# Read env.<INSTANCE>.sh flag state without leaking vars into caller.
# Prints four pipe-separated fields:
#   <projects_dir>|<headroom>|<fiss_writes>|<vertex>
# Each flag is "1" if enabled, "0" if not. projects_dir is the resolved value.
sb_read_env_flags() {
    local envfile=$1
    [ -r "$envfile" ] || { echo "||0|0"; return 1; }
    bash -c "
        set +u
        # shellcheck disable=SC1090
        source '$envfile' >/dev/null 2>&1 || true
        printf '%s|%s|%s|%s\n' \
            \"\${CLAUDE_SANDBOX_PROJECTS_DIR:-}\" \
            \"\$([ \"\${HEADROOM:-0}\" = \"1\" ] && echo 1 || echo 0)\" \
            \"\$([ \"\${FISS_MCP_ALLOW_WRITES:-0}\" = \"1\" ] && echo 1 || echo 0)\" \
            \"\$([ \"\${CLAUDE_CODE_USE_VERTEX:-0}\" = \"1\" ] && echo 1 || echo 0)\"
    "
}

# Newest top-level session jsonl under a state dir. Empty string if none.
# Top-level only: skips ".../<uuid>/subagents/agent-*.jsonl" — those are
# sub-agent transcripts and are not directly resumable via `claude --resume`.
sb_latest_session_file() {
    local state_dir=$1
    [ -d "$state_dir" ] || return 0
    local latest="" latest_mt=0 mt
    shopt -s nullglob
    # Each immediate child of state_dir is the URL-encoded project path
    # (e.g. "-workspace"). Sessions live directly inside it as <uuid>.jsonl.
    for f in "$state_dir"/*/*.jsonl; do
        mt=$(sb_mtime_of "$f")
        [ -n "$mt" ] || continue
        if [ "$mt" -gt "$latest_mt" ]; then
            latest_mt=$mt
            latest=$f
        fi
    done
    shopt -u nullglob
    [ -n "$latest" ] && printf '%s\n' "$latest"
}

# Print all top-level session jsonl files under a state dir, tab-separated as
# "<mtime>\t<path>". Caller can sort -rn to get newest first.
sb_list_sessions() {
    local state_dir=$1
    [ -d "$state_dir" ] || return 0
    shopt -s nullglob
    local f mt
    for f in "$state_dir"/*/*.jsonl; do
        mt=$(sb_mtime_of "$f")
        [ -n "$mt" ] && printf '%s\t%s\n' "$mt" "$f"
    done
    shopt -u nullglob
}

# Is a sandbox area currently running? Echoes container id if so, else nothing.
sb_running_cid() {
    local instance=$1
    docker ps --filter "name=^claude-sandbox-${instance}$" -q 2>/dev/null
}

# Print, one per line, the area names of every running claude-sandbox
# container. Single docker call — callers that need to check N areas should
# read this once rather than calling sb_running_cid in a loop (each docker
# fork is ~50-150 ms).
sb_running_areas() {
    docker ps --filter ancestor=claude-sandbox --format '{{.Names}}' 2>/dev/null \
        | sed -n 's/^claude-sandbox-\(.*\)$/\1/p'
}
