#!/usr/bin/env bash
# resume_session.sh — resume a Claude session by NAME instead of uuid.
#
# claude --resume takes a session ID, not the -n display name. This looks
# the name up across all state-dir layouts, resolves it to (instance, uuid),
# sources that instance's env, and launches run_claude_docker.sh --resume.
#
#   scripts/resume_session.sh <name> [extra claude args...]
#   scripts/resume_session.sh <name> --latest     # if the name is ambiguous, take newest
#
# Exact customTitle match wins; if none, falls back to substring. Ambiguous
# matches are listed and it bails (pass the uuid or --latest).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: $(basename "$0") <session-name> [claude args]" >&2; exit 2; }
shift
LATEST=0
args=()
for a in "$@"; do [ "$a" = "--latest" ] && LATEST=1 || args+=("$a"); done

field() { grep -m1 -o "\"$1\":\"[^\"]*\"" "$2" 2>/dev/null | head -1 | sed "s/\"$1\":\"//;s/\"$//"; }

# Emit "layout<TAB>instance<TAB>uuid<TAB>lastdate<TAB>title" for every session.
scan() {
  local d f layout inst title last
  for d in "$ROOT"/persistent-states/*/.claude/projects \
           "$ROOT"/claude-sandbox-persistent-state-*/.claude/projects \
           "$ROOT"/claude-sandbox-shared/.claude/projects; do
    [ -d "$d" ] || continue
    case "$d" in
      *"/persistent-states/"*) layout=current; inst=$(basename "$(dirname "$(dirname "$d")")") ;;
      *"/claude-sandbox-shared/"*) layout=shared; inst=shared ;;
      *) layout=OLD; inst=$(basename "$(dirname "$(dirname "$d")")" | sed 's/^claude-sandbox-persistent-state-//') ;;
    esac
    while IFS= read -r f; do
      title=$(field customTitle "$f")
      last=$(grep -o '"timestamp":"[0-9-]\{10\}' "$f" 2>/dev/null | tail -1 | grep -o '[0-9-]\{10\}$')
      printf '%s\t%s\t%s\t%s\t%s\n' "$layout" "$inst" "$(basename "$f" .jsonl)" "${last:-0000-00-00}" "$title"
    done < <(find "$d" -maxdepth 2 -name '*.jsonl' 2>/dev/null)
  done
}

all="$(scan)"
# Exact title match, else substring on title.
matches="$(printf '%s\n' "$all" | awk -F'\t' -v n="$NAME" '$5==n')"
[ -n "$matches" ] || matches="$(printf '%s\n' "$all" | awk -F'\t' -v n="$NAME" 'index($5,n)>0')"

n=$(printf '%s\n' "$matches" | grep -c . || true)
if [ "$n" -eq 0 ]; then
  echo "No session named '$NAME'. Try: scripts/find_session.sh '$NAME'" >&2
  exit 1
fi
if [ "$n" -gt 1 ]; then
  if [ "$LATEST" = 1 ]; then
    matches="$(printf '%s\n' "$matches" | sort -t$'\t' -k4,4r | head -1)"
  else
    echo "Ambiguous — '$NAME' matches $n sessions:" >&2
    printf '%s\n' "$matches" | awk -F'\t' '{printf "  %-8s %-16s %s  %s  %s\n",$1,$2,$4,$3,$5}' >&2
    echo "Re-run with --latest, a more specific name, or resume the uuid directly." >&2
    exit 1
  fi
fi

IFS=$'\t' read -r layout inst uuid last title <<<"$matches"
echo "resume: $title  (instance=$inst, layout=$layout, last=$last)"
echo "        session $uuid"

if [ "$layout" = "OLD" ]; then
  echo "This session is in the pre-refactor layout and the launcher won't see it." >&2
  echo "Migrate/merge it first:  scripts/migrate_env_layout.sh --go" >&2
  exit 1
fi
if [ "$layout" = "shared" ]; then
  echo "Note: shared-layout session — resuming under the currently-sourced env's instance." >&2
fi

# Source the instance env so run_claude_docker has PROJECTS_DIR/CONTEXT_DIR/etc.
envfile="$ROOT/envs/env.${inst}.sh"
if [ "$layout" = current ]; then
  if [ -f "$envfile" ]; then
    # shellcheck disable=SC1090
    source "$envfile"
  elif [ -z "${CLAUDE_SANDBOX_INSTANCE:-}" ]; then
    echo "No env for instance '$inst' at envs/env.${inst}.sh, and none sourced." >&2
    echo "Create it (cp envs/env.example.sh envs/env.${inst}.sh; set CLAUDE_SANDBOX_INSTANCE=$inst)" >&2
    echo "or source your env first, then re-run." >&2
    exit 1
  fi
fi

cd "$ROOT"
exec ./run_claude_docker.sh --resume "$uuid" ${args[@]+"${args[@]}"}
