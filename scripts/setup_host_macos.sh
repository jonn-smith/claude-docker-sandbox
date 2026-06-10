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

# Docker engine selection.
#
# Detect any existing working Docker engine first — many operators
# already have Docker Desktop installed via the official .dmg from
# docker.com (NOT through Homebrew). `brew list --cask docker` doesn't
# see that install, so blindly running `brew install --cask docker`
# would fail with "It seems there is already an App at '/Applications/
# Docker.app'". Skip the brew install when a working docker is already
# present and just remind the operator to make sure it's running.
#
# Preference order:
#   1. Working docker (any installer) → leave it alone, print version.
#   2. SANDBOX_DOCKER_ENGINE=orbstack → install OrbStack via brew cask.
#   3. Default → install Docker Desktop via brew cask.
ENGINE="${SANDBOX_DOCKER_ENGINE:-docker-desktop}"

echo
echo "${GRN}-- Docker engine --${RST}"

if command -v docker >/dev/null 2>&1; then
  echo "docker: found at $(command -v docker)"
  echo "version:"
  docker --version 2>&1 | sed 's/^/  /'
  if docker info >/dev/null 2>&1; then
    echo "daemon: reachable (existing install will be used; skipping brew step)"
  else
    echo "${YEL}daemon: not reachable. docker CLI is on PATH but the engine isn't running.${RST}"
    echo "${YEL}        Start Docker Desktop / OrbStack / whatever provided your${RST}"
    echo "${YEL}        docker binary, then re-run ./setup_host.sh (or skip straight${RST}"
    echo "${YEL}        to \`cd docker && make\` once the daemon responds).${RST}"
  fi
else
  echo "docker: not on PATH. Will install via Homebrew (SANDBOX_DOCKER_ENGINE=$ENGINE)."
  case "$ENGINE" in
    docker-desktop)
      if [[ -d /Applications/Docker.app ]]; then
        echo "${YEL}WARNING: /Applications/Docker.app exists but the docker CLI is not on${RST}"
        echo "${YEL}         PATH. Likely a partial install. Either launch the existing${RST}"
        echo "${YEL}         /Applications/Docker.app to finish its setup, or remove it${RST}"
        echo "${YEL}         (\`rm -rf /Applications/Docker.app\`) and re-run this script${RST}"
        echo "${YEL}         to do a clean brew install.${RST}"
        exit 1
      fi
      echo "Installing Docker Desktop (cask)..."
      brew install --cask docker
      echo "${YEL}Action required: launch Docker Desktop once from /Applications/Docker.app${RST}"
      echo "${YEL}so it can complete its first-run permissions setup.${RST}"
      ;;
    orbstack)
      if [[ -d /Applications/OrbStack.app ]]; then
        echo "${YEL}WARNING: /Applications/OrbStack.app exists but the docker CLI is not on${RST}"
        echo "${YEL}         PATH. Launch the existing app or remove it before re-running.${RST}"
        exit 1
      fi
      echo "Installing OrbStack (cask)..."
      brew install --cask orbstack
      echo "${YEL}Action required: launch OrbStack once from /Applications/OrbStack.app${RST}"
      echo "${YEL}so it can register the docker CLI socket on PATH.${RST}"
      ;;
    *)
      echo "${RED}Unknown SANDBOX_DOCKER_ENGINE='$ENGINE'. Use 'docker-desktop' or 'orbstack'.${RST}" >&2
      exit 1
      ;;
  esac
fi

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
