#!/usr/bin/env bash
# split_env.sh — break a "pool" env (one env script listing many workspaces
# via stacked CLAUDE_SANDBOX_PROJECTS_DIR lines) into one env per workspace,
# each with its own instance name = the workspace basename.
#
#   scripts/split_env.sh <pool>            # dry-run: show the envs it would create
#   scripts/split_env.sh <pool> --go       # write them
#
# For every CLAUDE_SANDBOX_PROJECTS_DIR value in envs/env.<pool>.sh (active
# OR commented — every workspace the pool ever pointed at), it generates
# envs/env.<basename>.sh: a copy of the pool env with
#   CLAUDE_SANDBOX_INSTANCE = <basename>
#   exactly one active CLAUDE_SANDBOX_PROJECTS_DIR = that path
# and all the pool's other settings (USE_SHARED, HEADROOM, FISS, notify…)
# carried over. Existing env files are never overwritten (skipped).
#
# Does NOT touch sessions or the pool env itself. Moving a workspace's
# existing sessions from persistent-states/<pool>/ into
# persistent-states/<basename>/ is separate (titles are task names, not
# workspace names, so that can't be auto-attributed) — use find_session.sh
# + a manual copy for the ones you care about.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

POOL="${1:-}"
GO=0; [[ "${2:-}" == "--go" ]] && GO=1
[ -n "$POOL" ] || { echo "usage: $(basename "$0") <pool-instance> [--go]" >&2; exit 2; }
POOL_ENV="$ROOT/envs/env.${POOL}.sh"
[ -f "$POOL_ENV" ] || { echo "no such env: envs/env.${POOL}.sh" >&2; exit 1; }

# Collect every PROJECTS_DIR value (strip leading '#', 'export', quotes).
mapfile -t paths < <(
  sed -nE 's/^[[:space:]]*#?[[:space:]]*export[[:space:]]+CLAUDE_SANDBOX_PROJECTS_DIR=(.*)$/\1/p' "$POOL_ENV" \
  | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' \
  | awk 'NF' | awk '!seen[$0]++'
)
[ "${#paths[@]}" -gt 0 ] || { echo "no CLAUDE_SANDBOX_PROJECTS_DIR entries in $POOL_ENV" >&2; exit 1; }

echo "Splitting envs/env.${POOL}.sh -> one env per workspace ($([ "$GO" = 1 ] && echo WRITING || echo dry-run)):"
made=0 skipped=0
for p in "${paths[@]}"; do
  inst="$(basename "$p")"
  # sanitize instance name to [A-Za-z0-9_-]
  inst_safe="$(printf '%s' "$inst" | tr -c 'A-Za-z0-9_-' '_')"
  out="$ROOT/envs/env.${inst_safe}.sh"
  if [ "$inst_safe" = "$POOL" ]; then
    echo "  skip $inst_safe (same name as the pool)"; continue
  fi
  if [ -e "$out" ]; then
    echo "  skip $inst_safe (envs/env.${inst_safe}.sh exists)"; skipped=$((skipped+1)); continue
  fi
  echo "  env.${inst_safe}.sh   PROJECTS_DIR=$p"
  if [ "$GO" = 1 ]; then
    # Copy the pool env, retarget instance, comment out every PROJECTS_DIR,
    # then add exactly one active line. Insert it before the trailing unset.
    sed -E \
      -e "s|^export CLAUDE_SANDBOX_INSTANCE=.*|export CLAUDE_SANDBOX_INSTANCE=${inst_safe}|" \
      -e 's|^export CLAUDE_SANDBOX_PROJECTS_DIR=|#export CLAUDE_SANDBOX_PROJECTS_DIR=|' \
      "$POOL_ENV" > "$out"
    # add the single active PROJECTS_DIR just before `unset __ENV_SCRIPT_DIR`
    # (or at EOF if that marker is absent).
    if grep -q '^unset __ENV_SCRIPT_DIR' "$out"; then
      awk -v line="export CLAUDE_SANDBOX_PROJECTS_DIR=$p" '
        /^unset __ENV_SCRIPT_DIR/ && !done { print line "\n"; done=1 } { print }
      ' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    else
      printf 'export CLAUDE_SANDBOX_PROJECTS_DIR=%s\n' "$p" >> "$out"
    fi
    chmod +x "$out"
  fi
  made=$((made+1))
done

echo
echo "$([ "$GO" = 1 ] && echo Created || echo Would create) ${made} env(s); ${skipped} skipped (already exist)."
if [ "$GO" != 1 ]; then
  echo "Re-run with --go to write them. The pool env and all sessions are left untouched."
else
  echo "Next: move each workspace's sessions from persistent-states/${POOL}/ into"
  echo "persistent-states/<name>/ as needed (scripts/find_session.sh to locate)."
fi
