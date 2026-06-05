#!/usr/bin/env bash
# SessionStart hook: auto-index workdir on first Claude session.
#
# Decision tree:
#   - Not a git repo at /workspace  → exit (don't index data dirs).
#   - /workspace/.codegraph-disable → exit (explicit per-workdir opt-out).
#   - .codegraph/init-complete present → exit (DB is fully populated; the
#     watcher inside `codegraph serve --mcp` keeps it current).
#   - codegraph binary missing      → exit (image wasn't rebuilt yet).
#   - Otherwise: spawn `codegraph init -i` detached in the background under
#     a flock so a second concurrent session can't start a duplicate
#     indexer. The sentinel is written ONLY when init exits 0 — a SIGKILL'd
#     init leaves a partial DB but no sentinel, so the next session retries
#     cleanly rather than serving incomplete results forever.
#
# We DO NOT gate on codegraph.db existence anymore: SQLite creates the file
# during init, so a half-finished run leaves a present-but-partial DB.
# Sentinel-based gating is the only safe signal.
set -eu

WS=/workspace
CG_DIR="$WS/.codegraph"
DB="$CG_DIR/codegraph.db"
SENTINEL="$CG_DIR/init-complete"
LOCK="$CG_DIR/init.lock"
LOG="$CG_DIR/init.log"

[ -d "$WS/.git" ] || exit 0
[ -f "$WS/.codegraph-disable" ] && exit 0
[ -f "$SENTINEL" ] && exit 0
command -v codegraph >/dev/null 2>&1 || exit 0

mkdir -p "$CG_DIR"

# Background indexer. Runs detached so SessionStart returns immediately.
# Layout:
#   - flock on $LOCK (non-blocking, exit 1 if held) prevents a second
#     concurrent session from kicking off a duplicate init.
#   - Sentinel written only on success — interrupt/crash leaves no sentinel
#     so the next session retries.
#   - All output → $LOG.
#   - setsid + nohup so a SIGINT to claude doesn't propagate.
(
    setsid nohup bash -c '
        WS=/workspace
        CG_DIR="$WS/.codegraph"
        LOCK="$CG_DIR/init.lock"
        SENTINEL="$CG_DIR/init-complete"
        LOG="$CG_DIR/init.log"
        exec >>"$LOG" 2>&1
        printf "\n--- codegraph init started: %s ---\n" "$(date -u +%FT%TZ)"
        # Non-blocking lock. fd 9 → LOCK. If another session is already
        # holding it, exit silently — that init will finish and write the
        # sentinel for us.
        exec 9>"$LOCK"
        if ! flock -n 9; then
            echo "another codegraph init is already running; deferring."
            exit 0
        fi
        cd "$WS"
        if codegraph init -i; then
            : > "$SENTINEL"
            printf -- "--- codegraph init complete: %s ---\n" "$(date -u +%FT%TZ)"
        else
            rc=$?
            printf -- "--- codegraph init FAILED (rc=%d): %s ---\n" "$rc" "$(date -u +%FT%TZ)"
            exit "$rc"
        fi
    ' </dev/null &
) >/dev/null 2>&1

# If a DB exists but no sentinel, we're recovering from a prior crash —
# tell the user the index is being rebuilt so they don't wonder why query
# results look thin until init finishes.
if [ -f "$DB" ] && [ ! -f "$SENTINEL" ]; then
    printf 'codegraph: re-indexing (prior init never finished; tail %s)\n' "$LOG" >&2
else
    printf 'codegraph: background indexing started (tail %s)\n' "$LOG" >&2
fi
