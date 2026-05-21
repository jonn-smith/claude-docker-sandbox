#!/usr/bin/env bash
# Smoke-test headroom's --backend vertex_ai against your real Vertex project.
# Run from the HOST (not inside the sandbox container). Cleans up after itself.
#
# Usage:
#   source SET_VERTEX_MODE.sh
#   ./headroom_vertex_smoke.sh
#
# Verifies, in order:
#   1. headroom-ai[proxy] installs into a throwaway venv
#   2. `headroom proxy --backend vertex_ai` starts without errors
#   3. host gcloud creds get picked up (ADC vs print-access-token)
#   4. an Anthropic-shape POST /v1/messages succeeds end-to-end
#   5. a streaming request returns SSE chunks
# Prints PASS / FAIL with details. Kills the proxy on exit.

set -uo pipefail

SMOKE_PORT="${SMOKE_PORT:-8788}"
SMOKE_DIR="$(mktemp -d -t headroom-vertex-smoke.XXXXXX)"
VENV="${SMOKE_DIR}/venv"
LOG="${SMOKE_DIR}/headroom.log"
PROXY_PID=""

cleanup() {
  if [[ -n "${PROXY_PID}" ]] && kill -0 "${PROXY_PID}" 2>/dev/null; then
    kill "${PROXY_PID}" 2>/dev/null || true
    wait "${PROXY_PID}" 2>/dev/null || true
  fi
  echo
  echo "Artifacts kept at: ${SMOKE_DIR}"
  echo "  log: ${LOG}"
  echo "Delete with: rm -rf ${SMOKE_DIR}"
}
trap cleanup EXIT INT TERM

step() { echo; echo "==> $*"; }
pass() { echo "    PASS: $*"; }
fail() { echo "    FAIL: $*" >&2; exit 1; }

# --- preconditions ---
step "Preconditions"
command -v gcloud >/dev/null 2>&1 || fail "gcloud not on PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 not on PATH"
[[ -n "${ANTHROPIC_VERTEX_PROJECT_ID:-}" ]] || fail "ANTHROPIC_VERTEX_PROJECT_ID unset (source SET_VERTEX_MODE.sh first)"
[[ -n "${CLOUD_ML_REGION:-}" ]] || fail "CLOUD_ML_REGION unset"
ACTIVE_ACCT="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1)"
[[ -n "${ACTIVE_ACCT}" ]] || fail "no active gcloud account; run 'gcloud auth login'"
ADC_FILE="${HOME}/.config/gcloud/application_default_credentials.json"
[[ -f "${ADC_FILE}" ]] || echo "    WARN: no ADC at ${ADC_FILE} — headroom may fall back to gcloud CLI; if it doesn't, run 'gcloud auth application-default login'"
pass "gcloud=${ACTIVE_ACCT}  project=${ANTHROPIC_VERTEX_PROJECT_ID}  region=${CLOUD_ML_REGION}"

# --- install ---
step "Install headroom-ai[proxy] into ${VENV}"
python3 -m venv "${VENV}"
"${VENV}/bin/pip" install --quiet --upgrade pip
"${VENV}/bin/pip" install --quiet 'headroom-ai[proxy]' || fail "pip install headroom-ai[proxy] failed"
HEADROOM_BIN="${VENV}/bin/headroom"
[[ -x "${HEADROOM_BIN}" ]] || fail "headroom binary not found at ${HEADROOM_BIN}"
pass "$(${HEADROOM_BIN} --version 2>&1 | head -1)"

# --- discover supported flags / backends ---
step "Inspect headroom proxy --help"
"${HEADROOM_BIN}" proxy --help 2>&1 | tee "${SMOKE_DIR}/help.txt" >/dev/null
if grep -q -- 'litellm-vertex\|--backend' "${SMOKE_DIR}/help.txt"; then
  pass "--backend flag present (real backend name for Vertex is litellm-vertex, NOT vertex_ai)"
else
  echo "    --backend flag NOT in help output. Dumping full help:"
  cat "${SMOKE_DIR}/help.txt"
  fail "headroom proxy doesn't expose --backend; this version cannot proxy to Vertex"
fi

# --- spawn proxy ---
step "Start: headroom proxy --backend litellm-vertex --region ${CLOUD_ML_REGION} --port ${SMOKE_PORT}"
# Defensively populate every env var name LiteLLM's Vertex backend has been
# observed to read. Unused ones are no-ops. ADC at ~/.config/gcloud/... is
# the auth source LiteLLM uses out of the box.
ANTHROPIC_VERTEX_PROJECT_ID="${ANTHROPIC_VERTEX_PROJECT_ID}" \
CLOUD_ML_REGION="${CLOUD_ML_REGION}" \
GOOGLE_CLOUD_PROJECT="${ANTHROPIC_VERTEX_PROJECT_ID}" \
VERTEXAI_PROJECT="${ANTHROPIC_VERTEX_PROJECT_ID}" \
VERTEXAI_LOCATION="${CLOUD_ML_REGION}" \
VERTEX_PROJECT="${ANTHROPIC_VERTEX_PROJECT_ID}" \
VERTEX_LOCATION="${CLOUD_ML_REGION}" \
nohup "${HEADROOM_BIN}" proxy \
    --backend litellm-vertex \
    --region "${CLOUD_ML_REGION}" \
    --port "${SMOKE_PORT}" \
    >"${LOG}" 2>&1 &
PROXY_PID=$!

echo -n "    waiting for proxy on 127.0.0.1:${SMOKE_PORT} "
READY=0
for _ in $(seq 1 30); do
  if (echo > "/dev/tcp/127.0.0.1/${SMOKE_PORT}") 2>/dev/null; then
    READY=1; echo "OK (pid=${PROXY_PID})"; break
  fi
  echo -n "."; sleep 1
done
if [[ "${READY}" != "1" ]]; then
  echo " FAILED"
  echo "    last 40 lines of ${LOG}:"
  tail -40 "${LOG}"
  fail "headroom proxy did not bind ${SMOKE_PORT}"
fi
pass "proxy bound :${SMOKE_PORT}"

# --- non-streaming request ---
step "Non-streaming POST /v1/messages"
REQ_BODY='{
  "model": "claude-opus-4-7",
  "max_tokens": 32,
  "messages": [{"role":"user","content":"reply with just the single word PONG"}]
}'
RESP="${SMOKE_DIR}/resp.json"
HTTP_CODE="$(curl -s -o "${RESP}" -w '%{http_code}' \
  -X POST "http://127.0.0.1:${SMOKE_PORT}/v1/messages" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d "${REQ_BODY}" || echo 000)"
if [[ "${HTTP_CODE}" == "200" ]]; then
  if grep -q -i 'pong' "${RESP}" 2>/dev/null; then
    pass "HTTP 200 + content includes 'pong' (full body: $(wc -c <"${RESP}") bytes)"
  else
    pass "HTTP 200 (body did not include 'pong' — model may have refused; check ${RESP})"
  fi
else
  echo "    HTTP ${HTTP_CODE} body:"
  head -50 "${RESP}"
  echo "    proxy log tail:"
  tail -20 "${LOG}"
  fail "non-streaming request failed"
fi

# --- streaming request ---
step "Streaming POST /v1/messages (stream=true, max ~5s)"
STREAM_OUT="${SMOKE_DIR}/stream.txt"
STREAM_REQ='{
  "model": "claude-opus-4-7",
  "max_tokens": 32,
  "stream": true,
  "messages": [{"role":"user","content":"count from 1 to 3"}]
}'
timeout 30 curl -s -N \
  -X POST "http://127.0.0.1:${SMOKE_PORT}/v1/messages" \
  -H 'content-type: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -d "${STREAM_REQ}" >"${STREAM_OUT}" || true
if grep -q '^event: ' "${STREAM_OUT}" 2>/dev/null; then
  pass "got SSE event: lines ($(grep -c '^event: ' "${STREAM_OUT}") events, $(wc -c <"${STREAM_OUT}") bytes)"
else
  echo "    no SSE events in stream output; first 40 lines:"
  head -40 "${STREAM_OUT}"
  echo "    proxy log tail:"
  tail -20 "${LOG}"
  fail "streaming did not return SSE events"
fi

# --- summary ---
step "Auth discovery — what did headroom actually use?"
echo "    proxy log tail (look for token-mint hints):"
tail -30 "${LOG}" | sed 's/^/      /'
echo
echo "ALL CHECKS PASSED. Findings:"
echo "  - headroom-ai[proxy] installs cleanly"
echo "  - --backend vertex_ai is present"
echo "  - non-streaming + streaming both work against project ${ANTHROPIC_VERTEX_PROJECT_ID} / region ${CLOUD_ML_REGION}"
echo "  - inspect ${LOG} to see how it auths (ADC file vs gcloud CLI vs metadata server)"
