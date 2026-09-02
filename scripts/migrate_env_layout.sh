#!/usr/bin/env bash
# migrate_env_layout.sh — one-shot migration to the envs/ + persistent-states/
# layout. Run from the ROOT of the checkout you want to migrate.
#
#   env.<NAME>.sh                              -> envs/env.<NAME>.sh
#   claude-sandbox-persistent-state-<INSTANCE> -> persistent-states/<INSTANCE>
#   (and patch __ENV_SCRIPT_DIR in each moved env so repo-root resolution
#    still works from one level down)
#
# Dry-run by default — prints what it WOULD do and changes nothing. Pass
# --go to actually move. Idempotent: safe to re-run; already-migrated items
# are skipped.
#
#   scripts/migrate_env_layout.sh          # preview
#   scripts/migrate_env_layout.sh --go     # do it
set -euo pipefail

GO=0
[[ "${1:-}" == "--go" ]] && GO=1
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

say()  { printf '%s\n' "$*"; }
do_or_echo() { if [ "$GO" = 1 ]; then eval "$1"; else say "  would: $1"; fi; }

# git mv when the path is tracked in a git repo, else plain mv. Keeps history
# for the one tracked env file (env.example.sh) without failing on a checkout
# that isn't a git repo or where the file is untracked.
move() {
    local src=$1 dst=$2
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
       && git -C "$ROOT" ls-files --error-unmatch "$src" >/dev/null 2>&1; then
        do_or_echo "git -C '$ROOT' mv '$src' '$dst'"
    else
        do_or_echo "mv '$src' '$dst'"
    fi
}

say "== migrate_env_layout ($([ "$GO" = 1 ] && echo APPLYING || echo dry-run)) =="
say "root: $ROOT"

# 1) env.<NAME>.sh  ->  envs/
say
say "[1] env scripts -> envs/"
shopt -s nullglob
env_files=(env.*.sh)
if [ ${#env_files[@]} -eq 0 ]; then
    say "  none at repo root (already migrated, or none exist)."
else
    do_or_echo "mkdir -p '$ROOT/envs'"
    for f in "${env_files[@]}"; do
        [ -e "$f" ] || continue
        if [ -e "envs/$f" ]; then
            say "  skip $f (envs/$f already exists)"
            continue
        fi
        move "$f" "envs/$f"
    done
fi

# 2) claude-sandbox-persistent-state-<INSTANCE>  ->  persistent-states/<INSTANCE>
say
say "[2] state dirs -> persistent-states/<INSTANCE>"
state_dirs=(claude-sandbox-persistent-state-*)
if [ ${#state_dirs[@]} -eq 0 ]; then
    say "  none at repo root (already migrated, or none exist)."
else
    do_or_echo "mkdir -p '$ROOT/persistent-states'"
    for d in "${state_dirs[@]}"; do
        [ -d "$d" ] || continue
        inst="${d##claude-sandbox-persistent-state-}"
        if [ -e "persistent-states/$inst" ]; then
            # Collision: an instance of the same name already ran in the new
            # layout, so we can't just move the OLD dir over it. Silently
            # skipping (the old behavior) STRANDS the OLD sessions — the
            # launcher only reads persistent-states/, so those transcripts
            # become unresumable. Instead MERGE the OLD projects/ (session
            # transcripts) into the new dir without clobbering anything
            # newer, and leave the OLD dir in place for manual review.
            local_new="persistent-states/$inst"
            n_old=$(find "$d/.claude/projects" -maxdepth 2 -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
            say "  MERGE $d -> $local_new (both exist; ${n_old} old transcript(s))"
            if [ "$GO" = 1 ]; then
                mkdir -p "$local_new/.claude/projects"
                # -n = no-clobber: never overwrite a newer file in the target.
                cp -rn "$d/.claude/projects/." "$local_new/.claude/projects/" 2>/dev/null || true
                say "     merged projects/ (no-clobber). OLD dir left at $d — verify then remove."
            else
                say "     would merge projects/ into $local_new (no-clobber), keep $d"
            fi
            continue
        fi
        move "$d" "persistent-states/$inst"
    done
fi

# 3) Patch __ENV_SCRIPT_DIR in each moved env so repo root resolves as the
#    PARENT of envs/. Only touch the old form; idempotent (skips if already /..).
say
say "[3] patch __ENV_SCRIPT_DIR resolution in envs/*.sh"
old='__ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
new='__ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"'
patched=0 already=0 missing=0
# Look in envs/ if it exists yet (dry-run: it may not, so also peek at root).
scan_dir="envs"; [ -d envs ] || scan_dir="."
for f in "$scan_dir"/env.*.sh; do
    [ -e "$f" ] || continue
    if grep -qF "$new" "$f"; then already=$((already+1)); continue; fi
    if grep -qF "$old" "$f"; then
        if [ "$GO" = 1 ]; then
            # exact literal replace via a temp file (no sed escaping headaches)
            python3 - "$f" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
open(p, "w").write(s.replace(old, new, 1))
PY
        fi
        patched=$((patched+1))
        say "  patch: $f"
    else
        missing=$((missing+1))
        say "  NOTE: $f has no standard __ENV_SCRIPT_DIR line — check by hand"
    fi
done
say "  patched=$patched already-ok=$already needs-manual=$missing"

say
if [ "$GO" = 1 ]; then
    say "== done. Verify: source envs/env.<NAME>.sh && echo \$CLAUDE_SANDBOX_PROJECTS_DIR =="
    say "   Then update .gitignore if this checkout tracks env/state patterns."
else
    say "== dry-run only. Re-run with --go to apply. =="
fi
