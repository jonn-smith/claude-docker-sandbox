#!/usr/bin/env bash
# env.example.sh — defaults work on a fresh clone with no edits.
# Lives in envs/ alongside one env.<NAME>.sh per workspace.
#
# Source directly for the "main" shared-mode instance:
#   source envs/env.example.sh && ./run_claude_docker.sh
#
# For a new workspace, copy and tweak:
#   cp envs/env.example.sh envs/env.<NAME>.sh
#   $EDITOR envs/env.<NAME>.sh   # change CLAUDE_SANDBOX_INSTANCE, optionally paths
#   source envs/env.<NAME>.sh && ./run_claude_docker.sh
#
# Each env gets its own persistent state at persistent-states/<INSTANCE>/.
#
# PATHS: comments below label each path [HOST] (a path on your machine, where
# this script and the launcher run) or [CONTAINER] (a path inside the
# sandbox). HOST dirs get bind-mounted to CONTAINER mount points — most
# importantly [HOST] CLAUDE_SANDBOX_PROJECTS_DIR is mounted at [CONTAINER]
# /workspace. When a value is consumed by something running INSIDE the
# container (a hook, the agent), it must be a CONTAINER path.

# [HOST] Resolve repo root. This file lives in envs/, so repo root is the
# PARENT of its own directory — hence the /.. below. All ${__ENV_SCRIPT_DIR}
# defaults (context_reference, workspace) are HOST paths resolved against the
# repo root, then bind-mounted into the container by the launcher.
__ENV_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Read-only context dir. The value is a [HOST] path; the launcher bind-mounts
# it read-only to [CONTAINER] /context. Defaults to the context_reference/
# dir tracked in the repo (host).
export CLAUDE_SANDBOX_CONTEXT_DIR="${__ENV_SCRIPT_DIR}/context_reference"

# Instance ID — must be unique across concurrent sandboxes (gates DinD
# volume, container name, per-instance state dir).
export CLAUDE_SANDBOX_INSTANCE=main

# Project workspace. The value is a [HOST] path (absolute); the launcher
# bind-mounts it to [CONTAINER] /workspace. So any container-side "/workspace"
# path (hooks, the audit log) refers to THIS host dir. Defaults to a
# workspace/ dir next to this script (host), auto-created on first use.
# Override to point at your real project tree.
export CLAUDE_SANDBOX_PROJECTS_DIR="${__ENV_SCRIPT_DIR}/workspace"

# Optional: extra read-only bind mounts. Space-separated list of [HOST]
# DIRECTORIES (no container path — the launcher picks one). Each shows
# up at [CONTAINER] /read-only-reference/<basename>, with
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

# Optional raw journal audit trail. The journal-nudge.sh hook always
# reminds the agent to keep /workspace/JOURNAL.md (the curated research
# journal). Set this to 1 to ALSO append a guaranteed, mechanical
# "timestamp<TAB>prompt" line for every turn — a separate, exhaustive
# capture distinct from the curated journal. Off by default. Path defaults
# to /workspace/.journal-audit.log — a [CONTAINER] path (the hook writes it
# INSIDE the container). /workspace is the mount of CLAUDE_SANDBOX_PROJECTS_DIR,
# so this already lands in the project dir. If you override it, keep it a
# /workspace/… [CONTAINER] path, NOT a host path — a host path won't exist
# inside the container and the write will fail.
#
#export CLAUDE_JOURNAL_AUDIT=1
#export CLAUDE_JOURNAL_AUDIT_FILE=/workspace/.journal-audit.log

# Optional HuggingFace token. Only used for the one-time headroom model
# prefetch (HEADROOM=1). Unauthenticated HF downloads get rate-limited and
# are slow on a cold cache; a read token dodges that. Get one at
# https://huggingface.co/settings/tokens (read scope is enough). Passed to
# the download only, by name (never printed, never baked into the image).
# Unset → anonymous download (still works, just slower the first time).
#
#export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

# GPU graphics capability (WebGPU / Vulkan / GL). Only relevant on a GPU
# host — the launcher forwards the GPU with --gpus all and, by default,
# only the compute,utility driver caps (CUDA). WebGPU (Dawn) and any
# Vulkan/GL need the `graphics` cap so the NVIDIA runtime also mounts the
# host driver's GL/Vulkan userspace (ICD json, libGLX_nvidia, …). That
# widens the GPU-driver attack surface, so it's opt-in. Set to 1 for
# WebGPU/graphics work; leave unset for the minimal compute-only surface.
# (Note: GPU mode already runs under plain runc, not sysbox — see README.)
# Power users can instead set NVIDIA_DRIVER_CAPABILITIES directly.
#
#export CLAUDE_SANDBOX_GPU_GRAPHICS=1

unset __ENV_SCRIPT_DIR

