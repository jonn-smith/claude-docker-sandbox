#!/usr/bin/env bash

set -euo pipefail

echo "Installing sysbox for docker-in-a-docker support"
wget https://downloads.nestybox.com/sysbox/releases/v0.6.7/sysbox-ce_0.6.7-0.linux_amd64.deb
sudo apt install ./sysbox-ce_0.6.7-0.linux_amd64.deb
# postinst restarts dockerd, registers sysbox-runc in /etc/docker/daemon.json

#Verify:
docker info | grep -i runtime
# Runtimes: io.containerd.runc.v2 runc sysbox-runc

################################################################################

# Must setup the postconf to include all subnets from docker images to get
# mail to forward properly:
# mynetworks = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
echo "Updating postfix config file to use all local networks to enable email forwarding from inside the docker image."
echo -n "Previous value: "
postconf -h mynetworks

sudo postconf -e 'mynetworks = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
sudo postfix reload
echo -n "New value: "
postconf -h mynetworks

