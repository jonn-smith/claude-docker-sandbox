#!/usr/bin/env bash
# Wrapper invoked by Claude Code as an MCP server (stdio).
# Read-only by default; honors FISS_MCP_ALLOW_WRITES=1 from the env passed
# by start_script.sh. Write mode is intentionally noisy at launch time —
# see the figlet banner in run_claude_docker.sh / start_script.sh.
set -euo pipefail

ARGS=(run /opt/fiss-mcp/src/terra_mcp/server.py)
if [[ "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
  ARGS+=(-- --allow-writes)
fi

exec /opt/fiss-mcp-venv/bin/fastmcp "${ARGS[@]}"
