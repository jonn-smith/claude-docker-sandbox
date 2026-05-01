#!/usr/bin/env bash
# migrate_to_shared.sh — one-shot migration of per-instance Claude state into
# a single shared dir, leaving write-hot state per-instance.
#
# Strategy: union-merge the shared subset from every existing instance into
# claude-sandbox-shared/, "first writer wins" with main going first. Then
# rename the per-instance copies to *.preshared.bak so the move is reversible.
#
# Usage:
#   ./migrate_to_shared.sh            # do it
#   ./migrate_to_shared.sh --dry-run  # show what it would do
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED_DIR="${SCRIPT_DIR}/claude-sandbox-shared"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

# Items to share (everything else stays per-instance):
SHARED_ITEMS=(
  settings.json
  skills
  plugins
  hooks
  plans
  tasks
  projects
  sessions
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

# Bring .claude.json from the first instance that has one, no clobber.
if [[ ! -e "${SHARED_DIR}/.claude.json" ]]; then
  for d in "${ordered[@]}"; do
    src="${d}/.claude.json"
    if [[ -f "$src" ]]; then
      echo "copy .claude.json from $(basename "$d")"
      run cp -a "$src" "${SHARED_DIR}/.claude.json"
      break
    fi
  done
fi
if [[ ! -e "${SHARED_DIR}/.claude.json" ]]; then
  echo "seed empty .claude.json"
  run bash -c "echo '{}' > '${SHARED_DIR}/.claude.json'"
fi

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

# Move per-instance copies aside so launches start using the shared bind.
echo
echo "renaming per-instance copies to *.preshared.bak"
for d in "${ordered[@]}"; do
  for item in "${SHARED_ITEMS[@]}"; do
    src="${d}/.claude/${item}"
    [[ -e "$src" ]] || continue
    bak="${src}.preshared.bak"
    if [[ -e "$bak" ]]; then
      echo "  skip ${src} ($(basename "$bak") exists)"
      continue
    fi
    echo "  mv ${src} -> ${bak}"
    run mv "$src" "$bak"
  done
  src="${d}/.claude.json"
  bak="${src}.preshared.bak"
  if [[ -f "$src" && ! -e "$bak" ]]; then
    echo "  mv ${src} -> ${bak}"
    run mv "$src" "$bak"
  fi
done

echo
echo "done."
echo "next: launch a sandbox; verify skills/plugins/sessions show up."
echo "rollback: for each *.preshared.bak, mv it back over the shared copy."
