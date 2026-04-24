#!/usr/bin/env bash

set -euo pipefail

wget https://downloads.nestybox.com/sysbox/releases/v0.6.7/sysbox-ce_0.6.7-0.linux_amd64.deb
sudo apt install ./sysbox-ce_0.6.7-0.linux_amd64.deb
# postinst restarts dockerd, registers sysbox-runc in /etc/docker/daemon.json

#Verify:
docker info | grep -i runtime
# Runtimes: io.containerd.runc.v2 runc sysbox-runc

