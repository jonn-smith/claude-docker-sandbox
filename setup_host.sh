#!/usr/bin/env bash

################################################################################

set -euo pipefail

################################################################################
echo "Installing essential packages..."

sudo apt update
sudo apt-get install -y git curl vim build-essential fzf

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

# Docker 29.x is incompatible with sysbox-runc (any version, including 0.6.7 and
# 0.7.0): containers fail to start with
#   OCI runtime create failed: namespace {"time" ""} does not exist
# Upstream bug: https://github.com/nestybox/sysbox/issues/1011 (open, no fix).
# Pin to the newest 5:28.* available in the repo and hold it so apt upgrade
# won't silently break the sandbox. If no 28.x is available we abort rather
# than install a known-broken combination.
DOCKER_PIN_VERSION="$(apt-cache madison docker-ce 2>/dev/null \
    | awk '{print $3}' \
    | grep -E '^5:28\.' \
    | sort -V \
    | tail -n1 || true)"
DOCKER_CLI_PIN_VERSION="$(apt-cache madison docker-ce-cli 2>/dev/null \
    | awk '{print $3}' \
    | grep -E '^5:28\.' \
    | sort -V \
    | tail -n1 || true)"

if [[ -z "${DOCKER_PIN_VERSION}" || -z "${DOCKER_CLI_PIN_VERSION}" ]]; then
  echo "ERROR: no docker-ce 28.x in the Docker apt repo for this distro." >&2
  echo "Docker 29.x is incompatible with sysbox-runc (sysbox issue #1011)." >&2
  echo "Cannot continue without a known-good Docker version." >&2
  exit 1
fi

echo "Pinning docker-ce to ${DOCKER_PIN_VERSION} (Docker 29.x breaks sysbox-runc)."
sudo apt install -y \
  "docker-ce=${DOCKER_PIN_VERSION}" \
  "docker-ce-cli=${DOCKER_CLI_PIN_VERSION}" \
  containerd.io docker-buildx-plugin docker-compose-plugin
sudo apt-mark hold docker-ce docker-ce-cli
sudo systemctl start docker

echo "Adding current user: ${USER} to docker group"
getent group docker || sudo groupadd docker
sudo usermod -aG docker $USER

################################################################################

echo "Installing sysbox for docker-in-a-docker support"
wget https://downloads.nestybox.com/sysbox/releases/v0.6.7/sysbox-ce_0.6.7-0.linux_amd64.deb
sudo apt install -y ./sysbox-ce_0.6.7-0.linux_amd64.deb
# postinst restarts dockerd, registers sysbox-runc in /etc/docker/daemon.json

#Verify:
sudo docker info | grep -i runtime
# Runtimes: io.containerd.runc.v2 runc sysbox-runc

# Smoke test: confirm sysbox-runc can actually start a container. This catches
# the Docker/sysbox version mismatch (sysbox issue #1011) and other runtime
# breakage before the user hits it from run_claude_docker.sh.
echo "Smoke-testing sysbox-runc with hello-world..."
if ! sudo docker run --rm --runtime=sysbox-runc hello-world >/dev/null 2>&1; then
  RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo
  echo "${RED}ERROR:${RST} ${YEL}sysbox-runc smoke test failed.${RST}"
  echo "${YEL}Re-run manually to see the error:${RST}"
  echo "${YEL}    sudo docker run --rm --runtime=sysbox-runc hello-world${RST}"
  echo "${YEL}If you see 'namespace {\"time\" \"\"} does not exist', your Docker is${RST}"
  echo "${YEL}newer than what sysbox supports. See:${RST}"
  echo "${YEL}    https://github.com/nestybox/sysbox/issues/1011${RST}"
  exit 1
fi
echo "sysbox-runc smoke test passed."

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

# fiss-mcp (Terra MCP server) lives on the host, not in the container, so it
# needs a host-side venv. Done here once at setup time — the run script will
# refuse to launch with FISS_MCP=1 until this completes.
echo
echo "Installing host-side fiss-mcp (Terra MCP server)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 not on PATH; installing python3 + venv"
  sudo apt-get install -y --no-install-recommends python3 python3-venv python3-pip
fi

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
bash "${SCRIPT_DIR}/host_fiss_mcp/install.sh"

################################################################################

# gcloud check for Vertex mode. The vertex_proxy.py script mints OAuth tokens
# via `gcloud auth print-access-token`, so Vertex mode is dead-in-the-water
# without gcloud on PATH. We intentionally do NOT install it here — picking a
# distribution channel (apt repo / snap / Google's install script) is a host
# policy decision. Just warn loudly so the user can act if they care.
echo
echo "Checking for gcloud (required only for Vertex mode)..."
if command -v gcloud >/dev/null 2>&1; then
  echo "gcloud: found at $(command -v gcloud)"
else
  RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo
  echo "${RED}WARNING:${RST} ${YEL}gcloud is not on PATH.${RST}"
  echo "${YEL}Vertex mode (CLAUDE_CODE_USE_VERTEX=1) will not work until gcloud is${RST}"
  echo "${YEL}installed and authenticated:${RST}"
  echo "${YEL}    gcloud auth login${RST}"
  echo "${YEL}    gcloud auth application-default login${RST}"
  echo "${YEL}Anthropic-API (default) mode does not need gcloud and is unaffected.${RST}"
  echo
fi

################################################################################

echo
echo
echo
echo
echo "YOU MUST LOG OUT AND LOG BACK IN FOR DOCKER GROUP SETTINGS TO PROPAGATE CORRECTLY"

