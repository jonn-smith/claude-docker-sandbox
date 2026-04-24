#!/usr/bin/env bash
set -euo pipefail

# Here we set our directories and credentials so we can authenticate and have
# a proper sandbox.  It's VERY important that we don't let these agents run
# freely around our machine.
PROJECTS_DIR=/juffowup2/claude_projects/workspace
PROJECTS_DIR=/juffowup2/claude_projects/workspace/gCNV_Calling
PERSISTENT_STATE_DIR=/juffowup2/claude_projects/claude-sandbox-persistent-state
SANDBOX_HOME="${CLAUDE_SANDBOX_HOME:-$PERSISTENT_STATE_DIR}"

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

# Make it so. Any args ($@) are passed to `claude` inside the container —
# e.g. --resume <id>, --continue, --dangerously-skip-permissions.
# To drop into a shell instead, swap `claude "$@"` below for `/bin/bash`.
exec docker run --rm -it \
  -v ${PROJECTS_DIR}:/workspace \
  -v "${SANDBOX_HOME}/.claude:/home/claude/.claude" \
  -v "${SANDBOX_HOME}/.claude.json:/home/claude/.claude.json" \
  -v "${HOME}/.claude/.credentials.json:/home/claude/.claude/.credentials.json" \
  --runtime=sysbox-runc \
  -v claude-dind-lib:/var/lib/docker \
  -w /workspace \
  --entrypoint /home/claude/start_script.sh \
  claude-sandbox:latest "$@"

