#!/bin/bash
# Wrapper for the sandbox statusline.
#
# Prints a compact `model · effort` segment first, then defers to caveman's
# own badge script. Result: `claude-fable-5 · xhigh  [CAVEMAN]` on one line.
#
# Why one wrapper instead of two statusline entries: claude-code's
# settings.json supports exactly ONE `statusLine.command`. All segments
# have to concatenate their output through a single script.
#
# The caveman badge script itself lives at one of two paths inside the
# plugin install, depending on what claude-code's plugin loader did:
#
#   plugins/marketplaces/caveman/hooks/caveman-statusline.sh
#       — the raw git clone of the marketplace repo. Stable name.
#   plugins/cache/caveman/caveman/<git-sha>/hooks/caveman-statusline.sh
#       — the per-commit cache. SHA in the path changes on every pin bump.
#
# We probe both cache and marketplace, both pre-1.8 (hooks/) and 1.8+
# (src/hooks/) layouts, and exit 0 silently if none exist — no statusline
# is better than a hard error.

# --- model + effort segment ------------------------------------------------
# claude-code pipes the session JSON to statusline commands on stdin. We
# read it once here, extract the model display name, and hand the buffered
# copy to caveman via a here-string so both scripts see the same input.
STATUSLINE_INPUT="$(cat)"

MODEL=""
if [ -n "$STATUSLINE_INPUT" ] && command -v jq >/dev/null 2>&1; then
    # Try display_name first (human-friendly), fall back to id.
    MODEL=$(printf '%s' "$STATUSLINE_INPUT" \
        | jq -r '.model.display_name // .model.id // empty' 2>/dev/null)
fi

# Effort comes from CLAUDE_EFFORT env (set by the launcher / env.*.sh); if
# unset, we don't invent a value — better to omit the segment than to lie.
EFFORT="${CLAUDE_EFFORT:-}"

# Dim gray so the segment sits back visually and lets caveman's orange pop.
DIM=$'\033[38;5;244m'
RST=$'\033[0m'

if [ -n "$MODEL" ] && [ -n "$EFFORT" ]; then
    printf '%s%s · %s%s  ' "$DIM" "$MODEL" "$EFFORT" "$RST"
elif [ -n "$MODEL" ]; then
    printf '%s%s%s  ' "$DIM" "$MODEL" "$RST"
elif [ -n "$EFFORT" ]; then
    printf '%seffort:%s%s  ' "$DIM" "$EFFORT" "$RST"
fi

# --- caveman badge ---------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"

for candidate in \
    "$PLUGIN_ROOT"/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh \
    "$PLUGIN_ROOT"/cache/caveman/caveman/*/hooks/caveman-statusline.sh \
    "$PLUGIN_ROOT"/marketplaces/caveman/src/hooks/caveman-statusline.sh \
    "$PLUGIN_ROOT"/marketplaces/caveman/hooks/caveman-statusline.sh ; do
    if [ -x "$candidate" ]; then
        bash "$candidate" "$@" <<<"$STATUSLINE_INPUT"
        exit $?
    fi
done
exit 0
