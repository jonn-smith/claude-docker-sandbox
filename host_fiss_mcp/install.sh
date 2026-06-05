#!/usr/bin/env bash
# Idempotent installer for the host-side fiss-mcp server.
#
# Why host-side: keeping fiss-mcp out of the container removes gcloud, gsutil,
# google-cloud-* libs, and ~/.config/gcloud from the agent's reach. The only
# path to Terra/GCP from inside the sandbox is the MCP tools exposed by this
# server, which is read-only by default.
#
# Installs alongside this script (the host_fiss_mcp/ directory in the repo
# checkout). Re-run any time; skips work that is already done.
set -euo pipefail

INSTALL_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC_DIR="${INSTALL_ROOT}/fiss-mcp"
VENV_DIR="${INSTALL_ROOT}/venv"
REPO_URL="https://github.com/broadinstitute/fiss-mcp.git"

# Pinned release. Bump together with anything that depends on new fiss-mcp
# features. The marker file below keys off this string, so any change here
# triggers a full reinstall on the next setup_host.sh run.
FISS_MCP_REF="1.0.4"
FISS_MCP_REF_COMMIT="453ac5245667d8450ef0c1b67a4dbf05725513b9"

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
  echo "host_fiss_mcp: cloning fiss-mcp into ${SRC_DIR} (ref=${FISS_MCP_REF})"
  git clone "${REPO_URL}" "${SRC_DIR}"
fi

# Pin to the expected release. Fetch the tag if missing (e.g. older clone),
# checkout, then verify the resolved commit matches the recorded SHA. Mismatch
# means the upstream tag was moved — abort rather than silently building a
# different version.
git -C "${SRC_DIR}" fetch --tags --quiet origin
git -C "${SRC_DIR}" checkout --quiet "${FISS_MCP_REF}"
RESOLVED="$(git -C "${SRC_DIR}" rev-parse HEAD)"
if [[ "${RESOLVED}" != "${FISS_MCP_REF_COMMIT}" ]]; then
  echo "host_fiss_mcp: tag ${FISS_MCP_REF} resolved to ${RESOLVED}," >&2
  echo "              expected ${FISS_MCP_REF_COMMIT}. Refusing to build a" >&2
  echo "              non-pinned revision. Re-confirm the upstream tag and" >&2
  echo "              update FISS_MCP_REF_COMMIT in this script." >&2
  exit 1
fi

# A venv is "good" only if both pyvenv.cfg AND bin/pip are present. An
# earlier `python3 -m venv` invocation on a host missing the python3-venv
# package writes pyvenv.cfg before bailing on ensurepip, leaving bin/pip
# absent — a guard that only checked pyvenv.cfg silently skipped recreation
# and the very next line (pip install) failed with "No such file or
# directory". Wipe any partial venv so the create step is forced.
if [[ ! -x "${VENV_DIR}/bin/pip" ]]; then
  if [[ -e "${VENV_DIR}" ]]; then
    echo "host_fiss_mcp: removing incomplete venv at ${VENV_DIR}"
    rm -rf "${VENV_DIR}"
  fi
  echo "host_fiss_mcp: creating venv at ${VENV_DIR}"
  "$PY" -m venv "${VENV_DIR}"
fi

# Marker file lets us skip the heavy pip step on repeat runs. The marker
# encodes the pinned ref + resolved commit, so any pin bump forces a
# reinstall on the next setup_host.sh run.
MARKER="${VENV_DIR}/.installed.marker"
EXPECTED_MARKER="fiss-mcp@${FISS_MCP_REF}+${FISS_MCP_REF_COMMIT}"
if [[ ! -f "${MARKER}" ]] || ! grep -q -x -F "${EXPECTED_MARKER}" "${MARKER}"; then
  echo "host_fiss_mcp: installing fiss-mcp + fastmcp into venv"
  "${VENV_DIR}/bin/pip" install --quiet --upgrade pip "setuptools<80"
  "${VENV_DIR}/bin/pip" install --quiet --no-build-isolation -e "${SRC_DIR}"
  echo "${EXPECTED_MARKER}" > "${MARKER}"
fi

echo "host_fiss_mcp: ready at ${INSTALL_ROOT}"
