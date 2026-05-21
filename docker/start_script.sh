#!/usr/bin/env bash
set -euo pipefail

# Start the postfix service for mail notifications:
service postfix start

# Start the docker service so we can run docker in a docker for tests:
~/start_dockerd.sh

# Vertex routing signal (Option B). When the host launcher spawned
# vertex_proxy.py and forwarded its URL via ANTHROPIC_TARGET_API_URL, that
# becomes the upstream for Anthropic-shape traffic instead of api.anthropic.com.
# Headroom (when on) natively reads ANTHROPIC_TARGET_API_URL via its
# --backend anthropic / --anthropic-api-url path, so we just export it and
# the headroom spawn below picks it up. With headroom OFF we point claude at
# vertex_proxy directly via ANTHROPIC_BASE_URL further down.
if [[ -n "${ANTHROPIC_TARGET_API_URL:-}" ]]; then
  export ANTHROPIC_TARGET_API_URL
  echo "vertex routing: ON  upstream=${ANTHROPIC_TARGET_API_URL}"
fi

# Headroom proxy (opt-in, set HEADROOM=1 at launch).
# When on, intercepts Claude Code traffic on localhost:$HEADROOM_PORT and
# compresses prompts/tool outputs before forwarding upstream — either to
# api.anthropic.com (default) or to the URL in ANTHROPIC_TARGET_API_URL when
# the launcher set one (Vertex mode). Process dies with the container; no
# persistent state.
HEADROOM_PORT="${HEADROOM_PORT:-8787}"
if [[ "${HEADROOM:-0}" == "1" ]]; then
  if ! command -v headroom >/dev/null 2>&1; then
    echo "headroom: binary missing — image needs rebuild with headroom-ai[proxy]" >&2
    exit 1
  fi
  echo "headroom: starting on :${HEADROOM_PORT}"
  headroom proxy --no-telemetry --port "${HEADROOM_PORT}" >/tmp/headroom.log 2>&1 &
  HR_PID=$!
  trap 'kill "${HR_PID}" 2>/dev/null || true' EXIT

  echo -n "Waiting for headroom proxy to start "
  for _ in {1..25}; do
    echo -n "."
    curl -fsS "http://127.0.0.1:${HEADROOM_PORT}/stats" >/dev/null 2>&1 && break
    sleep 1
  done

  if ! curl -fsS "http://127.0.0.1:${HEADROOM_PORT}/stats" >/dev/null 2>&1; then
    echo "headroom: failed to come up — see /tmp/headroom.log" >&2
    tail -20 /tmp/headroom.log >&2 || true
    exit 1
  fi

  export ANTHROPIC_BASE_URL="http://127.0.0.1:${HEADROOM_PORT}"
  echo "headroom: ON  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
else
  if [[ -n "${ANTHROPIC_TARGET_API_URL:-}" ]]; then
    # No headroom layer — claude talks to vertex_proxy directly. Skip the
    # compression step but keep the gcloud-token-on-host routing.
    export ANTHROPIC_BASE_URL="${ANTHROPIC_TARGET_API_URL}"
    echo "headroom: OFF  vertex direct  ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL}"
  else
    echo "headroom: OFF"
  fi
fi

# fiss-mcp (Terra MCP). Server lives on the HOST; the launcher (run script)
# spawned it and passed its URL via FISS_MCP_URL. We register an HTTP MCP
# entry in ~/.claude.json pointing at that URL. FISS_MCP=0 removes the entry.
# Mutating .claude.json here is race-free — claude has not started yet.
#
# Note: ~/.claude.json is bind-mounted from the host, so rename(2) (`mv`) on
# it fails with EBUSY. We write the temp file, then overwrite in place with
# `cat > ...` to preserve the bind-mounted inode.
CLAUDE_JSON="${HOME}/.claude.json"
[ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

if [[ "${FISS_MCP:-1}" == "1" ]]; then
  if [[ -z "${FISS_MCP_URL:-}" ]]; then
    echo "fiss-mcp: WARNING — FISS_MCP=1 but FISS_MCP_URL is empty." >&2
    echo "          The host launcher did not advertise an MCP server. Skipping registration." >&2
    jq 'if .mcpServers? then .mcpServers |= del(.["fiss-mcp"]) else . end' \
       "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"
  else
    jq --arg url "${FISS_MCP_URL}" \
       '.mcpServers["fiss-mcp"] = {
          type: "http",
          url: $url
        }' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"

    if [[ "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
      # Second banner inside the container so the warning shows up even when
      # the host launcher's output has scrolled off, or when somebody execs
      # into a running container and restarts claude. Banner is pre-rendered
      # figlet output (font: standard) — no runtime figlet dependency.
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
      echo "${YEL}fiss-mcp (host) running with --allow-writes.${RST}"
      echo "${YEL}Agent can submit workflows and mutate workspace state.${RST}"
      echo "fiss-mcp: ON  ${FISS_MCP_URL}  (WRITE MODE)"
    else
      echo "fiss-mcp: ON  ${FISS_MCP_URL}  (read-only)"
    fi
  fi
else
  jq 'if .mcpServers? then .mcpServers |= del(.["fiss-mcp"]) else . end' \
     "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && cat "${CLAUDE_JSON}.tmp" > "$CLAUDE_JSON" && rm "${CLAUDE_JSON}.tmp"
  echo "fiss-mcp: OFF"
fi

# Run claude:
claude "$@"
