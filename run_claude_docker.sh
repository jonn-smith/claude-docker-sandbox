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
# and persistent-state directory so concurrent instances don't fight over
# /var/lib/docker, .claude/sessions, or .claude.json.
INSTANCE_SUFFIX="-${CLAUDE_SANDBOX_INSTANCE}"
CONTAINER_NAME="claude-sandbox-${CLAUDE_SANDBOX_INSTANCE}"

# These directories are to store persistent state / settings.
# Used mostly for hooks / plugins / etc.
# Anchored to the script's own directory so the default works regardless of
# where the user invokes from. Docker rejects bind-mount sources that aren't
# absolute paths (it interprets them as volume names).
# Override with CLAUDE_SANDBOX_HOME — must be an absolute path, and caller is
# responsible for keeping it unique across concurrent instances.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSISTENT_STATE_DIR="${SCRIPT_DIR}/claude-sandbox-persistent-state${INSTANCE_SUFFIX}"
SANDBOX_HOME="${CLAUDE_SANDBOX_HOME:-$PERSISTENT_STATE_DIR}"

if [[ "$SANDBOX_HOME" != /* ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_HOME must be an absolute path." >&2
    echo "                Got: '$SANDBOX_HOME'" >&2
    exit 1
fi

# Set up settings if they don't exist:
mkdir -p "$SANDBOX_HOME/.claude"
[ -s "$SANDBOX_HOME/.claude.json" ] || echo '{}' > "$SANDBOX_HOME/.claude.json"
if [ ! -f "$SANDBOX_HOME/.claude/settings.json" ] ; then
  echo '{' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '  "hooks": {' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '    "UserPromptSubmit": [' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '      {' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '        "hooks": [' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '          {' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '            "type": "command",' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '            "command": "~/.claude/hooks/record-task-start.sh"' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '          }' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '        ]' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '      }' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '    ],' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '    "Stop": [' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '      {' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '        "hooks": [' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '          {' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '            "type": "command",' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '            "command": "~/.claude/hooks/notify-if-long.sh"' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '          }' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '        ]' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '      }' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '    ]' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '  }' >> "$SANDBOX_HOME/.claude/settings.json"
  echo '}' >> "$SANDBOX_HOME/.claude/settings.json"
fi

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
  -v "${SANDBOX_HOME}/.claude:/home/claude/.claude" \
  -v "${SANDBOX_HOME}/.claude.json:/home/claude/.claude.json" \
  -v "${HOME}/.claude/.credentials.json:/home/claude/.claude/.credentials.json" \
  -v ${CLAUDE_SANDBOX_CONTEXT_DIR}:/context \
  --runtime=sysbox-runc \
  -v "${DIND_VOLUME}:/var/lib/docker" \
  -e HEADROOM="${HEADROOM:-0}" \
  -e HEADROOM_PORT="${HEADROOM_PORT:-8787}" \
  -w /workspace \
  --entrypoint /home/claude/start_script.sh \
  claude-sandbox:latest "$@"

