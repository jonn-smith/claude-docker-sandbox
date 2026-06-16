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

# fiss-mcp (Terra MCP server). FISS_MCP=1 (default) makes the launcher spawn
# a host-side fiss-mcp server before docker run, then registers it in the
# container's MCP config as an HTTP endpoint at host.docker.internal:<PORT>.
# The server is killed automatically when this launch exits (trap on EXIT).
# FISS_MCP=0 skips spawn + registration entirely.
#
# Why host-side: the container has NO gcloud / gsutil / google-cloud-* libs
# and NO ~/.config/gcloud mount. The only reachable path from inside the
# sandbox to Terra/GCP is the MCP tools — and the server is read-only by
# default, so the agent cannot mutate state from inside the container.
#
# Auth: the host server inherits the host's gcloud creds. On a workstation,
# run `gcloud auth login` + `gcloud auth application-default login` once.
# On a GCE VM the default service account is picked up via metadata server.
#
# FISS_MCP_ALLOW_WRITES=1 starts the host server with write mode enabled —
# the agent can then submit workflows, mutate workspace attributes, and
# spend money on your Terra/GCP account. Leave at 0 unless you know exactly
# what you want. Write mode is intentionally loud: a red banner prints on
# the host launcher AND inside the container at startup so it is impossible
# to miss.
#
# FISS_MCP_PORT overrides the auto-computed host port (default: hashed from
# CLAUDE_SANDBOX_INSTANCE into 39000-39999).
export FISS_MCP=1
export FISS_MCP_ALLOW_WRITES=0
#export FISS_MCP_PORT=39042

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

# Optional: extra read-only bind mounts. Space-separated list of host
# DIRECTORIES (no container path — the launcher picks one). Each shows
# up at /read-only-reference/<basename> inside the container, with
# parent-dir prefixes joined by underscores on basename collision
# (/a/b/data + /x/y/data → /read-only-reference/b_data and
# /read-only-reference/y_data). Host path must exist; mounts are
# appended :ro so the agent can read but never write.
#
#export CLAUDE_SANDBOX_RO_MOUNTS="/data/reference /srv/corpus"

# --shm-size override for the sandbox container. Docker's default 64 MB
# /dev/shm is too small for Chromium/Playwright, PyTorch DataLoader
# workers, and other multi-process consumers. Set this when those
# workloads inside the sandbox fail with "No space left on device" on
# /dev/shm or similar shared-memory errors. Format is Docker's: 512m,
# 2g, 4g, etc. Unset → Docker default (64 MB).
#
#export CLAUDE_SANDBOX_SHM_SIZE=2g

unset __ENV_SCRIPT_DIR

