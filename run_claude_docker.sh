#!/usr/bin/env bash
set -euo pipefail

# Here we set our directories and credentials so we can authenticate and have
# a proper sandbox.  It's VERY important that we don't let these agents run
# freely around our machine.
if [[ ! -v CLAUDE_SANDBOX_PROJECTS_DIR ]] || [[ -z "$CLAUDE_SANDBOX_PROJECTS_DIR" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_PROJECTS_DIR is not set or is empty." >&2
    echo "                You must set this env var before starting the docker image." >&2
    exit 1
fi

if [[ ! -v CLAUDE_SANDBOX_CONTEXT_DIR ]] || [[ -z "$CLAUDE_SANDBOX_CONTEXT_DIR" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_CONTEXT_DIR is not set or is empty." >&2
    echo "                You must set this env var before starting the docker image." >&2
    exit 1
fi

if [[ ! -v CLAUDE_SANDBOX_INSTANCE ]] || [[ -z "$CLAUDE_SANDBOX_INSTANCE" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_INSTANCE is not set or is empty." >&2
    echo "                Each sandbox needs a unique instance ID so concurrent" >&2
    echo "                inner dockerds don't share /var/lib/docker." >&2
    exit 1
fi

# Per-instance suffix. Each sandbox gets its own DinD volume, container name,
# and instance-private state directory so concurrent instances don't fight
# over /var/lib/docker, write-hot caches, or shell snapshots.
INSTANCE_SUFFIX="-${CLAUDE_SANDBOX_INSTANCE}"
CONTAINER_NAME="claude-sandbox-${CLAUDE_SANDBOX_INSTANCE}"

# State is split in two:
#   SHARED_HOME  — settings/skills/plugins/hooks/projects/sessions/plans/tasks,
#                  plus .claude.json. One copy across all instances so installs
#                  and memory propagate.
#   SANDBOX_HOME — per-instance write-hot dirs (cache, file-history,
#                  shell-snapshots, session-env, backups, history.jsonl) so
#                  concurrent instances don't race on append-heavy files.
#
# Both are anchored to the script dir by default so the layout is portable.
# Override with CLAUDE_SANDBOX_HOME / CLAUDE_SANDBOX_SHARED — must be absolute.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSISTENT_STATE_DIR="${SCRIPT_DIR}/claude-sandbox-persistent-state${INSTANCE_SUFFIX}"
SHARED_STATE_DIR="${SCRIPT_DIR}/claude-sandbox-shared"
SANDBOX_HOME="${CLAUDE_SANDBOX_HOME:-$PERSISTENT_STATE_DIR}"
SHARED_HOME="${CLAUDE_SANDBOX_SHARED:-$SHARED_STATE_DIR}"

if [[ "$SANDBOX_HOME" != /* ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_HOME must be an absolute path." >&2
    echo "                Got: '$SANDBOX_HOME'" >&2
    exit 1
fi
if [[ "$SHARED_HOME" != /* ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_SHARED must be an absolute path." >&2
    echo "                Got: '$SHARED_HOME'" >&2
    exit 1
fi

# Bootstrap shared dir + default settings.json (only on first ever launch).
mkdir -p "$SHARED_HOME/.claude"
[ -s "$SHARED_HOME/.claude.json" ] || echo '{}' > "$SHARED_HOME/.claude.json"
if [ ! -f "$SHARED_HOME/.claude/settings.json" ] ; then
  cat > "$SHARED_HOME/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/record-task-start.sh"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-if-long.sh"
          }
        ]
      }
    ]
  }
}
JSON
fi

# Bootstrap per-instance hot-state dir. Bind-mount sources must exist before
# `docker run` or Docker silently creates them as the wrong type (dir vs file).
mkdir -p \
  "$SANDBOX_HOME/.claude/cache" \
  "$SANDBOX_HOME/.claude/file-history" \
  "$SANDBOX_HOME/.claude/backups" \
  "$SANDBOX_HOME/.claude/shell-snapshots" \
  "$SANDBOX_HOME/.claude/session-env"
touch "$SANDBOX_HOME/.claude/history.jsonl"

# Refuse to launch if this instance's DinD volume is already in use — two
# dockerds writing the same /var/lib/docker corrupt the store.
DIND_VOLUME="claude-dind-lib${INSTANCE_SUFFIX}"
in_use=$(docker ps -q --filter "volume=${DIND_VOLUME}")
if [ -n "$in_use" ]; then
    echo "Error: instance '${CLAUDE_SANDBOX_INSTANCE}' is already running:" >&2
    docker ps --filter "volume=${DIND_VOLUME}" \
        --format '  {{.ID}}  {{.Names}}  ({{.Status}})' >&2
    echo "Pick a different CLAUDE_SANDBOX_INSTANCE to launch a parallel sandbox." >&2
    exit 1
fi

# Make it so. Any args ($@) are passed to `claude` inside the container —
# e.g. --resume <id>, --continue, --dangerously-skip-permissions.
# To drop into a shell instead, swap `claude "$@"` below for `/bin/bash`.
exec docker run --rm -it \
  --name "${CONTAINER_NAME}" \
  -v ${CLAUDE_SANDBOX_PROJECTS_DIR}:/workspace \
  -v "${SHARED_HOME}/.claude:/home/claude/.claude" \
  -v "${SHARED_HOME}/.claude.json:/home/claude/.claude.json" \
  -v "${SANDBOX_HOME}/.claude/cache:/home/claude/.claude/cache" \
  -v "${SANDBOX_HOME}/.claude/file-history:/home/claude/.claude/file-history" \
  -v "${SANDBOX_HOME}/.claude/backups:/home/claude/.claude/backups" \
  -v "${SANDBOX_HOME}/.claude/shell-snapshots:/home/claude/.claude/shell-snapshots" \
  -v "${SANDBOX_HOME}/.claude/session-env:/home/claude/.claude/session-env" \
  -v "${SANDBOX_HOME}/.claude/history.jsonl:/home/claude/.claude/history.jsonl" \
  -v "${HOME}/.claude/.credentials.json:/home/claude/.claude/.credentials.json" \
  -v ${CLAUDE_SANDBOX_CONTEXT_DIR}:/context \
  --runtime=sysbox-runc \
  -v "${DIND_VOLUME}:/var/lib/docker" \
  -e HEADROOM="${HEADROOM:-0}" \
  -e HEADROOM_PORT="${HEADROOM_PORT:-8787}" \
  -w /workspace \
  --entrypoint /home/claude/start_script.sh \
  claude-sandbox:latest "$@"

