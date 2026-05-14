#!/usr/bin/env bash
# env.example.sh — defaults work on a fresh clone with no edits.
#
# Source directly for the "main" shared-mode instance:
#   source env.example.sh && ./run_claude_docker.sh
#
# For a second instance, copy and tweak:
#   cp env.example.sh env.<NAME>.sh
#   $EDITOR env.<NAME>.sh   # change CLAUDE_SANDBOX_INSTANCE, optionally paths
#   source env.<NAME>.sh && ./run_claude_docker.sh

# Resolve repo root regardless of where this file is sourced from.
__ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared-state layout: settings, skills, plugins, hooks, memory, sessions
# come from claude-sandbox-shared/. Set to 0 for fully isolated per-instance
# state.
export CLAUDE_SANDBOX_USE_SHARED=1

# Optional: turn the Headroom token-compression proxy on for this instance.
export HEADROOM=1

# fiss-mcp (Terra MCP server). FISS_MCP=1 (default) registers the server in
# claude's MCP config on launch; FISS_MCP=0 removes it.
#
# FISS_MCP_ALLOW_WRITES=1 starts the server with --allow-writes — the agent
# can then submit workflows, mutate workspace attributes, and spend money
# on your Terra/GCP account. Leave at 0 unless you know exactly what you
# want. Write mode is intentionally loud: a red figlet banner prints on
# the host launcher AND inside the container at startup so it is impossible
# to miss.
#
# Auth comes from the host: the launcher bind-mounts ~/.config/gcloud into
# the container (set up via `gcloud auth login` + `gcloud auth
# application-default login` on the host once). Set
# GOOGLE_APPLICATION_CREDENTIALS to a key-file path here to override with a
# service account, or GOOGLE_CLOUD_PROJECT to pin the project.
export FISS_MCP=1
export FISS_MCP_ALLOW_WRITES=0
#export GOOGLE_APPLICATION_CREDENTIALS=/path/to/sa-key.json
#export GOOGLE_CLOUD_PROJECT=your-gcp-project-id

# Email notifications when a Claude task takes longer than the threshold in
# claude-sandbox-shared/.claude/hooks/notify-if-long.sh. Leave
# CLAUDE_NOTIFY_EMAIL unset/empty to disable. CLAUDE_NOTIFY_FROM and
# CLAUDE_NOTIFY_HOSTNAME shape the From/Message-ID headers; they default to
# "claude-sandbox" and the host's $(hostname -f) if not set.
#export CLAUDE_NOTIFY_EMAIL=you@example.com
#export CLAUDE_NOTIFY_FROM=claude-sandbox
#export CLAUDE_NOTIFY_HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# Read-only context dir, bind-mounted to /context. Defaults to the
# context_reference/ dir tracked in the repo.
export CLAUDE_SANDBOX_CONTEXT_DIR="${__ENV_SCRIPT_DIR}/context_reference"

# Instance ID — must be unique across concurrent sandboxes (gates DinD
# volume, container name, per-instance state dir).
export CLAUDE_SANDBOX_INSTANCE=main

# Project workspace, bind-mounted to /workspace inside the container. Must
# be an absolute path. Defaults to a workspace/ dir next to this script,
# auto-created on first use. Override to point at your real project tree.
export CLAUDE_SANDBOX_PROJECTS_DIR="${__ENV_SCRIPT_DIR}/workspace"

unset __ENV_SCRIPT_DIR

