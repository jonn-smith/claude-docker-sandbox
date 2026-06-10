#!/usr/bin/env bash
# setup_host_macos.sh — macOS host bootstrap.
#
# Invoked via ../setup_host.sh on Darwin hosts. Sets up everything the
# sandbox needs to launch from a fresh macOS install (Apple Silicon or
# Intel) — Homebrew, a Docker engine, the supporting coreutils, the
# host-side fiss-mcp venv. Mail-notification relay setup is documented
# but not automated (credentials are personal).
#
# Non-coverage:
#   - sysbox-runc: Linux-only. The Docker Desktop VM provides equivalent
#     isolation via Hypervisor.framework; see README "macOS limitations".
#   - NVIDIA / CUDA: impossible on macOS (no NVIDIA hardware, no Metal-
#     to-container bridge).
#   - DinD: disabled by default on macOS in run_claude_docker.sh
#     (SANDBOX_HAS_DIND=0). Docker Desktop's nested-VM path makes inner
#     dockerd slow and weakly isolated; not worth wiring up by default.
set -euo pipefail

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; GRN=$'\033[1;32m'; RST=$'\033[0m'

echo "${GRN}== macOS host bootstrap ==${RST}"
echo

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "${RED}ERROR: this script targets macOS. Got uname=$(uname -s).${RST}" >&2
  exit 1
fi

# Architecture probe — Homebrew lives in different prefixes on Apple
# Silicon (/opt/homebrew) vs Intel (/usr/local), and the docker / orbstack
# casks are arch-aware so we want this in the log up front.
ARCH=$(uname -m)
echo "arch:    $ARCH"
case "$ARCH" in
  arm64) BREW_PREFIX=/opt/homebrew ;;
  x86_64) BREW_PREFIX=/usr/local ;;
  *) echo "${YEL}WARNING: unfamiliar arch '$ARCH'; assuming /opt/homebrew.${RST}"; BREW_PREFIX=/opt/homebrew ;;
esac
echo "prefix:  $BREW_PREFIX"
echo

################################################################################

echo "${GRN}-- Homebrew --${RST}"
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not on PATH. Installing..."
  # Official installer. NONINTERACTIVE skips the password / Enter prompts
  # so this can run unattended; the install script still needs to ask
  # for sudo at least once for /usr/local or /opt/homebrew creation.
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  # Add brew to PATH for the remainder of this shell.
  eval "$("$BREW_PREFIX/bin/brew" shellenv)"
else
  echo "brew: $(command -v brew)"
fi

################################################################################

# Docker engine selection. We default to Docker Desktop (the most common
# choice and the one Apple-Silicon developers tend to already have). The
# user can opt for OrbStack instead by setting SANDBOX_DOCKER_ENGINE=orbstack
# — OrbStack is faster and lighter but proprietary.
ENGINE="${SANDBOX_DOCKER_ENGINE:-docker-desktop}"

echo
echo "${GRN}-- Docker engine: $ENGINE --${RST}"
case "$ENGINE" in
  docker-desktop)
    if ! brew list --cask docker >/dev/null 2>&1; then
      echo "Installing Docker Desktop (cask)..."
      brew install --cask docker
    else
      echo "Docker Desktop already installed via Homebrew cask."
    fi
    echo "${YEL}Action required: launch Docker Desktop once from /Applications/Docker.app${RST}"
    echo "${YEL}so it can complete its first-run permissions setup. Subsequent launches${RST}"
    echo "${YEL}of run_claude_docker.sh will rely on the engine already being running.${RST}"
    ;;
  orbstack)
    if ! brew list --cask orbstack >/dev/null 2>&1; then
      echo "Installing OrbStack (cask)..."
      brew install --cask orbstack
    else
      echo "OrbStack already installed via Homebrew cask."
    fi
    echo "${YEL}Action required: launch OrbStack once from /Applications/OrbStack.app${RST}"
    echo "${YEL}so it can register the docker CLI socket on PATH.${RST}"
    ;;
  *)
    echo "${RED}Unknown SANDBOX_DOCKER_ENGINE='$ENGINE'. Use 'docker-desktop' or 'orbstack'.${RST}" >&2
    exit 1
    ;;
esac

################################################################################

echo
echo "${GRN}-- Supporting CLI tooling --${RST}"
# coreutils gives us `greadlink -f` and other GNU-equivalents for any
# script that hasn't yet been ported to the portable resolver pattern.
# python3 + venv covers host_fiss_mcp/install.sh. fzf powers the
# start_sandbox.sh interactive picker. jq is used by start_script.sh
# inside the container, but the host operator may want it too.
for pkg in coreutils python@3.12 fzf jq curl git; do
  if brew list "$pkg" >/dev/null 2>&1; then
    echo "$pkg: already installed"
  else
    echo "Installing $pkg..."
    brew install "$pkg"
  fi
done

################################################################################

echo
echo "${GRN}-- Host-side fiss-mcp --${RST}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -x "${REPO_ROOT}/host_fiss_mcp/install.sh" ]]; then
  bash "${REPO_ROOT}/host_fiss_mcp/install.sh"
else
  echo "${YEL}skipping fiss-mcp install — ${REPO_ROOT}/host_fiss_mcp/install.sh not found.${RST}"
fi

################################################################################

echo
echo "${GRN}-- gcloud check (only required for Vertex mode) --${RST}"
if command -v gcloud >/dev/null 2>&1; then
  echo "gcloud: $(command -v gcloud)"
else
  echo "${YEL}gcloud not on PATH. Install via:${RST}"
  echo "${YEL}    brew install --cask google-cloud-sdk${RST}"
  echo "${YEL}then run:${RST}"
  echo "${YEL}    gcloud auth login${RST}"
  echo "${YEL}    gcloud auth application-default login${RST}"
  echo "${YEL}Anthropic-API (default) mode does not need gcloud and is unaffected.${RST}"
fi

################################################################################

echo
echo "${GRN}-- Mail notifications (manual setup) --${RST}"
cat <<EOF
The sandbox's notify-if-long.sh hook emits SMTP via curl to the host on
port 25. On Linux the launcher's setup_host_linux.sh configures the host
postfix to relay; macOS does not have a stock outbound-MTA path.

If you want email notifications on a macOS host, configure an SMTP relay
under /etc/postfix/main.cf with SMTP-AUTH credentials for Gmail / SES /
SendGrid / similar, then \`sudo postfix start\` and \`sudo launchctl
enable system/com.apple.postfix.master\` so it survives reboot.

Skip this whole step if you don't need email notifications.
EOF

################################################################################

echo
echo "${GRN}== macOS host bootstrap complete ==${RST}"
echo
echo "Next steps:"
echo "  1. Make sure Docker Desktop / OrbStack is running."
echo "  2. cd docker && make             # build the sandbox image"
echo "  3. source env.example.sh"
echo "  4. ./run_claude_docker.sh        # /login prompts inside the container"
echo
