#!/usr/bin/env bash
set -euo pipefail

# Here we set our directories and credentials so we can authenticate and have
# a proper sandbox.  It's VERY important that we don't let these agents run
# freely around our machine.
# `:-` default — under `set -u`, a bare ${VAR} on an unset var errors with
# "unbound variable" before our friendly message ever runs. ${VAR:-} expands
# to empty so the -z test fires the helpful branch instead.
if [[ -z "${CLAUDE_SANDBOX_PROJECTS_DIR:-}" ]] || [[ ! -d "${CLAUDE_SANDBOX_PROJECTS_DIR}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_PROJECTS_DIR is not set, is empty, or does not exist." >&2
    echo "                You must set this env var before starting the docker image." >&2
    echo "                Try: source env.example.sh   (or your env.<INSTANCE>.sh)" >&2
    exit 1
fi

if [[ -z "${CLAUDE_SANDBOX_CONTEXT_DIR:-}" ]] || [[ ! -d "${CLAUDE_SANDBOX_CONTEXT_DIR}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_CONTEXT_DIR is not set, is empty, or does not exist." >&2
    echo "                You must set this env var before starting the docker image." >&2
    echo "                Try: source env.example.sh   (or your env.<INSTANCE>.sh)" >&2
    exit 1
fi

if [[ -z "${CLAUDE_SANDBOX_INSTANCE:-}" ]]; then
    echo "CRITICAL ERROR: CLAUDE_SANDBOX_INSTANCE is not set, does not exist, or is empty." >&2
    echo "                Each sandbox needs a unique instance ID so concurrent" >&2
    echo "                inner dockerds don't share /var/lib/docker." >&2
    echo "                Try: source env.example.sh   (or your env.<INSTANCE>.sh)" >&2
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

# Resolve the script's actual location, following symlinks, so SCRIPT_DIR
# points at the repo regardless of where the caller invoked from. Without
# `readlink -f` a `./run_claude_docker.sh` invocation from a directory that
# contains a *symlink* (or a copy) of the script resolved SCRIPT_DIR to the
# caller's CWD, redirecting shared state + persistent state lookups to a
# location that has none of the repo's content.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
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

# Defaults committed in the repo so a fresh clone has working hooks +
# settings on first launch. Source: claude-sandbox-shared/.claude/. Shared
# mode (USE_SHARED=1) bind-mounts the whole tracked dir; per-instance mode
# (USE_SHARED=0) copies these as seed on first launch only.
DEFAULT_HOOKS_DIR="${SCRIPT_DIR}/claude-sandbox-shared/.claude/hooks"
DEFAULT_SETTINGS_FILE="${SCRIPT_DIR}/claude-sandbox-shared/.claude/settings.json"

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

# Seed settings.json from the tracked default if target doesn't exist yet.
# Same semantics as seed_hooks — first-launch only, never overwrites user
# customization. Source is the in-repo tracked file, not SHARED_HOME (which
# the user may have remapped to a custom location).
seed_settings() {
  local target="$1"
  if [[ ! -f "$target" && -f "$DEFAULT_SETTINGS_FILE" ]]; then
    mkdir -p "$(dirname "$target")"
    cp -a "$DEFAULT_SETTINGS_FILE" "$target"
  fi
}

if [[ "$USE_SHARED" == "1" ]]; then
    # --- shared layout ---------------------------------------------------
    # SHARED_HOME defaults to the tracked claude-sandbox-shared/ in the repo,
    # so settings.json + hooks/ are already present from the clone. No
    # seeding needed unless the user remapped CLAUDE_SANDBOX_SHARED to an
    # empty dir; seed_hooks/seed_settings handle that as a courtesy.
    mkdir -p "$SHARED_HOME/.claude"
    seed_hooks "$SHARED_HOME/.claude/hooks"
    seed_settings "$SHARED_HOME/.claude/settings.json"

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
    seed_settings "$SANDBOX_HOME/.claude/settings.json"
    [ -s "$SANDBOX_HOME/.claude.json" ] || echo '{}' > "$SANDBOX_HOME/.claude.json"
    echo "layout: per-instance (SANDBOX_HOME=${SANDBOX_HOME})"
fi

# Defensive sanity check: any of these paths existing as a DIRECTORY is a
# silent killer. They're supposed to be regular files. The trap appears
# when an earlier `docker run -v <host_file>:<container_file>` ran without
# the host file existing — Docker creates the container destination as a
# directory by default, and that directory then persists inside whatever
# parent directory bind mount it landed in (e.g. the shared .claude/).
# Once present, claude code can't write `.credentials.json` because a
# directory with that name is in the way; /login appears to succeed in
# memory but the on-disk write fails. Same shape for `.claude.json`.
#
# Catch it here and shriek rather than letting the user debug another
# silent /login round trip. NEVER auto-rm — rm-on-someone-else's-state-
# dir is a footgun, and a real directory at these paths only happens via
# this bug, so the safe thing is to halt and ask.
#
# Prevention going forward: we don't bind-mount any single host file
# whose existence isn't pre-guaranteed by this script. The host
# credentials file mount that originally created this trap was removed
# in c7b0cab. This check is defense-in-depth against leftover state from
# the old code path and against any future regression.
check_not_directory() {
    local path="$1"
    if [ -d "$path" ]; then
        local RED=$'\033[1;31m' YEL=$'\033[1;33m' RST=$'\033[0m'
        echo
        echo "${RED}===== LAUNCH ABORTED: directory where a file should be =====${RST}"
        echo "${YEL}Path:    $path${RST}"
        echo "${YEL}Found:   directory${RST}"
        echo "${YEL}Wanted:  regular file (or absent)${RST}"
        echo
        echo "${YEL}This is leftover state from an older sandbox launcher that bind-${RST}"
        echo "${YEL}mounted a host file source that did not exist. Docker auto-created${RST}"
        echo "${YEL}the destination as a directory and that directory persisted inside${RST}"
        echo "${YEL}one of the directory bind mounts. claude code cannot write the file${RST}"
        echo "${YEL}while a directory blocks the path, so /login fails silently.${RST}"
        echo
        echo "${YEL}Fix:${RST}"
        echo "${YEL}    rm -rf '$path'${RST}"
        echo "${YEL}Then relaunch.${RST}"
        echo "${RED}=============================================================${RST}"
        echo
        exit 1
    fi
}
for candidate in \
    "$SHARED_HOME/.claude/.credentials.json" \
    "$SHARED_HOME/.claude.json" \
    "$SANDBOX_HOME/.claude/.credentials.json" \
    "$SANDBOX_HOME/.claude.json" ; do
    check_not_directory "$candidate"
done

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
  # No host credentials file bind-mounted. Each sandbox does its own
  # /login on first launch and stores the resulting token inside its
  # state dir's .claude/ (shared dir in USE_SHARED=1, per-instance dir
  # otherwise) — both of which are directory bind mounts where claude
  # code's atomic rename(2) works fine. Earlier attempts to bind the
  # host's ~/.claude/.credentials.json directly broke rename and
  # silently dropped post-/login tokens.
  -v "${CLAUDE_SANDBOX_CONTEXT_DIR}:/context"
  -v "${DIND_VOLUME}:/var/lib/docker"
)

# Optional caller-supplied read-only mounts. Space-separated list of
# host:container pairs in CLAUDE_SANDBOX_RO_MOUNTS — one bind mount per
# entry, all forced read-only via the :ro suffix. Use for reference
# datasets, shared corpora, system config the agent should read but never
# mutate. Host path must already exist; we refuse to launch otherwise so
# Docker doesn't auto-create the source as a directory (same trap the
# `check_not_directory` guard above protects against).
#
# Example env.<INSTANCE>.sh:
#   export CLAUDE_SANDBOX_RO_MOUNTS="/data/reference:/data/reference /etc/shared-config:/opt/config"
RO_MOUNTS_RAW="${CLAUDE_SANDBOX_RO_MOUNTS:-}"
if [[ -n "$RO_MOUNTS_RAW" ]]; then
    for entry in $RO_MOUNTS_RAW; do
        host_path="${entry%%:*}"
        cont_path="${entry#*:}"
        if [[ "$host_path" == "$entry" || -z "$cont_path" ]]; then
            echo "CRITICAL ERROR: CLAUDE_SANDBOX_RO_MOUNTS entry '$entry' is not 'host:container' form." >&2
            exit 1
        fi
        if [[ "$host_path" != /* || "$cont_path" != /* ]]; then
            echo "CRITICAL ERROR: CLAUDE_SANDBOX_RO_MOUNTS entry '$entry' must use absolute paths on both sides." >&2
            exit 1
        fi
        if [[ ! -e "$host_path" ]]; then
            echo "CRITICAL ERROR: CLAUDE_SANDBOX_RO_MOUNTS host path '$host_path' does not exist on this host." >&2
            echo "                Refusing to let Docker auto-create it as a directory." >&2
            exit 1
        fi
        MOUNTS+=( -v "${host_path}:${cont_path}:ro" )
        echo "ro-mount: ${host_path} -> ${cont_path}"
    done
fi

# fiss-mcp (Terra MCP server) lifecycle. The server runs on the HOST (not in
# the container) over HTTP. The container only sees a URL; it has no gcloud,
# gsutil, ~/.config/gcloud, or google-cloud-* libs — the only path to GCP
# from inside the sandbox is via the MCP tools exposed by this server, which
# is read-only unless FISS_MCP_ALLOW_WRITES=1. We install/refresh the host
# venv on every launch (idempotent), spawn the server, wait for it to bind,
# and register a trap so the server dies when this script exits.
FISS_MCP_ENABLED="${FISS_MCP:-1}"
FISS_MCP_URL_FOR_CONTAINER=""
HOST_FISS_PID=""
HOST_FISS_LOG=""

cleanup_host_fiss() {
  if [[ -n "${HOST_FISS_PID}" ]] && kill -0 "${HOST_FISS_PID}" 2>/dev/null; then
    echo "host_fiss_mcp: stopping (pid=${HOST_FISS_PID})"
    kill "${HOST_FISS_PID}" 2>/dev/null || true
    wait "${HOST_FISS_PID}" 2>/dev/null || true
  fi
}
# Vertex proxy state — declared here so the cleanup function below is safe
# under `set -u` even when Vertex mode is off.
HOST_VERTEX_PID=""
cleanup_host_vertex() {
  if [[ -n "${HOST_VERTEX_PID:-}" ]] && kill -0 "${HOST_VERTEX_PID}" 2>/dev/null; then
    echo "vertex_proxy: stopping (pid=${HOST_VERTEX_PID})"
    kill "${HOST_VERTEX_PID}" 2>/dev/null || true
    wait "${HOST_VERTEX_PID}" 2>/dev/null || true
  fi
}
cleanup_host_services() { cleanup_host_fiss; cleanup_host_vertex; }
trap cleanup_host_services EXIT INT TERM

if [[ "$FISS_MCP_ENABLED" == "1" ]]; then
  INSTALL_ROOT="${SCRIPT_DIR}/host_fiss_mcp"
  if [[ ! -x "${INSTALL_ROOT}/venv/bin/python" || ! -f "${INSTALL_ROOT}/run-server.py" ]]; then
    echo "ERROR: fiss-mcp host install not found at ${INSTALL_ROOT}." >&2
    echo "       Run ./setup_host.sh on this machine first to install it," >&2
    echo "       or export FISS_MCP=0 to launch without Terra access." >&2
    exit 1
  fi

  # Per-instance port so concurrent sandboxes don't collide. Hash the
  # instance name into 39000-39999. Override with FISS_MCP_PORT.
  PORT_OFFSET=$(printf '%s' "${CLAUDE_SANDBOX_INSTANCE}" | cksum | awk '{print $1 % 1000}')
  HOST_FISS_PORT="${FISS_MCP_PORT:-$((39000 + PORT_OFFSET))}"
  HOST_FISS_PATH="/mcp/"

  # Bind only to the docker bridge gateway IP — the same address the container
  # reaches us at via `host.docker.internal:host-gateway`. This keeps the MCP
  # off external interfaces (eth0, wlan0) without needing iptables / firewall
  # config. Refuse to launch if we can't determine the bridge IP rather than
  # silently falling back to 0.0.0.0.
  HOST_BIND_IP="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  if [[ -z "${HOST_BIND_IP}" ]]; then
    echo "fiss-mcp: could not determine docker bridge gateway IP via" >&2
    echo "          \`docker network inspect bridge\`. Refusing to bind 0.0.0.0." >&2
    echo "          Verify docker is running and the default bridge exists." >&2
    exit 1
  fi

  if (echo > "/dev/tcp/${HOST_BIND_IP}/${HOST_FISS_PORT}") 2>/dev/null; then
    echo "fiss-mcp: ${HOST_BIND_IP}:${HOST_FISS_PORT} already in use." >&2
    echo "          Set FISS_MCP_PORT to a free port or stop the conflicting process." >&2
    exit 1
  fi

  HOST_FISS_LOG="${SANDBOX_HOME}/.claude/host_fiss_mcp.log"
  mkdir -p "$(dirname "${HOST_FISS_LOG}")"

  FISS_MCP_HOST="${HOST_BIND_IP}" \
  FISS_MCP_PORT="${HOST_FISS_PORT}" \
  FISS_MCP_PATH="${HOST_FISS_PATH}" \
  FISS_MCP_ALLOW_WRITES="${FISS_MCP_ALLOW_WRITES:-0}" \
  nohup "${INSTALL_ROOT}/venv/bin/python" "${INSTALL_ROOT}/run-server.py" \
    > "${HOST_FISS_LOG}" 2>&1 &
  HOST_FISS_PID=$!

  echo -n "fiss-mcp: waiting for host server on ${HOST_BIND_IP}:${HOST_FISS_PORT} "
  READY=0
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/${HOST_BIND_IP}/${HOST_FISS_PORT}") 2>/dev/null; then
      READY=1; echo " OK"; break
    fi
    echo -n "."; sleep 1
  done
  if [[ "$READY" != "1" ]]; then
    echo " FAILED"
    echo "fiss-mcp: server did not come up — last 20 lines of ${HOST_FISS_LOG}:" >&2
    tail -20 "${HOST_FISS_LOG}" >&2 || true
    exit 1
  fi

  FISS_MCP_URL_FOR_CONTAINER="http://host.docker.internal:${HOST_FISS_PORT}${HOST_FISS_PATH}"
  echo "fiss-mcp: host server pid=${HOST_FISS_PID} url=${FISS_MCP_URL_FOR_CONTAINER}"
fi

# Vertex AI proxy lifecycle (Option B — chained).
#
# Activated when the parent shell has sourced SET_VERTEX_MODE.sh, which
# exports CLAUDE_CODE_USE_VERTEX=1 + ANTHROPIC_VERTEX_PROJECT_ID + CLOUD_ML_REGION.
# Those env vars are LAUNCHER-side signals only — claude-code inside the
# container runs in standard Anthropic mode, not Vertex SDK mode. We do not
# forward CLAUDE_CODE_USE_VERTEX into the container.
#
# Flow:
#   claude (in container, Anthropic mode)
#     → headroom (in container, optional, when HEADROOM=1)
#         (reads ANTHROPIC_TARGET_API_URL from env, forwards Anthropic-shape
#          body to the host vertex_proxy at that URL)
#     → vertex_proxy.py (on host, bound to docker bridge gateway IP)
#         (strips incoming Authorization, mints fresh GCP token, rebuilds
#          Vertex URL from project/region/model, forwards)
#     → Vertex AI
#
# With HEADROOM=0, claude hits vertex_proxy directly via ANTHROPIC_BASE_URL
# (set inside the container by start_script.sh when no headroom is running).
VERTEX_ENABLED="${CLAUDE_CODE_USE_VERTEX:-0}"
VERTEX_PROXY_URL_FOR_CONTAINER=""
HOST_VERTEX_LOG=""

if [[ "$VERTEX_ENABLED" == "1" ]]; then
  if ! command -v gcloud >/dev/null 2>&1; then
    echo "vertex_proxy: gcloud not on PATH; cannot mint Vertex access tokens." >&2
    echo "              Install Google Cloud SDK + run 'gcloud auth login' and" >&2
    echo "              'gcloud auth application-default login', or unset" >&2
    echo "              CLAUDE_CODE_USE_VERTEX to launch in Anthropic-API mode." >&2
    exit 1
  fi
  if [[ -z "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]]; then
    echo "vertex_proxy: ANTHROPIC_VERTEX_PROJECT_ID is unset." >&2
    echo "              Source SET_VERTEX_MODE.sh (with your project id) first." >&2
    exit 1
  fi
  if [[ -z "${CLOUD_ML_REGION:-}" ]]; then
    echo "vertex_proxy: CLOUD_ML_REGION is unset." >&2
    echo "              Source SET_VERTEX_MODE.sh (with your region) first." >&2
    exit 1
  fi
  if [[ ! -f "${SCRIPT_DIR}/vertex_proxy.py" ]]; then
    echo "vertex_proxy: ${SCRIPT_DIR}/vertex_proxy.py not found." >&2
    exit 1
  fi

  # Per-instance port in the 38000-38999 range so concurrent sandboxes don't
  # collide. Hashed from the instance name. Disjoint from fiss-mcp's 39xxx.
  VERTEX_PORT_OFFSET=$(printf '%s' "${CLAUDE_SANDBOX_INSTANCE}" | cksum | awk '{print $1 % 1000}')
  HOST_VERTEX_PORT="${VERTEX_PROXY_PORT:-$((38000 + VERTEX_PORT_OFFSET))}"

  # Bind only to the docker bridge gateway IP — same model as fiss-mcp. Keeps
  # the proxy off external interfaces (eth0, wlan0) without needing iptables.
  VERTEX_BIND_IP="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
  if [[ -z "${VERTEX_BIND_IP}" ]]; then
    echo "vertex_proxy: could not determine docker bridge gateway IP via" >&2
    echo "              \`docker network inspect bridge\`. Refusing to bind 0.0.0.0." >&2
    exit 1
  fi

  if (echo > "/dev/tcp/${VERTEX_BIND_IP}/${HOST_VERTEX_PORT}") 2>/dev/null; then
    echo "vertex_proxy: ${VERTEX_BIND_IP}:${HOST_VERTEX_PORT} already in use." >&2
    echo "              Set VERTEX_PROXY_PORT to a free port or stop the conflict." >&2
    exit 1
  fi

  HOST_VERTEX_LOG="${SANDBOX_HOME}/.claude/host_vertex_proxy.log"
  mkdir -p "$(dirname "${HOST_VERTEX_LOG}")"

  VERTEX_PROXY_HOST="${VERTEX_BIND_IP}" \
  VERTEX_PROXY_PORT="${HOST_VERTEX_PORT}" \
  ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID}" \
  CLOUD_ML_REGION="${CLOUD_ML_REGION}" \
  ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}" \
  nohup python3 "${SCRIPT_DIR}/vertex_proxy.py" \
    > "${HOST_VERTEX_LOG}" 2>&1 &
  HOST_VERTEX_PID=$!

  echo -n "vertex_proxy: waiting for host server on ${VERTEX_BIND_IP}:${HOST_VERTEX_PORT} "
  VREADY=0
  for _ in $(seq 1 30); do
    if (echo > "/dev/tcp/${VERTEX_BIND_IP}/${HOST_VERTEX_PORT}") 2>/dev/null; then
      VREADY=1; echo " OK"; break
    fi
    echo -n "."; sleep 1
  done
  if [[ "$VREADY" != "1" ]]; then
    echo " FAILED"
    echo "vertex_proxy: server did not come up — last 20 lines of ${HOST_VERTEX_LOG}:" >&2
    tail -20 "${HOST_VERTEX_LOG}" >&2 || true
    exit 1
  fi

  # No /v1 suffix: Anthropic-SDK convention (and headroom's ANTHROPIC_TARGET_API_URL)
  # is base URL only — clients append /v1/messages. The proxy ignores the path
  # anyway, so it's purely about not confusing headroom's URL builder.
  VERTEX_PROXY_URL_FOR_CONTAINER="http://host.docker.internal:${HOST_VERTEX_PORT}"
  echo "vertex_proxy: host server pid=${HOST_VERTEX_PID} url=${VERTEX_PROXY_URL_FOR_CONTAINER}"
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

# Runtime + GPU selection.
#
# sysbox-runc gives us docker-in-docker, user-namespace remap, and stronger
# isolation, but it does NOT support NVIDIA GPU passthrough
# (https://github.com/nestybox/sysbox/issues/50). If the host has GPUs, fall
# back to the default runc runtime and forward them with --gpus all.
RUNTIME_FLAG=(--runtime=sysbox-runc)
GPU_FLAGS=()
HAVE_GPU=0
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  HAVE_GPU=1
fi

# Don't switch runtimes if Docker has no 'nvidia' runtime registered — the
# --gpus flag would just error out and we'd lose sysbox for no gain.
if [[ "${HAVE_GPU}" == "1" ]]; then
  if ! docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
    RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
    echo
    echo "${YEL}WARNING: GPU detected but Docker has no 'nvidia' runtime registered.${RST}"
    echo "${YEL}Install nvidia-container-toolkit and run:${RST}"
    echo "${YEL}    sudo nvidia-ctk runtime configure --runtime=docker${RST}"
    echo "${YEL}    sudo systemctl restart docker${RST}"
    echo "${YEL}Falling back to sysbox-runc with NO GPU passthrough.${RST}"
    echo
    HAVE_GPU=0
  fi
fi

if [[ "${HAVE_GPU}" == "1" ]]; then
  RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo
  echo "${YEL}========================================================================${RST}"
  echo "${YEL}GPU DETECTED — switching container runtime from sysbox-runc to runc.${RST}"
  echo "${YEL}    * --gpus all will be forwarded to the container${RST}"
  echo "${YEL}    * docker-in-docker (DinD) inside the sandbox WILL NOT WORK${RST}"
  echo "${YEL}    * user-namespace remap and extra sysbox isolation: DISABLED${RST}"
  echo "${YEL}    * upstream issue: https://github.com/nestybox/sysbox/issues/50${RST}"
  echo "${YEL}If you need DinD instead, hide nvidia-smi from PATH before launching.${RST}"
  echo "${YEL}========================================================================${RST}"
  echo
  RUNTIME_FLAG=()
  GPU_FLAGS=(--gpus all)
fi

# Make it so. Any args ($@) are passed to `claude` inside the container —
# e.g. --resume <id>, --continue, --dangerously-skip-permissions.
# To drop into a shell instead, swap `claude "$@"` below for `/bin/bash`.
# Note: not using `exec` so the EXIT trap can still fire to clean up the
# host fiss-mcp process after the container exits.
docker run --rm -it \
  --name "${CONTAINER_NAME}" \
  "${MOUNTS[@]}" \
  --add-host=host.docker.internal:host-gateway \
  "${RUNTIME_FLAG[@]}" \
  "${GPU_FLAGS[@]}" \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  -e HEADROOM="${HEADROOM:-0}" \
  -e HEADROOM_PORT="${HEADROOM_PORT:-8787}" \
  -e CLAUDE_NOTIFY_EMAIL="${CLAUDE_NOTIFY_EMAIL:-}" \
  -e CLAUDE_NOTIFY_FROM="${CLAUDE_NOTIFY_FROM:-claude-sandbox}" \
  -e CLAUDE_NOTIFY_HOSTNAME="${CLAUDE_NOTIFY_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}" \
  -e SANDBOX_HAS_DIND="$([[ "${HAVE_GPU}" == "1" ]] && echo 0 || echo 1)" \
  -e FISS_MCP="${FISS_MCP_ENABLED}" \
  -e FISS_MCP_ALLOW_WRITES="${FISS_MCP_ALLOW_WRITES:-0}" \
  -e FISS_MCP_URL="${FISS_MCP_URL_FOR_CONTAINER}" \
  -e CODEGRAPH="${CODEGRAPH:-1}" \
  -e ANTHROPIC_MODEL="${ANTHROPIC_MODEL:-}" \
  -e CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" \
  -e ANTHROPIC_TARGET_API_URL="${VERTEX_PROXY_URL_FOR_CONTAINER}" \
  -w /workspace \
  claude-sandbox:latest /home/claude/start_script.sh "$@"

