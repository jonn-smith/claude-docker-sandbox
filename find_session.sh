#!/usr/bin/env bash
# find_session.sh — locate a Claude Code session across every state-dir
# layout and print what you need to resume it. Sessions are host-local
# files; --resume takes the session ID (uuid), never the -n display name,
# so this maps a name (or any substring) back to uuid(s).
#
#   ./find_session.sh <name-or-substring>     # search by customTitle / content
#   ./find_session.sh --all                   # list every session everywhere
#
# Searches:
#   persistent-states/<INSTANCE>/.claude/projects/        (current layout)
#   claude-sandbox-persistent-state-<INSTANCE>/.claude/…  (pre-refactor layout)
#   claude-sandbox-shared/.claude/projects/               (shared mode)
#
# Not `set -e`: the scan runs many greps in $() that return non-zero on a
# per-file miss (no customTitle, no timestamp) — under -e that aborts the
# whole search silently. A miss should just skip the file.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEEDLE="${1:-}"
if [[ -z "$NEEDLE" ]]; then
  echo "usage: $(basename "$0") <session-name-or-substring> | --all" >&2
  exit 2
fi
[[ "$NEEDLE" == "--all" ]] && NEEDLE=""

# Emit "layout<TAB>source<TAB>statedir" for each state dir that exists.
state_dirs() {
  local d
  for d in "$ROOT"/persistent-states/*/.claude/projects; do
    [ -d "$d" ] || continue
    printf 'current\t%s\t%s\n' "$(basename "$(dirname "$(dirname "$d")")")" "$d"
  done
  for d in "$ROOT"/claude-sandbox-persistent-state-*/.claude/projects; do
    [ -d "$d" ] || continue
    printf 'OLD\t%s\t%s\n' "$(basename "$(dirname "$(dirname "$d")")" | sed 's/^claude-sandbox-persistent-state-//')" "$d"
  done
  [ -d "$ROOT/claude-sandbox-shared/.claude/projects" ] \
    && printf 'shared\t%s\t%s\n' "shared" "$ROOT/claude-sandbox-shared/.claude/projects"
}

# Pull first title / first+last timestamp from a transcript without jq.
field() { grep -m1 -o "\"$1\":\"[^\"]*\"" "$2" 2>/dev/null | head -1 | sed "s/\"$1\":\"//;s/\"$//"; }

hits=0 old_hit=0
printf '%-8s %-18s %-10s %-10s %8s  %-26s %s\n' LAYOUT INSTANCE FIRST LAST SIZE TITLE SESSION-ID
printf '%.0s-' {1..110}; echo

while IFS=$'\t' read -r layout source dir; do
  [ -n "$dir" ] || continue
  # Transcripts live at projects/<encoded-cwd>/<uuid>.jsonl (depth 2), not
  # directly under projects/. -maxdepth 2 keeps us to real session files and
  # skips the deeper <uuid>/ sidecar dirs.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    local_title="$(field customTitle "$f")"
    # Match on title OR anywhere in the file (covers unnamed sessions).
    if [[ -n "$NEEDLE" ]]; then
      if [[ "$local_title" != *"$NEEDLE"* ]] && ! grep -qF "$NEEDLE" "$f" 2>/dev/null; then
        continue
      fi
    fi
    first="$(field timestamp "$f" | cut -c1-10)"
    last="$(grep -o '"timestamp":"[0-9-]\{10\}' "$f" 2>/dev/null | tail -1 | grep -o '[0-9-]\{10\}$')"
    size="$(du -h "$f" 2>/dev/null | cut -f1)"
    uuid="$(basename "$f" .jsonl)"
    disp_title="${local_title:-—}"
    printf '%-8s %-18s %-10s %-10s %8s  %-26s %s\n' \
      "$layout" "${source:0:18}" "${first:-?}" "${last:-?}" "${size:-?}" "${disp_title:0:26}" "$uuid"
    hits=$((hits+1))
    [[ "$layout" == "OLD" ]] && old_hit=1
  done < <(find "$dir" -maxdepth 2 -name '*.jsonl' 2>/dev/null)
done < <(state_dirs)

echo
if [[ "$hits" -eq 0 ]]; then
  echo "No session matching '${NEEDLE}' on this machine."
  echo "Sessions are host-local — if it ran elsewhere, search there."
  exit 1
fi

echo "Resume: source the env for that INSTANCE, then:"
echo "    ./run_claude_docker.sh --resume <SESSION-ID>"
echo "(pick the SESSION-ID column; --resume needs the id, not the name.)"
if [[ "$old_hit" -eq 1 ]]; then
  echo
  echo "NOTE: rows marked OLD are in the pre-refactor layout"
  echo "(claude-sandbox-persistent-state-<inst>/). The launcher now looks in"
  echo "persistent-states/<inst>/, so migrate first or it won't be found:"
  echo "    ./migrate_env_layout.sh --go     # moves OLD dirs -> persistent-states/"
  echo "then resume with CLAUDE_SANDBOX_INSTANCE set to that instance."
fi
