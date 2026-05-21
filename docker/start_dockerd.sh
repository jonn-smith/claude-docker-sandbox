#!/usr/bin/env bash
# Start dockerd inside this container (Docker-in-Docker).
#
# Prerequisites (host must launch the container with):
#   --privileged --cgroupns=host \
#   -v claude-dind-lib:/var/lib/docker \
#   -v claude-dind-run:/var/run
#
# Then inside the container run: bash scripts/dind/start_dockerd.sh
set -euo pipefail

LOG=/tmp/dockerd.log

# Launcher sets SANDBOX_HAS_DIND=0 when the container is running under plain
# runc (e.g. with --gpus all, since sysbox-runc has no GPU passthrough — see
# nestybox/sysbox#50). Plain runc cannot mount overlay2 for a nested dockerd,
# so don't even try; the daemon would just fail with
#   "failed to mount overlay: operation not permitted"
#   "error initializing graphdriver: driver not supported"
if [[ "${SANDBOX_HAS_DIND:-1}" != "1" ]]; then
  YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo "${YEL}dockerd: SKIPPED — container is not running under sysbox-runc.${RST}"
  echo "${YEL}         Docker-in-Docker is disabled in this session.${RST}"
  exit 0
fi

if [ -S /var/run/docker.sock ] && sudo docker info >/dev/null 2>&1; then
    echo "dockerd already reachable via /var/run/docker.sock"
    sudo docker version
    exit 0
fi

echo "==> starting dockerd (log: ${LOG})"
sudo bash -c "nohup dockerd \
    --host=unix:///var/run/docker.sock \
    --storage-driver=overlay2 \
    --iptables=false \
    > '${LOG}' 2>&1 &"

echo "==> waiting for daemon socket"
for i in $(seq 1 30); do
    if sudo docker info >/dev/null 2>&1; then
        echo "dockerd ready after ${i}s"
        sudo docker version
        # Make the socket world-readable so the claude user can speak to it
        # without a new login shell (usermod -aG takes effect only on re-login).
        sudo chmod 666 /var/run/docker.sock
        exit 0
    fi
    sleep 1
done

echo "dockerd did not come up in 30s — last 40 log lines:" >&2
tail -40 "${LOG}" >&2
exit 1
