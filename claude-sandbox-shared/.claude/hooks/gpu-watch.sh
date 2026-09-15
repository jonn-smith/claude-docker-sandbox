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
# Fires on BOTH UserPromptSubmit and Stop, so a lost GPU is caught either at
# the start of your next turn OR the moment Claude finishes a long turn —
# whichever comes first. Strict NO-OP unless the launcher marked this instance
# GPU-enabled (CLAUDE_SANDBOX_GPU=1); CPU/macOS sandboxes pay nothing.
# CLAUDE_SANDBOX_GPU_COUNT carries the GPU count seen at launch, so a partial
# drop (some devices fell out) is caught too.
#
# Surfacing differs by event, because Claude Code treats hook stdout
# differently per event:
#   - UserPromptSubmit: stdout is injected as prompt context -> the agent sees
#     the warning and relays it. Always emitted when the GPU is down.
#   - Stop: stdout only shows in transcript mode, so for a real turn-end
#     notification we ALSO send an email (same curl-smtp path as
#     notify-if-long.sh) when CLAUDE_NOTIFY_EMAIL is set. Deduped via a state
#     file so it emails once on the healthy->lost transition, not every turn.
#
# Always exits 0; never blocks a prompt or a stop.
#
# Wired in settings.json under UserPromptSubmit and Stop.

# Only relevant when this sandbox was launched with GPU access.
[[ "${CLAUDE_SANDBOX_GPU:-0}" == "1" ]] || exit 0

# Bound the query: a wedged driver can make nvidia-smi hang. Don't hang the turn.
smi() {
  if command -v timeout >/dev/null 2>&1; then timeout 8 nvidia-smi "$@"; else nvidia-smi "$@"; fi
}

# --- assess GPU health -> LOST (0/1) + human-readable $warn -----------------
LOST=0
warn=""
if ! command -v nvidia-smi >/dev/null 2>&1; then
  LOST=1
  warn="⚠️  GPU LOST — this sandbox was launched with GPU access, but nvidia-smi is
    no longer present in the container. The NVIDIA runtime mount has dropped out.
    CUDA work will fail until you exit and re-run run_claude_docker.sh."
else
  out="$(smi --query-gpu=name --format=csv,noheader 2>&1)"
  rc=$?
  if [[ $rc -ne 0 || -z "${out// /}" ]]; then
    LOST=1
    warn="⚠️  GPU LOST — this sandbox was launched with GPU access, but nvidia-smi now fails:
    ${out}
    Known NVIDIA container bug: the GPU was dropped from the container cgroup
    (often after a host \`systemctl daemon-reload\`). CUDA is dead until relaunch.
    Fix: exit this sandbox and re-run run_claude_docker.sh. On the host, avoid
    daemon-reload while GPU sandboxes run, or upgrade nvidia-container-toolkit."
  else
    now=$(printf '%s\n' "$out" | grep -c .)
    want="${CLAUDE_SANDBOX_GPU_COUNT:-1}"
    if [[ "$now" =~ ^[0-9]+$ && "$want" =~ ^[0-9]+$ && "$now" -lt "$want" ]]; then
      LOST=1
      warn="⚠️  GPU COUNT DROPPED — started with ${want} GPU(s), now see ${now}. Some devices
    fell out of the container cgroup (NVIDIA daemon-reload bug). Relaunch the
    sandbox to recover all ${want}."
    fi
  fi
fi

# State file for email dedupe. Per-instance: ~/.claude/cache is bind-mounted
# per-instance even in shared mode, so two GPU sandboxes don't clobber each
# other's last-known state.
STATE_FILE="${HOME}/.claude/cache/.gpu-watch-last"
prev="$(cat "$STATE_FILE" 2>/dev/null || echo ok)"

if [[ "$LOST" -eq 0 ]]; then
  printf 'ok' > "$STATE_FILE" 2>/dev/null || true
  exit 0
fi

# GPU is down. Always emit to stdout (context on UserPromptSubmit; transcript
# on Stop).
printf '%s\n' "$warn"

# Event-aware email. Read the hook payload only now (lost path), pull the event
# name with a cheap grep (no parser fork on the healthy path).
payload="$(cat 2>/dev/null)"
event="$(printf '%s' "$payload" | grep -o '"hook_event_name":"[^"]*"' | head -1 | sed 's/.*":"//;s/"$//')"

# Email once on the healthy->lost transition, on Stop, if configured. Same
# curl-smtp mechanism as notify-if-long.sh.
if [[ "$event" == "Stop" && "$prev" != "lost" && -n "${CLAUDE_NOTIFY_EMAIL:-}" ]]; then
  ip="$(ip route 2>/dev/null | awk '/default/ {print $3; exit}')"
  host="${CLAUDE_NOTIFY_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
  from="${CLAUDE_NOTIFY_FROM:-claude-sandbox}"
  inst="${CLAUDE_SANDBOX_INSTANCE:-sandbox}"
  if [[ -n "$ip" ]]; then
    curl -s "smtp://${ip}:25" --insecure \
      --mail-from "${from}@${host}" \
      --mail-rcpt "${CLAUDE_NOTIFY_EMAIL}" \
      --upload-file - >/dev/null 2>&1 <<EOF || true
Message-ID: <$(date +%s%N)@${host}>
Date: $(date -R)
Subject: [Claude] GPU LOST on ${inst} (pwd:$(basename "$PWD"))
From: ${from}@${host}
To: ${CLAUDE_NOTIFY_EMAIL}

${warn}

Instance: ${inst}
Project:  $(basename "$PWD")
Host:     ${host}
Time:     $(date -u +%Y-%m-%dT%H:%M:%SZ)

Recover: exit the sandbox and re-run run_claude_docker.sh.
EOF
  fi
fi

printf 'lost' > "$STATE_FILE" 2>/dev/null || true
exit 0
