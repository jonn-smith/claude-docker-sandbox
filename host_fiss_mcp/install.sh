#!/usr/bin/env bash
# Idempotent installer for the host-side fiss-mcp server.
#
# Why host-side: keeping fiss-mcp out of the container removes gcloud, gsutil,
# google-cloud-* libs, and ~/.config/gcloud from the agent's reach. The only
# path to Terra/GCP from inside the sandbox is the MCP tools exposed by this
# server, which is read-only by default.
#
# Installs into $XDG_DATA_HOME/claude-sandbox-fiss-mcp (default
# ~/.local/share/claude-sandbox-fiss-mcp). Re-run any time; skips work that is
# already done.
set -euo pipefail

INSTALL_ROOT="${XDG_DATA_HOME:-$HOME/.local/share}/claude-sandbox-fiss-mcp"
SRC_DIR="${INSTALL_ROOT}/fiss-mcp"
VENV_DIR="${INSTALL_ROOT}/venv"
RUN_WRAPPER_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-server.py"
RUN_WRAPPER_DST="${INSTALL_ROOT}/run-server.py"
REPO_URL="https://github.com/broadinstitute/fiss-mcp.git"

mkdir -p "${INSTALL_ROOT}"

# Python 3.10+ check (fiss-mcp requires >=3.10).
PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "host_fiss_mcp/install.sh: python3 not found on PATH" >&2
  exit 1
fi
PY_VER=$("$PY" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJ=${PY_VER%%.*}; PY_MIN=${PY_VER##*.}
if [[ "$PY_MAJ" -lt 3 ]] || { [[ "$PY_MAJ" -eq 3 ]] && [[ "$PY_MIN" -lt 10 ]]; }; then
  echo "host_fiss_mcp/install.sh: python ${PY_VER} too old; fiss-mcp needs >=3.10" >&2
  exit 1
fi

if [[ ! -d "${SRC_DIR}/.git" ]]; then
  echo "host_fiss_mcp: cloning fiss-mcp into ${SRC_DIR}"
  git clone --depth=1 "${REPO_URL}" "${SRC_DIR}"
fi

if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  echo "host_fiss_mcp: creating venv at ${VENV_DIR}"
  "$PY" -m venv "${VENV_DIR}"
fi

# Marker file lets us skip the heavy pip step on repeat runs. Bump the marker
# string when bumping pinned deps to force a reinstall.
MARKER="${VENV_DIR}/.installed.marker"
EXPECTED_MARKER="fiss-mcp@$(git -C "${SRC_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ ! -f "${MARKER}" ]] || ! grep -q -x -F "${EXPECTED_MARKER}" "${MARKER}"; then
  echo "host_fiss_mcp: installing fiss-mcp + fastmcp into venv"
  "${VENV_DIR}/bin/pip" install --quiet --upgrade pip "setuptools<80"
  "${VENV_DIR}/bin/pip" install --quiet --no-build-isolation -e "${SRC_DIR}"
  echo "${EXPECTED_MARKER}" > "${MARKER}"
fi

install -m 0755 "${RUN_WRAPPER_SRC}" "${RUN_WRAPPER_DST}"

echo "host_fiss_mcp: ready at ${INSTALL_ROOT}"
