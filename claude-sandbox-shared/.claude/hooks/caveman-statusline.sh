#!/bin/bash
# Wrapper for caveman's statusline badge.
#
# Why a wrapper instead of pointing settings.json at the script directly:
# the canonical caveman statusline script lives at one of two paths inside
# the plugin install, depending on what claude-code's plugin loader did:
#
#   plugins/marketplaces/caveman/hooks/caveman-statusline.sh
#       — the raw git clone of the marketplace repo. Stable name.
#   plugins/cache/caveman/caveman/<git-sha>/hooks/caveman-statusline.sh
#       — the per-commit cache. SHA in the path changes on every pin bump.
#
# Hardcoding the cache path with a specific SHA would break every time we
# bump the caveman ref in settings.json. Hardcoding the marketplace path
# is stable across pin bumps but assumes claude-code's plugin layout
# doesn't change. This wrapper tries cache first (what claude-code
# actually executes), then marketplace, then exits 0 silently — no
# statusline is better than a hard error.

PLUGIN_ROOT="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins"

# Upstream caveman has shipped two on-disk layouts over the v1.x line:
#   1. <root>/hooks/caveman-statusline.sh           (pre-1.8 layout)
#   2. <root>/src/hooks/caveman-statusline.sh       (current — 1.8+)
# claude-code's cache dir mirrors whichever layout the source was
# published in, so we probe both forms at the cache/<sha>/ path AND at
# the vendored marketplaces/ path.
for candidate in \
    "$PLUGIN_ROOT"/cache/caveman/caveman/*/src/hooks/caveman-statusline.sh \
    "$PLUGIN_ROOT"/cache/caveman/caveman/*/hooks/caveman-statusline.sh \
    "$PLUGIN_ROOT"/marketplaces/caveman/src/hooks/caveman-statusline.sh \
    "$PLUGIN_ROOT"/marketplaces/caveman/hooks/caveman-statusline.sh ; do
    if [ -x "$candidate" ]; then
        exec bash "$candidate" "$@"
    fi
done
exit 0
