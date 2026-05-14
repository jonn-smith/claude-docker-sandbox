#!/usr/bin/env bash
set -euo pipefail

# Start the postfix service for mail notifications:
service postfix start

# Start the docker service so we can run docker in a docker for tests:
~/start_dockerd.sh

# Headroom proxy (opt-in, set HEADROOM=1 at launch).
# When on, intercepts Claude Code traffic on localhost:$HEADROOM_PORT and
# compresses prompts/tool outputs before forwarding to api.anthropic.com.
# Process dies with the container; no persistent state.
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

  echo "headroom: starting on :${HEADROOM_PORT}"
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
  echo "headroom: OFF"
fi

# fiss-mcp (Terra MCP). FISS_MCP=1 (default) registers the server in
# ~/.claude.json so claude can find it; FISS_MCP=0 removes the entry.
# Mutating .claude.json here is race-free because claude has not started yet.
CLAUDE_JSON="${HOME}/.claude.json"
[ -s "$CLAUDE_JSON" ] || echo '{}' > "$CLAUDE_JSON"

if [[ "${FISS_MCP:-1}" == "1" ]]; then
  if [[ ! -d "${HOME}/.config/gcloud" && -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    echo "fiss-mcp: WARNING — no gcloud config mounted and GOOGLE_APPLICATION_CREDENTIALS unset." >&2
    echo "          MCP server will register but Terra calls will fail until auth is present." >&2
    echo "          Run 'gcloud auth login && gcloud auth application-default login' on the host." >&2
  fi
  jq --arg cmd /usr/local/bin/fiss-mcp-server \
     --arg allow "${FISS_MCP_ALLOW_WRITES:-0}" \
     '.mcpServers["fiss-mcp"] = {
        type: "stdio",
        command: $cmd,
        args: [],
        env: { FISS_MCP_ALLOW_WRITES: $allow }
      }' "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"

  if [[ "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
    # Second banner inside the container so the warning shows up even when
    # the host launcher's output has scrolled off, or when somebody execs
    # into a running container and restarts claude.
    RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
    echo
    echo "${RED}"
    if command -v figlet >/dev/null 2>&1; then
      figlet -w 120 "FISS WRITE MODE"
    else
      echo "##############################################################"
      echo "#  F I S S - M C P   W R I T E   M O D E   E N A B L E D     #"
      echo "##############################################################"
    fi
    echo "${YEL}fiss-mcp registered with --allow-writes.${RST}"
    echo "${YEL}Agent can submit workflows and mutate workspace state.${RST}"
    echo "${RST}"
    echo "fiss-mcp: ON  (WRITE MODE — agent has Terra write access)"
  else
    echo "fiss-mcp: ON  (read-only)"
  fi
else
  jq 'if .mcpServers? then .mcpServers |= del(.["fiss-mcp"]) else . end' \
     "$CLAUDE_JSON" > "${CLAUDE_JSON}.tmp" && mv "${CLAUDE_JSON}.tmp" "$CLAUDE_JSON"
  echo "fiss-mcp: OFF"
fi

# Run claude:
claude "$@"
