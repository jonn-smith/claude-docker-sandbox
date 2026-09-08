#!/usr/bin/env bash
# gpu-watch.sh — warn when a GPU-enabled sandbox has silently lost its GPU(s).
#
# The NVIDIA container stack has a long-standing bug: a running container can
# lose GPU access without exiting. The device gets dropped from the container's
# cgroup — classically triggered by a host-side `systemctl daemon-reload`
# (or anything that rewrites the systemd/cgroup tree while the container runs).
# After that, nvidia-smi inside the container fails with
#     Failed to initialize NVML: Unknown Error
# even though /dev/nvidia* may still be present, and every CUDA call in the
# sandbox breaks until the container is relaunched.
# Refs: NVIDIA/nvidia-container-toolkit issues #48 / #1730.
#
# This hook fires on UserPromptSubmit so a lost GPU is surfaced the moment you
# start the next turn — before you (or the agent) waste time on CUDA work that
# will fail. It is a strict NO-OP unless the launcher marked this instance
# GPU-enabled (CLAUDE_SANDBOX_GPU=1), so CPU / macOS sandboxes pay nothing.
# CLAUDE_SANDBOX_GPU_COUNT carries how many GPUs were visible at launch, so a
# partial drop (some devices fell out) is caught too.
#
# Output goes to stdout, which UserPromptSubmit injects as prompt context —
# the agent sees it and relays it. Always exits 0; never blocks a prompt.
#
# Wired in settings.json under UserPromptSubmit.

# Only relevant when this sandbox was launched with GPU access.
[[ "${CLAUDE_SANDBOX_GPU:-0}" == "1" ]] || exit 0

# nvidia-smi is mounted into the container by the NVIDIA runtime. If it's gone
# while we were launched with a GPU, the GPU stack itself has dropped out.
if ! command -v nvidia-smi >/dev/null 2>&1; then
  cat <<'MSG'
⚠️  GPU LOST — this sandbox was launched with GPU access, but nvidia-smi is no
    longer present in the container. The NVIDIA runtime mount has dropped out.
    CUDA work will fail until you exit and re-run run_claude_docker.sh.
MSG
  exit 0
fi

# Bound the query: a wedged driver can make nvidia-smi hang. Don't hang the prompt.
smi() {
  if command -v timeout >/dev/null 2>&1; then timeout 8 nvidia-smi "$@"; else nvidia-smi "$@"; fi
}

out="$(smi --query-gpu=name --format=csv,noheader 2>&1)"
rc=$?

if [[ $rc -ne 0 || -z "${out// /}" ]]; then
  cat <<MSG
⚠️  GPU LOST — this sandbox was launched with GPU access, but nvidia-smi now fails:
    ${out}
    Known NVIDIA container bug: the GPU was dropped from the container cgroup
    (often after a host \`systemctl daemon-reload\`). CUDA is dead until relaunch.
    Fix: exit this sandbox and re-run run_claude_docker.sh. On the host, avoid
    daemon-reload while GPU sandboxes run, or upgrade nvidia-container-toolkit.
MSG
  exit 0
fi

# Healthy nvidia-smi, but did we lose some of the GPUs we started with?
now=$(printf '%s\n' "$out" | grep -c .)
want="${CLAUDE_SANDBOX_GPU_COUNT:-1}"
if [[ "$now" =~ ^[0-9]+$ && "$want" =~ ^[0-9]+$ && "$now" -lt "$want" ]]; then
  echo "⚠️  GPU COUNT DROPPED — started with ${want} GPU(s), now see ${now}. Some devices"
  echo "    fell out of the container cgroup (NVIDIA daemon-reload bug). Relaunch the"
  echo "    sandbox to recover all ${want}."
fi
exit 0
