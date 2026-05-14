#!/usr/bin/env bash
# Wrapper invoked by Claude Code as an MCP server (stdio).
# Honors FISS_MCP_ALLOW_WRITES=1 to enable Terra write ops.
set -euo pipefail

ARGS=(run /opt/fiss-mcp/src/terra_mcp/server.py)
if [[ "${FISS_MCP_ALLOW_WRITES:-0}" == "1" ]]; then
  ARGS+=(-- --allow-writes)
fi

exec /opt/fiss-mcp-venv/bin/fastmcp "${ARGS[@]}"
