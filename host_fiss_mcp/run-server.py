#!/usr/bin/env python3
"""Host-side launcher for fiss-mcp over HTTP.

fastmcp's `fastmcp run` CLI imports the server module, which skips the
__main__ block in terra_mcp.server.py — so its `--allow-writes` argparse
flag never runs. We reuse the same module-level `mcp` object but set
`ALLOW_WRITES` from env, then drive the HTTP transport directly via
`mcp.run(transport='http', ...)`.

Env vars:
  FISS_MCP_HOST           bind host  (default 127.0.0.1)
  FISS_MCP_PORT           bind port  (default 39000)
  FISS_MCP_PATH           HTTP path  (default /mcp/)
  FISS_MCP_ALLOW_WRITES   "1" enables write tools (default 0; read-only)
"""

from __future__ import annotations

import os
import sys

import terra_mcp.server as server

allow_writes = os.environ.get("FISS_MCP_ALLOW_WRITES", "0") == "1"
server.ALLOW_WRITES = allow_writes

host = os.environ.get("FISS_MCP_HOST", "127.0.0.1")
port = int(os.environ.get("FISS_MCP_PORT", "39000"))
path = os.environ.get("FISS_MCP_PATH", "/mcp/")

mode = "WRITE" if allow_writes else "read-only"
print(
    f"host_fiss_mcp: starting on http://{host}:{port}{path} ({mode})",
    file=sys.stderr,
    flush=True,
)

server.mcp.run(transport="http", host=host, port=port, path=path)
