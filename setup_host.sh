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

# python3 is preinstalled on most Debian/Ubuntu, but python3-venv and
# python3-pip are SEPARATE packages and are NOT preinstalled — so a bare
# `command -v python3` test passed while `python3 -m venv` later blew up
# with "ensurepip is not available". Install all three unconditionally;
# apt is idempotent so this is cheap when they're already present.
echo "Ensuring python3 + python3-venv + python3-pip are installed"
sudo apt-get install -y --no-install-recommends python3 python3-venv python3-pip

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

# GPU-host workaround for NVIDIA/nvidia-docker issue #1730.
#
# Symptom: containers with --gpus all silently lose GPU access mid-workload
# whenever `systemctl daemon-reload` runs on the host. apt-get installs,
# kernel updates, security patches, and CUDA toolkit installs all trigger
# the reload, which yanks GPU device cgroups out from under running
# containers. NVML stops responding on the next call; no error inside the
# container.
#
# Fix (NVIDIA-recommended per issue #1730):
# `nvidia-ctk system create-dev-char-symlinks --create-all` pre-creates
# /dev/char/ device-node symlinks so the cgroup detach doesn't take the
# devices out from under running containers. We run it once now (covers
# the current boot) AND install a systemd oneshot unit that re-runs it at
# every boot (covers reboots).
#
# CPU-only hosts: nvidia-smi/nvidia-ctk absent → this whole block is a
# silent no-op.
echo
echo "Checking for GPU + nvidia-container-toolkit (NVIDIA bug #1730 workaround)..."
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "GPU: no nvidia-smi on PATH — CPU-only host, skipping GPU workaround."
elif ! nvidia-smi -L >/dev/null 2>&1; then
  echo "GPU: nvidia-smi present but reports no GPUs — skipping workaround."
elif ! command -v nvidia-ctk >/dev/null 2>&1; then
  RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'
  echo
  echo "${RED}WARNING:${RST} ${YEL}nvidia-ctk is not on PATH but GPUs are present.${RST}"
  echo "${YEL}This host needs nvidia-container-toolkit >= 1.12 to apply the${RST}"
  echo "${YEL}fix for NVIDIA/nvidia-docker issue #1730. Without it, sandboxed${RST}"
  echo "${YEL}GPU workloads will silently lose GPU access every time anything${RST}"
  echo "${YEL}on the host triggers \`systemctl daemon-reload\` (apt-get, kernel${RST}"
  echo "${YEL}updates, etc). Install per:${RST}"
  echo "${YEL}    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html${RST}"
  echo "${YEL}then re-run this script.${RST}"
  echo
else
  # Best-effort version check. nvidia-ctk's output format isn't formally
  # stable but the first line has historically been "NVIDIA Container
  # Toolkit CLI version X.Y.Z". If parsing fails we proceed anyway —
  # missing the fix on an old toolkit is no worse than the current state.
  NCT_VER=$(nvidia-ctk --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  if [[ -n "${NCT_VER:-}" ]]; then
    NCT_MAJ=${NCT_VER%%.*}
    NCT_REST=${NCT_VER#*.}
    NCT_MIN=${NCT_REST%%.*}
    if [[ "${NCT_MAJ:-0}" -lt 1 ]] || { [[ "${NCT_MAJ:-0}" -eq 1 ]] && [[ "${NCT_MIN:-0}" -lt 12 ]]; }; then
      YEL=$'\033[1;33m'; RST=$'\033[0m'
      echo "${YEL}WARNING: nvidia-ctk ${NCT_VER} is older than 1.12 — create-dev-char-symlinks may not exist. Proceeding anyway.${RST}"
    else
      echo "nvidia-ctk: found ${NCT_VER}"
    fi
  fi

  # Run the fix now (covers the current boot, no reboot required).
  echo "Applying nvidia-ctk create-dev-char-symlinks for the current boot..."
  if sudo nvidia-ctk system create-dev-char-symlinks --create-all 2>&1 | sed 's/^/  /'; then
    echo "GPU: dev-char symlinks created."
  else
    echo "GPU: create-dev-char-symlinks failed — see output above; continuing." >&2
  fi

  # Install + enable the systemd unit so the fix re-applies at boot.
  # WantedBy=multi-user.target so it runs after the standard graphical or
  # multi-user boot path; After/Wants nvidia-persistenced so the device
  # nodes exist before we touch them.
  UNIT_PATH=/etc/systemd/system/nvidia-symlinks.service
  if [[ ! -f "$UNIT_PATH" ]]; then
    echo "Installing nvidia-symlinks.service systemd oneshot at $UNIT_PATH..."
    sudo tee "$UNIT_PATH" >/dev/null <<'UNIT'
[Unit]
Description=Pre-create NVIDIA device char symlinks for container GPU access (NVIDIA bug #1730 fix)
After=nvidia-persistenced.service
Wants=nvidia-persistenced.service

[Service]
Type=oneshot
ExecStart=/usr/bin/nvidia-ctk system create-dev-char-symlinks --create-all
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
  else
    echo "nvidia-symlinks.service already installed; leaving alone."
  fi
  if ! systemctl is-enabled --quiet nvidia-symlinks.service 2>/dev/null; then
    sudo systemctl enable nvidia-symlinks.service
  fi
  echo "GPU: nvidia-symlinks.service enabled (re-applies fix on every boot)."
fi

################################################################################

echo
echo
echo
echo
echo "YOU MUST LOG OUT AND LOG BACK IN FOR DOCKER GROUP SETTINGS TO PROPAGATE CORRECTLY"

