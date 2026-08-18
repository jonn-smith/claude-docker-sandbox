#!/usr/bin/env bash
# archive_sessions.sh — copy Claude Code session history out of every
# instance's live state dir into SESSION_ARCHIVE/, on demand.
#
# Sources scanned (relative to the repo root):
#   persistent-states/<INSTANCE>/.claude/  — per-instance state
#   claude-sandbox-shared/.claude/         — shared-mode state (USE_SHARED=1)
#
# For each source we copy:
#   .claude/projects/    session transcripts (<uuid>.jsonl) + their sidecar
#                        dirs (tool-results, memory, …)
#   .claude/history.jsonl   the command-history log, if present
#
# Destination: SESSION_ARCHIVE/<source>/ where <source> is the instance
# name (B, GATK, WHB, main, …) or "shared". Re-running overwrites with the
# live copy — transcripts are frozen once a session ends, so this is a
# safe mirror, not a destructive sync (nothing in the archive is deleted
# just because it vanished upstream).
#
# ponytail: cp-based mirror, no rsync (not installed on this host). If the
# transcript count grows into the thousands and full recopy gets slow,
# switch to `rsync -a --ignore-existing` — frozen files never need recopy.
set -euo pipefail

ARCHIVE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$ARCHIVE_DIR")"

copied_any=0

archive_one() {
    local src_claude="$1" label="$2"
    [ -d "$src_claude" ] || return 0

    local dest="$ARCHIVE_DIR/$label"
    local did=0

    if [ -d "$src_claude/projects" ]; then
        mkdir -p "$dest/projects"
        cp -a "$src_claude/projects/." "$dest/projects/"
        did=1
    fi
    # history.jsonl is a symlink to a container-only path in shared-mode
    # state dirs; -f dereferences and skips a dangling link cleanly.
    if [ -f "$src_claude/history.jsonl" ]; then
        mkdir -p "$dest"
        cp -a "$src_claude/history.jsonl" "$dest/history.jsonl"
        did=1
    fi

    if [ "$did" = 1 ]; then
        local n
        n=$(find "$dest/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
        echo "  ${label}: ${n} transcript(s) -> ${dest#$REPO_ROOT/}"
        copied_any=1
    fi
}

echo "Archiving session history into ${ARCHIVE_DIR#$REPO_ROOT/}/ ..."

# Per-instance state dirs (persistent-states/<INSTANCE>/).
for d in "$REPO_ROOT"/persistent-states/*; do
    [ -d "$d" ] || continue
    archive_one "$d/.claude" "$(basename "$d")"
done

# Shared-mode state (one dir, all shared instances write here).
archive_one "$REPO_ROOT/claude-sandbox-shared/.claude" "shared"

if [ "$copied_any" = 0 ]; then
    echo "  nothing found to archive."
fi
echo "Done."
