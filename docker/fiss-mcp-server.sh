#!/usr/bin/env bash
# Wrapper invoked by Claude Code as an MCP server (stdio).
# Read-only by policy — --allow-writes is intentionally never passed, so the
# agent cannot submit workflows or mutate workspace state.
set -euo pipefail

exec /opt/fiss-mcp-venv/bin/fastmcp run /opt/fiss-mcp/src/terra_mcp/server.py
