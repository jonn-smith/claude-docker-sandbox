#!/usr/bin/env bash
# caveman-stats-refresh.sh — Stop hook. After each Claude response, run
# caveman-stats.js against the just-finished session so it recomputes the
# estimated tokens saved and rewrites .caveman-statusline-suffix. The
# caveman badge script (caveman-statusline.sh) reads that suffix and
# appends "⛏ 12K" to [CAVEMAN], so the number tracks per-response.
#
# Why a Stop hook: caveman ships caveman-stats.js but wires it only to the
# /caveman-stats slash command, so the suffix never refreshed on its own.
# aggregateHistory keeps only the latest line per session_id, so running
# every Stop is idempotent — the count stays correct, the history file
# just grows one small JSON line per response.
#
# Reads the Stop payload on stdin for .transcript_path (the session JSONL
# caveman-stats should parse). Silent + non-blocking: any failure exits 0
# so a bad poll never interrupts the session.

CC_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

# Extract transcript_path from the Stop hook's stdin JSON.
payload="$(cat 2>/dev/null)"
transcript=""
if command -v jq >/dev/null 2>&1; then
    transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
fi

# Locate caveman-stats.js across the marketplace/cache × pre-1.8/1.8+ paths
# (same probing the statusline wrapper uses for the badge script).
stats_js=""
for c in \
    "$CC_DIR"/plugins/cache/caveman/caveman/*/src/hooks/caveman-stats.js \
    "$CC_DIR"/plugins/cache/caveman/caveman/*/hooks/caveman-stats.js \
    "$CC_DIR"/plugins/marketplaces/caveman/src/hooks/caveman-stats.js \
    "$CC_DIR"/plugins/marketplaces/caveman/hooks/caveman-stats.js ; do
    [ -f "$c" ] && { stats_js="$c"; break; }
done

[ -n "$stats_js" ] || exit 0
command -v node >/dev/null 2>&1 || exit 0

if [ -n "$transcript" ] && [ -f "$transcript" ]; then
    node "$stats_js" --session-file "$transcript" >/dev/null 2>&1 || true
else
    # No transcript in payload — let caveman-stats fall back to the most
    # recent session it can find.
    node "$stats_js" >/dev/null 2>&1 || true
fi
exit 0
