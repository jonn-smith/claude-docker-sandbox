#!/bin/bash
# Composite statusline wrapper for the sandbox.
#
# Renders: `model · effort  [PLUGIN_A_BADGE] [PLUGIN_B_BADGE] ...`
#
# claude-code's settings.json accepts exactly ONE statusLine.command, so
# every segment concatenates through this single script. Filename kept as
# caveman-statusline.sh for backward compatibility with the settings
# entry — despite the name, it now composes badges from any listed
# plugin, not just caveman.
#
# Adding a new plugin badge: append the plugin name to STATUSLINE_PLUGINS
# below. The wrapper discovers <name>-statusline.sh under any of the
# canonical locations Claude Code's plugin loader may use:
#   plugins/marketplaces/<name>/{,src/}hooks/<name>-statusline.sh
#   plugins/cache/<name>/<name>/*/{,src/}hooks/<name>-statusline.sh
# A missing badge is silently skipped — better no output than a hard
# error.
#
# Order in STATUSLINE_PLUGINS controls display order left-to-right.

STATUSLINE_PLUGINS=(caveman ponytail)

# --- buffer stdin ----------------------------------------------------------
# claude-code pipes the session JSON to statusline commands on stdin. Read
# it once here so every badge script sees the same input via here-string.
STATUSLINE_INPUT="$(cat)"

# --- model + effort segment ------------------------------------------------
MODEL=""
if [ -n "$STATUSLINE_INPUT" ] && command -v jq >/dev/null 2>&1; then
    # Try display_name first (human-friendly), fall back to id.
    MODEL=$(printf '%s' "$STATUSLINE_INPUT" \
        | jq -r '.model.display_name // .model.id // empty' 2>/dev/null)
fi

# Effort comes from CLAUDE_EFFORT env (set by the launcher / env.*.sh); if
# unset, we don't invent a value — better to omit the segment than to lie.
EFFORT="${CLAUDE_EFFORT:-}"

# Dim gray so this segment sits back visually and lets the badges pop.
DIM=$'\033[38;5;244m'
RST=$'\033[0m'

if [ -n "$MODEL" ] && [ -n "$EFFORT" ]; then
    printf '%s%s · %s%s  ' "$DIM" "$MODEL" "$EFFORT" "$RST"
elif [ -n "$MODEL" ]; then
    printf '%s%s%s  ' "$DIM" "$MODEL" "$RST"
elif [ -n "$EFFORT" ]; then
    printf '%seffort:%s%s  ' "$DIM" "$EFFORT" "$RST"
fi

# --- plugin badges ---------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"

for plugin in "${STATUSLINE_PLUGINS[@]}"; do
    for candidate in \
        "$PLUGIN_ROOT"/cache/"$plugin"/"$plugin"/*/src/hooks/"$plugin"-statusline.sh \
        "$PLUGIN_ROOT"/cache/"$plugin"/"$plugin"/*/hooks/"$plugin"-statusline.sh \
        "$PLUGIN_ROOT"/marketplaces/"$plugin"/src/hooks/"$plugin"-statusline.sh \
        "$PLUGIN_ROOT"/marketplaces/"$plugin"/hooks/"$plugin"-statusline.sh ; do
        # -f (regular file) not -x — some vendored trees ship without the
        # exec bit (ponytail's tarball did), but `bash <path>` runs it
        # regardless.
        if [ -f "$candidate" ]; then
            bash "$candidate" "$@" <<<"$STATUSLINE_INPUT"
            printf ' '  # separator between plugin badges
            break
        fi
    done
done
exit 0
