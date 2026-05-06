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

# Instance ID — must be unique across concurrent sandboxes (gates DinD
# volume, container name, per-instance state dir).
export CLAUDE_SANDBOX_INSTANCE=main

# Shared-state layout: settings, skills, plugins, hooks, memory, sessions
# come from claude-sandbox-shared/. Set to 0 for fully isolated per-instance
# state.
export CLAUDE_SANDBOX_USE_SHARED=1

# Optional: turn the Headroom token-compression proxy on for this instance.
#export HEADROOM=1

# Project workspace, bind-mounted to /workspace inside the container. Must
# be an absolute path. Defaults to a workspace/ dir next to this script,
# auto-created on first use. Override to point at your real project tree.
export CLAUDE_SANDBOX_PROJECTS_DIR="${__ENV_SCRIPT_DIR}/workspace"
mkdir -p "${CLAUDE_SANDBOX_PROJECTS_DIR}"

# Read-only context dir, bind-mounted to /context. Defaults to the
# context_reference/ dir tracked in the repo.
export CLAUDE_SANDBOX_CONTEXT_DIR="${__ENV_SCRIPT_DIR}/context_reference"

unset __ENV_SCRIPT_DIR
