#!/usr/bin/env bash
set -euo pipefail

# Here we set our directories and credentials so we can authenticate and have
# a proper sandbox.  It's VERY important that we don't let these agents run
# freely around our machine.
if [[ -z "${CLAUDE_SANDBOX_PROJECTS_DIR}" ]] || [[ ! -d "${CLAUDE_SANDBOX_PROJECTS_DIR}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_PROJECTS_DIR is not set, is empty, or does not exist." >&2
    echo "                You must set this env var before starting the docker image." >&2
    exit 1
fi

if [[ -z "${CLAUDE_SANDBOX_CONTEXT_DIR}" ]] || [[ ! -d "${CLAUDE_SANDBOX_CONTEXT_DIR}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_CONTEXT_DIR is not set, is empty, or does not exist." >&2
    echo "                You must set this env var before starting the docker image." >&2
    exit 1
fi

if [[ -z "$CLAUDE_SANDBOX_INSTANCE" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_INSTANCE is not set, does not exist, or is empty." >&2
    echo "                Each sandbox needs a unique instance ID so concurrent" >&2
    echo "                inner dockerds don't share /var/lib/docker." >&2
    exit 1
fi

# Per-instance suffix. Each sandbox gets its own DinD volume, container name,
# and persistent-state directory so concurrent instances don't fight over
# /var/lib/docker.
INSTANCE_SUFFIX="-${CLAUDE_SANDBOX_INSTANCE}"
CONTAINER_NAME="claude-sandbox-${CLAUDE_SANDBOX_INSTANCE}"

# Two layout modes, picked by CLAUDE_SANDBOX_USE_SHARED:
#
#   0 (default) — full per-instance state at $SANDBOX_HOME/.claude. Settings,
#                 skills, plugins, sessions, hot dirs all live here. One copy
#                 per instance. Original layout, fully self-contained.
#
#   1           — split layout. $SHARED_HOME holds settings/skills/plugins/
#                 hooks/projects/plans/tasks/sessions, one copy across all
#                 shared-mode instances. $SANDBOX_HOME holds write-hot dirs
#                 (cache, file-history, backups, shell-snapshots,
#                 session-env, history.jsonl) and .claude.json. Per-instance
#                 overlays bind-mount on top of the shared .claude.
#                 .claude.json stays per-instance because it is rewritten
#                 whole on every change and holds per-project state
#                 (allowedTools, mcpServers, history) that would race or
#                 collide if shared.
#
# Existing per-instance dirs are untouched when USE_SHARED=0, so old instances
# keep working exactly as before. Opt new instances into shared mode by
# exporting CLAUDE_SANDBOX_USE_SHARED=1 in their env.<INSTANCE>.sh.
USE_SHARED="${CLAUDE_SANDBOX_USE_SHARED:-0}"

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
if [[ "$USE_SHARED" == "1" && "$SHARED_HOME" != /* ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_SHARED must be an absolute path." >&2
    echo "                Got: '$SHARED_HOME'" >&2
    exit 1
fi

# Default hooks committed in the repo so a fresh clone has working hooks.
# Source: claude-sandbox-shared/.claude/hooks/. Shared-mode launches use
# them in place; per-instance launches get a copy on first launch via
# seed_hooks.
DEFAULT_HOOKS_DIR="${SCRIPT_DIR}/claude-sandbox-shared/.claude/hooks"

# Seed hooks dir from DEFAULT_HOOKS_DIR if target doesn't exist yet. First
# launch of a new instance gets the committed defaults; subsequent launches
# leave user customizations alone.
seed_hooks() {
  local target="$1"
  if [[ ! -d "$target" && -d "$DEFAULT_HOOKS_DIR" ]]; then
    mkdir -p "$(dirname "$target")"
    cp -a "$DEFAULT_HOOKS_DIR" "$target"
  fi
}

# Default settings.json content for first-ever launch of an empty state dir.
write_default_settings() {
  local target="$1"
  cat > "$target" <<'JSON'
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
    "Notification": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/notify-if-long.sh"
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
}

if [[ "$USE_SHARED" == "1" ]]; then
    # --- shared layout ---------------------------------------------------
    mkdir -p "$SHARED_HOME/.claude"
    seed_hooks "$SHARED_HOME/.claude/hooks"
    [ -f "$SHARED_HOME/.claude/settings.json" ] || write_default_settings "$SHARED_HOME/.claude/settings.json"

    # Per-instance hot-state dirs. Bind-mount sources must exist before
    # `docker run` or Docker creates them as the wrong type (dir vs file).
    # .claude.json stays per-instance: it's rewritten whole on every change
    # and holds per-project allowedTools/mcpServers/history that race under
    # concurrent shared-mode launches.
    mkdir -p \
      "$SANDBOX_HOME/.claude/cache" \
      "$SANDBOX_HOME/.claude/file-history" \
      "$SANDBOX_HOME/.claude/backups" \
      "$SANDBOX_HOME/.claude/shell-snapshots" \
      "$SANDBOX_HOME/.claude/session-env" \
      "$SANDBOX_HOME/.claude/projects"
    touch "$SANDBOX_HOME/.claude/history.jsonl"
    [ -s "$SANDBOX_HOME/.claude.json" ] || echo '{}' > "$SANDBOX_HOME/.claude.json"
    echo "layout: shared (SHARED_HOME=${SHARED_HOME}, hot=${SANDBOX_HOME})"
else
    # --- original per-instance layout ------------------------------------
    mkdir -p "$SANDBOX_HOME/.claude"
    seed_hooks "$SANDBOX_HOME/.claude/hooks"
    [ -s "$SANDBOX_HOME/.claude.json" ] || echo '{}' > "$SANDBOX_HOME/.claude.json"
    [ -f "$SANDBOX_HOME/.claude/settings.json" ] || write_default_settings "$SANDBOX_HOME/.claude/settings.json"
    echo "layout: per-instance (SANDBOX_HOME=${SANDBOX_HOME})"
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

# Build the mount args based on layout. Later mounts shadow earlier ones, so
# in shared mode the per-instance hot dirs override the shared parent.
MOUNTS=( -v "${CLAUDE_SANDBOX_PROJECTS_DIR}:/workspace" )
if [[ "$USE_SHARED" == "1" ]]; then
    MOUNTS+=(
      -v "${SHARED_HOME}/.claude:/home/claude/.claude"
      -v "${SANDBOX_HOME}/.claude.json:/home/claude/.claude.json"
      -v "${SANDBOX_HOME}/.claude/cache:/home/claude/.claude/cache"
      -v "${SANDBOX_HOME}/.claude/file-history:/home/claude/.claude/file-history"
      -v "${SANDBOX_HOME}/.claude/backups:/home/claude/.claude/backups"
      -v "${SANDBOX_HOME}/.claude/shell-snapshots:/home/claude/.claude/shell-snapshots"
      -v "${SANDBOX_HOME}/.claude/session-env:/home/claude/.claude/session-env"
      -v "${SANDBOX_HOME}/.claude/projects:/home/claude/.claude/projects"
      -v "${SANDBOX_HOME}/.claude/history.jsonl:/home/claude/.claude/history.jsonl"
    )
else
    MOUNTS+=(
      -v "${SANDBOX_HOME}/.claude:/home/claude/.claude"
      -v "${SANDBOX_HOME}/.claude.json:/home/claude/.claude.json"
    )
fi
MOUNTS+=(
  -v "${HOME}/.claude/.credentials.json:/home/claude/.claude/.credentials.json"
  -v "${CLAUDE_SANDBOX_CONTEXT_DIR}:/context"
  -v "${DIND_VOLUME}:/var/lib/docker"
)

# fiss-mcp / Terra auth pass-through. gcloud config dir (rw — adc refreshes
# need to write) plus optional service-account key file. Both optional; if
# the host paths don't exist we skip the mount so launches without GCP
# context still work.
FISS_MCP_ENABLED="${FISS_MCP:-1}"
if [[ "$FISS_MCP_ENABLED" == "1" ]]; then
  if [[ -d "${HOME}/.config/gcloud" ]]; then
    MOUNTS+=( -v "${HOME}/.config/gcloud:/home/claude/.config/gcloud" )
  fi
  # If GOOGLE_APPLICATION_CREDENTIALS points at a file on the host, mount it
  # in at a fixed container path so the env var (forwarded below) resolves.
  GAC_HOST="${GOOGLE_APPLICATION_CREDENTIALS:-}"
  GAC_CONTAINER=""
  if [[ -n "$GAC_HOST" && -f "$GAC_HOST" ]]; then
    GAC_CONTAINER="/home/claude/.config/gcloud-sa-key.json"
    MOUNTS+=( -v "${GAC_HOST}:${GAC_CONTAINER}:ro" )
  fi
fi

# Loud warning when fiss-mcp is launching with write access. Writes can
# submit workflows, mutate workspace attributes, and spend real money. The
# banner below is pre-rendered figlet output (font: standard) baked into
# the script so we don't need figlet on the host. The in-container
# start_script prints a matching banner so the warning is unavoidable on
# both sides.
if [[ "${FISS_MCP_ENABLED}" == "1" && "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
  RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo
  printf '%s' "${RED}"
  cat <<'BANNER'
 _____ ___ ____ ____   __        ______  ___ _____ _____   __  __  ___  ____  _____
|  ___|_ _/ ___/ ___|  \ \      / /  _ \|_ _|_   _| ____| |  \/  |/ _ \|  _ \| ____|
| |_   | |\___ \___ \   \ \ /\ / /| |_) || |  | | |  _|   | |\/| | | | | | | |  _|
|  _|  | | ___) |__) |   \ V  V / |  _ < | |  | | | |___  | |  | | |_| | |_| | |___
|_|   |___|____/____/     \_/\_/  |_| \_\___| |_| |_____| |_|  |_|\___/|____/|_____|
BANNER
  printf '%s' "${RST}"
  echo
  echo "${YEL}fiss-mcp is launching with --allow-writes.${RST}"
  echo "${YEL}The agent CAN submit workflows, mutate workspace attributes,${RST}"
  echo "${YEL}and otherwise spend money on your Terra/GCP account.${RST}"
  echo "${YEL}Unset FISS_MCP_ALLOW_WRITES to disable.${RST}"
  echo
  sleep 2
fi

# Make it so. Any args ($@) are passed to `claude` inside the container —
# e.g. --resume <id>, --continue, --dangerously-skip-permissions.
# To drop into a shell instead, swap `claude "$@"` below for `/bin/bash`.
exec docker run --rm -it \
  --name "${CONTAINER_NAME}" \
  "${MOUNTS[@]}" \
  --runtime=sysbox-runc \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e HEADROOM="${HEADROOM:-0}" \
  -e HEADROOM_PORT="${HEADROOM_PORT:-8787}" \
  -e CLAUDE_NOTIFY_EMAIL="${CLAUDE_NOTIFY_EMAIL:-}" \
  -e CLAUDE_NOTIFY_FROM="${CLAUDE_NOTIFY_FROM:-claude-sandbox}" \
  -e CLAUDE_NOTIFY_HOSTNAME="${CLAUDE_NOTIFY_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}" \
  -e FISS_MCP="${FISS_MCP_ENABLED}" \
  -e FISS_MCP_ALLOW_WRITES="${FISS_MCP_ALLOW_WRITES:-0}" \
  -e GOOGLE_APPLICATION_CREDENTIALS="${GAC_CONTAINER:-}" \
  -e GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-}" \
  -e CLOUDSDK_CORE_PROJECT="${CLOUDSDK_CORE_PROJECT:-${GOOGLE_CLOUD_PROJECT:-}}" \
  -w /workspace \
  claude-sandbox:latest /home/claude/start_script.sh "$@"

