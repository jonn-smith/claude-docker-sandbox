#!/usr/bin/env bash
# caveman-stats-refresh.sh — Stop hook. After each Claude response, compute
# THIS session's estimated caveman token savings and write the pre-rendered
# suffix (.caveman-statusline-suffix) that the statusline badge reads. The
# badge then shows [CAVEMAN ⛏ 2.1M] for the current session only.
#
# Per-session, not lifetime: caveman's own caveman-stats.js aggregates across
# all sessions in .caveman-history, which made the badge a running lifetime
# total. We want the number scoped to the session in front of you, so we
# compute it here from just this session's transcript and skip caveman's
# aggregate writer entirely.
#
# Estimate (there is no real per-session measurement — see the design notes:
# caveman changes model OUTPUT and the un-caveman'd counterfactual is never
# generated):
#     est_saved = sum(assistant output_tokens this session) * ratio
# ratio = 0.65 for full mode (caveman's benchmarked COMPRESSION['full']).
# Other modes have no benchmarked ratio, so no number is shown for them.
#
# Reads the Stop payload on stdin for .transcript_path. Silent + non-
# blocking: any failure exits 0 so a bad poll never interrupts the session.
set -u
CC_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SUFFIX_FILE="$CC_DIR/.caveman-statusline-suffix"

command -v jq >/dev/null 2>&1 || exit 0

payload="$(cat 2>/dev/null)"
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Ratio by mode. Only 'full' (and unset -> full) is benchmarked.
mode=$(head -c 64 "$CC_DIR/.caveman-active" 2>/dev/null | tr -d '\n\r' \
       | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
case "$mode" in
    ""|full) ratio="0.65" ;;
    *)       ratio="" ;;   # no benchmarked ratio -> no number
esac

# Refuse to write through a symlink (same hardening as the flag file).
[ -L "$SUFFIX_FILE" ] && exit 0

if [ -z "$ratio" ]; then
    : > "$SUFFIX_FILE" 2>/dev/null || true   # clear number for unbenchmarked modes
    exit 0
fi

# Sum this session's assistant output tokens, apply ratio, humanize.
out=$(jq -rs '[.[] | .message.usage.output_tokens // empty] | add // 0' "$transcript" 2>/dev/null)
[ -n "$out" ] || exit 0

human=$(awk -v o="$out" -v r="$ratio" 'BEGIN{
    n = o * r;
    if (n>=1e9) printf "%.1fB", n/1e9;
    else if (n>=1e6) printf "%.1fM", n/1e6;
    else if (n>=1e3) printf "%dK", int(n/1e3);
    else printf "%d", n
}' 2>/dev/null)
[ -n "$human" ] || exit 0

# Atomic write via temp + mv so a concurrent statusline read never sees a
# half-written file.
tmp="$SUFFIX_FILE.tmp.$$"
printf '⛏ %s' "$human" > "$tmp" 2>/dev/null && mv -f "$tmp" "$SUFFIX_FILE" 2>/dev/null
rm -f "$tmp" 2>/dev/null
exit 0
