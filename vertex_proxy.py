#!/usr/bin/env python3
"""Host-side Vertex AI proxy for claude-code.

Why host-side: the sandbox container has NO gcloud / gsutil / google-cloud-*
libs and NO ~/.config/gcloud mount. The only path to Vertex AI from inside
the sandbox is this proxy.

Architecture (Option B — chained):
  claude-code (Anthropic mode) → headroom (in container, optional) → vertex_proxy (host) → Vertex AI

claude-code runs in standard Anthropic mode (NOT CLAUDE_CODE_USE_VERTEX). The
launcher forwards ANTHROPIC_TARGET_API_URL into the container pointing at
this proxy. If HEADROOM=1, headroom compresses Anthropic-shape POST bodies
then forwards to this proxy. If HEADROOM=0, claude hits this proxy directly
via ANTHROPIC_BASE_URL. Either way, we strip any incoming Authorization
header, mint a fresh GCP access token, rebuild the Vertex URL from env +
request-body "model", and forward.

Config (all via env, matching the variables exported by SET_VERTEX_MODE.sh
so the same shell that launches claude-code configures the proxy):
  ANTHROPIC_VERTEX_PROJECT_ID  GCP project id (required)
  CLOUD_ML_REGION              Vertex region, e.g. us-east5 or global (required)
  VERTEX_PROXY_HOST            Bind address (default 127.0.0.1)
  VERTEX_PROXY_PORT            Bind port    (default 4000)
  ANTHROPIC_MODEL              Default model to fall through if request omits

The proxy ignores the incoming URL path entirely: clients send Anthropic
shapes like /v1/messages, but we rebuild the Vertex URL from env + the
request body's "model" field anyway. Vertex's :rawPredict endpoint accepts
the Anthropic Messages body format unchanged, so no body translation is
needed.
"""
import http.server
import itertools
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

PROJECT_ID = os.environ.get("ANTHROPIC_VERTEX_PROJECT_ID") or os.environ.get("VERTEX_PROJECT_ID")
REGION = os.environ.get("CLOUD_ML_REGION") or os.environ.get("VERTEX_REGION")
HOST = os.environ.get("VERTEX_PROXY_HOST", "127.0.0.1")
PORT = int(os.environ.get("VERTEX_PROXY_PORT", "4000"))
DEFAULT_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-opus-4-7")

_PLACEHOLDERS = {"", "your-gcp-project-id", "YOUR_PROJECT_ID"}
if not PROJECT_ID or PROJECT_ID in _PLACEHOLDERS:
    print(
        "vertex_proxy: ANTHROPIC_VERTEX_PROJECT_ID is unset or a placeholder.\n"
        "              Source SET_VERTEX_MODE.sh (with your real project id)\n"
        "              before starting the proxy.",
        file=sys.stderr,
    )
    sys.exit(1)
if not REGION:
    print("vertex_proxy: CLOUD_ML_REGION is unset.", file=sys.stderr)
    sys.exit(1)


def get_gcp_token():
    """Fetch a fresh OAuth token from the local gcloud CLI."""
    try:
        result = subprocess.run(
            ["gcloud", "auth", "print-access-token"],
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except FileNotFoundError:
        print("vertex_proxy: gcloud not on PATH — cannot mint access tokens.", file=sys.stderr)
        return None
    except subprocess.CalledProcessError as e:
        print(f"vertex_proxy: gcloud auth print-access-token failed: {e.stderr}", file=sys.stderr)
        return None


# Anthropic Messages fields that Vertex's :rawPredict schema accepts.
# Vertex rejects any unknown body field with HTTP 400 "Extra inputs are
# not permitted", so we whitelist rather than denylist — anything claude-code
# or headroom adds outside this set (e.g. context_management, mcp_servers,
# betas, container, model) gets dropped before forwarding. Note: "model"
# is intentionally excluded — Vertex requires model in the URL path only
# and rejects it in the body.
VERTEX_ALLOWED_FIELDS = frozenset({
    "anthropic_version", "max_tokens", "messages", "system",
    "stop_sequences", "stream", "temperature", "top_k", "top_p",
    "metadata", "tools", "tool_choice", "thinking",
})


def sanitize_for_vertex(payload: dict) -> dict:
    """Strip unsupported fields and force the Vertex anthropic_version."""
    clean = {k: v for k, v in payload.items() if k in VERTEX_ALLOWED_FIELDS}
    clean["anthropic_version"] = "vertex-2023-10-16"
    return clean


def vertex_host(region: str) -> str:
    # Regional endpoints follow {LOCATION}-aiplatform.googleapis.com, EXCEPT
    # global which uses the bare aiplatform.googleapis.com host (location=global
    # still appears in the URL path). The 'global-aiplatform.googleapis.com'
    # host returns Google's generic 404 page — not a Vertex error — which
    # claude-code surfaces as "model not available".
    if region == "global":
        return "aiplatform.googleapis.com"
    return f"{region}-aiplatform.googleapis.com"


_req_counter = itertools.count(1)
_log_lock = threading.Lock()


def log(req_id: int, msg: str) -> None:
    """Single-line log entry, thread-safe, with timestamp + request id."""
    ts = time.strftime("%H:%M:%S")
    with _log_lock:
        sys.stderr.write(f"[{ts}] vertex_proxy[#{req_id}] {msg}\n")
        sys.stderr.flush()


def summarize_messages(messages):
    """Return (count, last_user_snippet) for request logging."""
    if not isinstance(messages, list):
        return 0, ""
    last_user = ""
    for m in messages:
        if isinstance(m, dict) and m.get("role") == "user":
            content = m.get("content")
            if isinstance(content, str):
                last_user = content
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        last_user = part.get("text", "")
            # don't break — want the LAST user message
    snippet = last_user.strip().replace("\n", " ")
    if len(snippet) > 120:
        snippet = snippet[:117] + "..."
    return len(messages), snippet


# Pull message id + usage out of streamed SSE events. Vertex sends standard
# Anthropic SSE: event:message_start carries the message envelope (with id
# and input_tokens); event:message_delta carries the final usage. We match on
# the JSON payload rather than the SSE event lines so partial framing doesn't
# trip us up.
_SSE_MSG_START_ID = re.compile(rb'"type"\s*:\s*"message_start"[^}]*?"id"\s*:\s*"([^"]+)"', re.DOTALL)
_SSE_MSG_START_ID_ALT = re.compile(rb'"id"\s*:\s*"(msg_[^"]+)"')
_SSE_OUTPUT_TOKENS = re.compile(rb'"output_tokens"\s*:\s*(\d+)')
_SSE_INPUT_TOKENS = re.compile(rb'"input_tokens"\s*:\s*(\d+)')


def scan_sse_buffer(buf: bytes):
    """Best-effort: extract (msg_id, input_tokens, output_tokens) from SSE bytes."""
    msg_id = None
    m = _SSE_MSG_START_ID.search(buf) or _SSE_MSG_START_ID_ALT.search(buf)
    if m:
        msg_id = m.group(1).decode("utf-8", errors="replace")
    in_tok = None
    out_tok = None
    m = _SSE_INPUT_TOKENS.search(buf)
    if m:
        in_tok = int(m.group(1))
    # output_tokens appears multiple times; the LAST occurrence is the final tally
    out_matches = list(_SSE_OUTPUT_TOKENS.finditer(buf))
    if out_matches:
        out_tok = int(out_matches[-1].group(1))
    return msg_id, in_tok, out_tok


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Cut down on default access-log noise; errors still print via send_error.
        sys.stderr.write("vertex_proxy: " + (fmt % args) + "\n")

    def do_POST(self):
        req_id = next(_req_counter)
        t0 = time.monotonic()

        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length)

        try:
            payload = json.loads(post_data)
        except json.JSONDecodeError:
            log(req_id, f"ERR invalid JSON body ({content_length}B) from {self.client_address[0]}")
            self.send_error(400, "Invalid JSON payload")
            return

        is_stream = bool(payload.get("stream", False))
        requested_model = payload.get("model", "") or ""
        # Per Anthropic's Vertex docs, current models (Opus 4.6+, Sonnet 4.6+)
        # use bare names on Vertex; only older models carry an @YYYYMMDD suffix.
        # Pass the requested model through verbatim; fall back to DEFAULT_MODEL
        # only when the request omits a model entirely.
        model = requested_model or DEFAULT_MODEL

        clean_payload = sanitize_for_vertex(payload)
        forward_body = json.dumps(clean_payload).encode("utf-8")

        msg_count, last_snippet = summarize_messages(payload.get("messages"))
        tool_count = len(payload.get("tools") or [])
        max_tok = payload.get("max_tokens")
        log(
            req_id,
            f"REQ  path={self.path} model={model} stream={is_stream} "
            f"msgs={msg_count} tools={tool_count} max_tokens={max_tok} "
            f"body={len(forward_body)}B "
            f'last_user="{last_snippet}"'
        )

        token = get_gcp_token()
        if not token:
            log(req_id, "ERR no GCP token (gcloud auth print-access-token failed)")
            self.send_error(500, "Failed to retrieve GCP credentials")
            return

        endpoint = "streamRawPredict" if is_stream else "rawPredict"
        vertex_url = (
            f"https://{vertex_host(REGION)}/v1/projects/{PROJECT_ID}"
            f"/locations/{REGION}/publishers/anthropic/models/{model}:{endpoint}"
        )

        req = urllib.request.Request(vertex_url, data=forward_body, method="POST")
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("Content-Type", "application/json")

        try:
            with urllib.request.urlopen(req) as response:
                self.send_response(response.status)
                upstream_req_id = None
                for k, v in response.headers.items():
                    if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                        self.send_header(k, v)
                    # Vertex echoes a request id in either of these headers —
                    # captures it for logging even when we can't parse a body id.
                    if k.lower() in ("request-id", "x-request-id"):
                        upstream_req_id = v
                self.end_headers()

                buf = bytearray()
                BUF_CAP = 64 * 1024  # cap buffer; only need start_event + tail usage
                total = 0
                while True:
                    chunk = response.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    total += len(chunk)
                    if len(buf) < BUF_CAP:
                        buf.extend(chunk[: BUF_CAP - len(buf)])
                    # For stream responses, also keep grabbing the tail so the
                    # final message_delta with output_tokens lands in buf.
                    if is_stream and len(chunk) < 4096:
                        # likely near end; refresh tail window
                        tail_keep = min(len(buf), 16 * 1024)
                        buf = bytearray(bytes(buf)[-tail_keep:]) + bytearray(chunk)

                elapsed_ms = int((time.monotonic() - t0) * 1000)
                msg_id, in_tok, out_tok = (None, None, None)
                if is_stream:
                    msg_id, in_tok, out_tok = scan_sse_buffer(bytes(buf))
                else:
                    try:
                        body_json = json.loads(bytes(buf))
                        msg_id = body_json.get("id")
                        usage = body_json.get("usage") or {}
                        in_tok = usage.get("input_tokens")
                        out_tok = usage.get("output_tokens")
                    except (json.JSONDecodeError, ValueError):
                        pass

                vertex_proof = "YES" if (msg_id or "").startswith(("msg_vrtx_", "req_vrtx_")) else "?"
                log(
                    req_id,
                    f"RESP {response.status} {elapsed_ms}ms "
                    f"id={msg_id} vertex={vertex_proof} "
                    f"in_tok={in_tok} out_tok={out_tok} "
                    f"upstream_req_id={upstream_req_id} bytes={total}"
                )
        except urllib.error.HTTPError as e:
            err_body = e.read()
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            preview = forward_body[:800].decode("utf-8", errors="replace")
            log(req_id, f"ERR upstream HTTP {e.code} in {elapsed_ms}ms from {vertex_url}")
            log(req_id, f"     request body (truncated): {preview}")
            log(req_id, f"     response body: {err_body.decode('utf-8', errors='replace')}")
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(err_body)
        except Exception as e:
            elapsed_ms = int((time.monotonic() - t0) * 1000)
            log(req_id, f"ERR forwarding exception in {elapsed_ms}ms: {e!r}")
            self.send_error(500, f"Proxy forwarding error: {e}")


if __name__ == "__main__":
    httpd = http.server.ThreadingHTTPServer((HOST, PORT), ProxyHandler)
    print(f"vertex_proxy: listening on {HOST}:{PORT}")
    print(f"vertex_proxy: project={PROJECT_ID} region={REGION} default_model={DEFAULT_MODEL}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nvertex_proxy: shutting down.")
