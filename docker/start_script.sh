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

# Run claude:
claude "$@"
