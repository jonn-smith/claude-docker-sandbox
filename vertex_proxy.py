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
import json
import os
import subprocess
import sys
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
# betas, container) gets dropped before forwarding. "model" is kept because
# Vertex tolerates (and ignores) it; the URL path is authoritative.
VERTEX_ALLOWED_FIELDS = frozenset({
    "anthropic_version", "max_tokens", "messages", "system",
    "stop_sequences", "stream", "temperature", "top_k", "top_p",
    "metadata", "tools", "tool_choice", "thinking", "model",
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


class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Cut down on default access-log noise; errors still print via send_error.
        sys.stderr.write("vertex_proxy: " + (fmt % args) + "\n")

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        post_data = self.rfile.read(content_length)

        try:
            payload = json.loads(post_data)
        except json.JSONDecodeError:
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

        token = get_gcp_token()
        if not token:
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
                for k, v in response.headers.items():
                    if k.lower() not in ("transfer-encoding", "content-length", "connection"):
                        self.send_header(k, v)
                self.end_headers()
                while True:
                    chunk = response.read(4096)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    self.wfile.flush()
        except urllib.error.HTTPError as e:
            self.send_response(e.code)
            self.end_headers()
            self.wfile.write(e.read())
        except Exception as e:
            self.send_error(500, f"Proxy forwarding error: {e}")


if __name__ == "__main__":
    httpd = http.server.ThreadingHTTPServer((HOST, PORT), ProxyHandler)
    print(f"vertex_proxy: listening on {HOST}:{PORT}")
    print(f"vertex_proxy: project={PROJECT_ID} region={REGION} default_model={DEFAULT_MODEL}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nvertex_proxy: shutting down.")
