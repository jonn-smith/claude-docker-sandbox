#!/usr/bin/env bash
# Idempotently merge new entries from the tracked shared settings.json into
# any settings.json files lying around on this host. Intended for one-shot
# use after pulling a change to the tracked file — e.g., on a deployment
# that has its own pre-tracking copies under
# claude-sandbox-persistent-state-*/.claude/settings.json that won't update
# themselves.
#
# What it does:
#  - For each target settings.json:
#    - Back up to .bak.<timestamp>.
#    - Use jq to ensure hooks.SessionStart contains a codegraph-init.sh entry.
#    - Leave every other field untouched. Re-running is a no-op.
#
# What it does NOT do:
#  - Overwrite the file with the tracked default. Local customizations
#    (custom hooks, plugins, theme, effortLevel, etc.) are preserved.
#  - Touch the shared settings.json itself unless you pass --include-shared.
#    The shared file is already correct in this repo.
#
# Usage:
#   ./scripts/patch_settings_json.sh                # patch all per-instance
#   ./scripts/patch_settings_json.sh --include-shared
#   ./scripts/patch_settings_json.sh path/to/settings.json [...]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v jq >/dev/null 2>&1 || { echo "jq required" >&2; exit 1; }

INCLUDE_SHARED=0
EXPLICIT_FILES=()
for arg in "$@"; do
    case "$arg" in
        --include-shared) INCLUDE_SHARED=1 ;;
        -h|--help)
            sed -n '2,/^set -/p' "$0" | sed '$d'; exit 0 ;;
        *) EXPLICIT_FILES+=("$arg") ;;
    esac
done

# Resolve target list.
if [ ${#EXPLICIT_FILES[@]} -gt 0 ]; then
    TARGETS=("${EXPLICIT_FILES[@]}")
else
    TARGETS=()
    shopt -s nullglob
    for f in "$REPO_ROOT"/claude-sandbox-persistent-state-*/.claude/settings.json; do
        TARGETS+=("$f")
    done
    if [ "$INCLUDE_SHARED" = 1 ]; then
        SHARED="$REPO_ROOT/claude-sandbox-shared/.claude/settings.json"
        [ -f "$SHARED" ] && TARGETS+=("$SHARED")
    fi
    shopt -u nullglob
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
    echo "No settings.json files found. Nothing to do."
    exit 0
fi

# Single source of truth for the merger: just add the SessionStart codegraph
# entry if it's not already present. Idempotent.
CODEGRAPH_HOOK='{ hooks: [ { type: "command", command: "~/.claude/hooks/codegraph-init.sh" } ] }'

JQ_PATCH='
  # Ensure .hooks is an object.
  .hooks = (.hooks // {}) |
  # Ensure .hooks.SessionStart is an array.
  .hooks.SessionStart = (.hooks.SessionStart // []) |
  # Append the codegraph entry only if no SessionStart hook already points
  # to codegraph-init.sh. Two-arg any() so we pick the generator explicitly;
  # the one-arg form defaults to .[] which would iterate top-level settings
  # values (including booleans like skipDangerousModePermissionPrompt) and
  # blow up on .hooks lookup against them.
  if any(
       .hooks.SessionStart[]? | (.hooks // [])[]? ;
       (.command? // "") | test("codegraph-init\\.sh$")
     )
  then .
  else .hooks.SessionStart += [ '"$CODEGRAPH_HOOK"' ]
  end
'

TS=$(date -u +%Y%m%dT%H%M%SZ)
patched=0
skipped=0
for f in "${TARGETS[@]}"; do
    if [ ! -f "$f" ]; then
        echo "  MISS  $f (no such file)"
        continue
    fi
    before=$(jq -S . "$f" 2>/dev/null || echo "")
    if [ -z "$before" ]; then
        echo "  ERR   $f (invalid JSON, skipping)"
        continue
    fi
    after=$(jq -S "$JQ_PATCH" "$f")
    if [ "$before" = "$after" ]; then
        echo "  OK    $f (already has codegraph hook)"
        skipped=$((skipped + 1))
        continue
    fi
    cp -a "$f" "$f.bak.$TS"
    printf '%s\n' "$after" > "$f"
    echo "  ADD   $f  (backup: $f.bak.$TS)"
    patched=$((patched + 1))
done

echo
echo "Patched: $patched   Already current: $skipped"
