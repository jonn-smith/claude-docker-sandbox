#!/usr/bin/env bash

################################################################################

set -euo pipefail

################################################################################
echo "Installing essential packages..."

sudo apt update
sudo apt-get install -y git curl vim build-essential

################################################################################

echo "Installing docker"
# Add Docker's official GPG key:
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update

sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl start docker

echo "Adding current user: ${USER} to docker group"
getent group docker || sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker

################################################################################

echo "Installing sysbox for docker-in-a-docker support"
wget https://downloads.nestybox.com/sysbox/releases/v0.6.7/sysbox-ce_0.6.7-0.linux_amd64.deb
sudo apt install -y ./sysbox-ce_0.6.7-0.linux_amd64.deb
# postinst restarts dockerd, registers sysbox-runc in /etc/docker/daemon.json

#Verify:
sudo docker info | grep -i runtime
# Runtimes: io.containerd.runc.v2 runc sysbox-runc

################################################################################

# Must setup the postconf to include all subnets from docker images to get
# mail to forward properly:
# mynetworks = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
sudo DEBIAN_FRONTEND=noninteractive apt install -y postfix
echo "Updating postfix config file to use all local networks to enable email forwarding from inside the docker image."
echo -n "Previous value: "
postconf -h mynetworks

sudo postconf -e 'mynetworks = 127.0.0.0/8 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16'
sudo postfix reload
echo -n "New value: "
postconf -h mynetworks

################################################################################

################################################################################

# fiss-mcp (Terra MCP server) lives on the host, not in the container, so it
# needs a host-side venv. Done here once at setup time — the run script will
# refuse to launch with FISS_MCP=1 until this completes.
echo
echo "Installing host-side fiss-mcp (Terra MCP server)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not on PATH; installing python3 + venv"
  sudo apt-get install -y --no-install-recommends python3 python3-venv python3-pip
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${SCRIPT_DIR}/host_fiss_mcp/install.sh"

################################################################################

echo
echo
echo
echo
echo "YOU MUST LOG OUT AND LOG BACK IN FOR DOCKER GROUP SETTINGS TO PROPAGATE CORRECTLY"

