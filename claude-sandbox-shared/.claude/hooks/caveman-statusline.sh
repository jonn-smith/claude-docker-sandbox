#!/bin/bash
# Composite statusline wrapper for the sandbox.
#
# Renders: `model · effort  [BACKEND]  [PLUGIN_A_BADGE] [PLUGIN_B_BADGE] ...`
# where [BACKEND] is [VERTEX] or [CLAUDE.AI] (see backend-badge section).
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

# --- backend badge ---------------------------------------------------------
# Which backend is ACTIVE — not merely available. The launcher forwards
# ANTHROPIC_TARGET_API_URL whenever it spawned the host vertex_proxy, but
# that only means Vertex is *reachable*. A claude.ai OAuth login (e.g.
# `/login` with an enterprise account) overrides it: Claude Code then
# talks to claude.ai and ignores the proxy. CLAUDE_CODE_USE_VERTEX is read
# host-side only and never reaches the container, so it can't be the signal.
#
# Discriminator:
#   OAuth login active            -> [CLAUDE.AI]  (overrides proxy)
#   else, proxy URL set           -> [VERTEX]
#   else                          -> no badge (plain api.anthropic.com / unset)
#
# OAuth-active = a non-empty ~/.claude/.credentials.json AND oauthAccount
# set in ~/.claude.json. Both are local file reads — no network.
# .credentials.json lives INSIDE the config dir; .claude.json sits one
# level up in $HOME (not inside .claude/).
CC_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CC_JSON="$HOME/.claude.json"
oauth_active=0
if [ -s "$CC_DIR/.credentials.json" ]; then
    if command -v jq >/dev/null 2>&1; then
        [ "$(jq -r '.oauthAccount != null' "$CC_JSON" 2>/dev/null)" = "true" ] \
            && oauth_active=1
    else
        # jq absent: credentials file alone is a good-enough signal.
        oauth_active=1
    fi
fi

# Single trailing space to match the one-space separator between plugin
# badges below (two here left a visible gap before the first plugin).
if [ "$oauth_active" = 1 ]; then
    printf '\033[38;5;208m[CLAUDE.AI]\033[0m '       # orange
elif [ -n "${ANTHROPIC_TARGET_API_URL:-}" ]; then
    printf '\033[38;5;39m[VERTEX]\033[0m '           # blue
fi

# --- headroom badge --------------------------------------------------------
# When the headroom proxy is on (HEADROOM=1), show a green badge with the
# lifetime tokens it has saved: e.g. [HR 612K]. The count comes from
# headroom's /stats (.savings.total_tokens) and refreshes after each
# response (this hook re-runs then).
#
# The statusline can render many times between responses, so a naive curl
# per render would hammer the proxy. Cache the number to a tmp file with a
# short TTL and only re-fetch when stale. If headroom is unreachable, fall
# back to the last cached value, else a bare [HR] so the badge never blanks
# mid-session on one slow poll.
if [ "${HEADROOM:-0}" = "1" ]; then
    hr_port="${HEADROOM_PORT:-8787}"
    hr_cache="${TMPDIR:-/tmp}/hr-statusline-saved"
    hr_ttl=2
    hr_saved=""

    # Use cache if fresh (mtime within TTL). stat -c works on the Linux
    # container; guard it so a missing stat never aborts the statusline.
    if [ -f "$hr_cache" ]; then
        now=$(date +%s 2>/dev/null || echo 0)
        mtime=$(stat -c %Y "$hr_cache" 2>/dev/null || echo 0)
        if [ "$now" -gt 0 ] && [ $((now - mtime)) -lt "$hr_ttl" ]; then
            hr_saved=$(cat "$hr_cache" 2>/dev/null)
        fi
    fi

    if [ -z "$hr_saved" ] && command -v jq >/dev/null 2>&1; then
        hr_saved=$(curl -sf --max-time 0.5 "http://127.0.0.1:${hr_port}/stats" 2>/dev/null \
                   | jq -r '.savings.total_tokens // empty' 2>/dev/null)
        [ -n "$hr_saved" ] && printf '%s' "$hr_saved" > "$hr_cache" 2>/dev/null
    fi
    # Last-resort fallback to a stale cache so the number doesn't vanish.
    [ -z "$hr_saved" ] && [ -f "$hr_cache" ] && hr_saved=$(cat "$hr_cache" 2>/dev/null)

    # Human-readable: 612434 -> 612K, 1500000 -> 1.5M.
    hr_human=""
    if [ -n "$hr_saved" ] && [ "$hr_saved" -eq "$hr_saved" ] 2>/dev/null; then
        hr_human=$(awk -v n="$hr_saved" 'BEGIN{
            if (n>=1e9) printf "%.1fB", n/1e9;
            else if (n>=1e6) printf "%.1fM", n/1e6;
            else if (n>=1e3) printf "%dK", int(n/1e3);
            else printf "%d", n
        }' 2>/dev/null)
    fi

    if [ -n "$hr_human" ]; then
        printf '\033[38;5;42m[HR %s]\033[0m ' "$hr_human"   # green
    else
        printf '\033[38;5;42m[HR]\033[0m '
    fi
fi

# --- plugin badges ---------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"

# Probe the VENDORED marketplace copy before the runtime cache. The cache
# can hold an older caveman version than the pinned/vendored tree — its
# badge script predated the savings-suffix feature, so a cache-first order
# silently dropped the "⛏ 6M" suffix. Marketplace is the pinned source of
# truth; prefer it.
for plugin in "${STATUSLINE_PLUGINS[@]}"; do
    for candidate in \
        "$PLUGIN_ROOT"/marketplaces/"$plugin"/src/hooks/"$plugin"-statusline.sh \
        "$PLUGIN_ROOT"/marketplaces/"$plugin"/hooks/"$plugin"-statusline.sh \
        "$PLUGIN_ROOT"/cache/"$plugin"/"$plugin"/*/src/hooks/"$plugin"-statusline.sh \
        "$PLUGIN_ROOT"/cache/"$plugin"/"$plugin"/*/hooks/"$plugin"-statusline.sh ; do
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
