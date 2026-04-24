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
