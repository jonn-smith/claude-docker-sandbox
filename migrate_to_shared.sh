#!/usr/bin/env bash
# migrate_to_shared.sh — populate claude-sandbox-shared/ with a union-merge of
# every existing per-instance Claude state dir. Leaves all existing instance
# dirs UNTOUCHED, so old instances keep working unchanged. Only a brand-new
# instance launched with CLAUDE_SANDBOX_USE_SHARED=1 reads from the shared
# dir; everyone else stays on their own per-instance state.
#
# Strategy: copy "first writer wins" with main going first. No renames, no
# deletes, no in-place modification of existing instance dirs. Idempotent —
# rerun safely; existing files in the shared dir aren't overwritten.
#
# Usage:
#   ./migrate_to_shared.sh            # populate shared dir
#   ./migrate_to_shared.sh --dry-run  # show what it would copy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/claude-sandbox-shared"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# Items to share (everything else stays per-instance):
#
# projects/ and sessions/ deliberately NOT shared. Claude Code keys
# projects/<encoded-cwd>/*.jsonl by container CWD. All instances bind-mount
# to /workspace, so they collapse to the same projects/-workspace/ bucket;
# sharing it makes `--continue` pick the newest JSONL across instances and
# silently resume the wrong session. Keep per-instance.
SHARED_ITEMS=(
  settings.json
  skills
  plugins
  hooks
  plans
  tasks
)

shopt -s nullglob
instances=( "${SCRIPT_DIR}"/claude-sandbox-persistent-state-* )
shopt -u nullglob
if (( ${#instances[@]} == 0 )); then
  echo "no claude-sandbox-persistent-state-* dirs found in ${SCRIPT_DIR}" >&2
  exit 1
fi

# Order: main first, rest alphabetical. Main wins conflicts.
ordered=()
for d in "${instances[@]}"; do
  [[ "$(basename "$d")" == "claude-sandbox-persistent-state-main" ]] && ordered+=("$d")
done
for d in "${instances[@]}"; do
  [[ "$(basename "$d")" == "claude-sandbox-persistent-state-main" ]] && continue
  ordered+=("$d")
done

run() {
  if (( DRY )); then
    printf 'DRY: '; printf '%q ' "$@"; printf '\n'
  else
    "$@"
  fi
}

echo "shared dir: ${SHARED_DIR}"
echo "instances (in merge order):"
for d in "${ordered[@]}"; do echo "  - $(basename "$d")"; done
echo

run mkdir -p "${SHARED_DIR}/.claude"

# .claude.json stays per-instance — it's rewritten whole on every Claude
# change and holds per-project allowedTools/mcpServers/history. Sharing it
# across concurrent instances would race; merging across instances would
# pick a winner and silently drop the others' per-project state. So leave
# each instance's existing .claude.json in place; run_claude_docker.sh
# bootstraps a fresh one for new instances.

# Union-merge each shared item, no-clobber so first wins.
for d in "${ordered[@]}"; do
  echo "merging from $(basename "$d")"
  for item in "${SHARED_ITEMS[@]}"; do
    src="${d}/.claude/${item}"
    dst="${SHARED_DIR}/.claude/${item}"
    [[ -e "$src" ]] || continue
    if [[ -d "$src" ]]; then
      run mkdir -p "$dst"
      # cp -an: archive + no-clobber. Use trailing /. so contents merge.
      run cp -an "${src}/." "${dst}/"
    else
      [[ -e "$dst" ]] || run cp -a "$src" "$dst"
    fi
  done
done

echo
echo "done. existing instance dirs untouched."
echo
echo "next: create an env.<NEW>.sh with"
echo "      export CLAUDE_SANDBOX_INSTANCE=<NEW>"
echo "      export CLAUDE_SANDBOX_USE_SHARED=1"
echo "      then ./run_claude_docker.sh to launch the aggregated sandbox."
echo
echo "rollback: rm -rf ${SHARED_DIR} (only deletes the new shared copy;"
echo "          per-instance dirs are untouched and remain usable)."
