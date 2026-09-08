## 2026-06-04T17:40:00Z — integrate codegraph MCP into sandbox image

**Context.** Operator pointed at colbymchenry/codegraph (40k stars, MIT,
v0.9.9 latest) as a token-reduction tool: pre-built tree-sitter code graph
in SQLite, exposed as stdio MCP server with `codegraph_search` /
`codegraph_callers` / etc. so Claude queries the graph instead of grep+Read
chains. Goal: bake into shared sandbox image, register as default MCP,
auto-index every workdir so operator never has to run `codegraph init` by
hand.

**Decision / action.** Three-part integration:
1. `docker/Dockerfile` — install bundle from the official curl-piped
   installer into /opt/codegraph + /usr/local/bin/codegraph. Pinned via
   `ENV CODEGRAPH_VERSION=v0.9.9`. Bundle ships its own Node runtime so no
   npm/Node compile.
2. `docker/start_script.sh` — register `mcpServers.codegraph` in
   ~/.claude.json on every container boot via idempotent jq edit. Mirrors
   the fiss-mcp pattern at start_script.sh:73-117. CODEGRAPH=0 in env
   disables it.
3. `claude-sandbox-shared/.claude/hooks/codegraph-init.sh` — SessionStart
   hook that detached-spawns `codegraph init -i` when /workspace has a
   .git/ dir and .codegraph/codegraph.db is missing. Returns immediately;
   indexing runs in background.
Committed at b6ccb7b.

**Why.** Considered three placements for the MCP config:
- `claude-sandbox-shared/.claude/settings.json` mcpServers — REJECTED.
  Claude Code schema validation does not accept `mcpServers` as a
  settings.json field (verified empirically; schema error included full
  list of valid keys). Only valid placements: `~/.claude.json`,
  `.mcp.json`, or as a plugin.
- `.mcp.json` per workdir — REJECTED. Pollutes user repos with a sandbox
  artifact; requires .gitignore opt-in per repo.
- `~/.claude.json` at container boot via start_script.sh — ACCEPTED.
  Same pattern as fiss-mcp. ~/.claude.json is per-instance (overlay mount),
  so this needs to run on every boot; the jq write is idempotent.

For auto-indexing, considered:
- CLAUDE.md instruction telling Claude to run init — REJECTED. Wastes
  tokens, depends on Claude remembering, no guarantee.
- Synchronous run in start_script.sh — REJECTED. Multi-minute index would
  block container startup; bad UX.
- SessionStart hook with detached spawn — ACCEPTED. Fast hook return,
  background indexing, MCP queries return partial results during init
  which is fine.

Gated on `.git/` existing so non-code workdirs (data dirs, scratch dirs)
don't get indexed. Opt-out via `/workspace/.codegraph-disable` sentinel
file for repos where indexing isn't wanted.

Also added `settings.json` to .gitignore exception list. The shared
settings.json was previously untracked; without tracking it the new
SessionStart hook entry would not propagate to fresh clones. Inspected
file for secrets — only host-level prefs (effortLevel, theme, hook
references, enabled plugins). Safe to commit.

**Evidence.** Repo audit before integrating:
- 40714 stars, 2525 forks, MIT, created 2026-01-18, regularly tagged
  releases (15 total, v0.9.4→v0.9.9 in ~10 days).
- install.sh inspected (sha256 `50f5fdbb...`, 95 lines): clean, no sudo,
  no system writes, no telemetry endpoints. Only network = GitHub
  releases redirect + tarball download. No checksum verification of
  tarball, however — that's the residual trust assumption.
- Tarball is opaque pre-built bundle, not built from the visible TS
  source at build time. Source could in principle diverge from artifact;
  not audited bit-for-bit. Sandbox containment makes this acceptable.

Verified MCP wiring pattern by reading fiss-mcp lifecycle in
start_script.sh:73-117. Mirrored its jq mutation strategy (write to
.tmp then `cat > .json` to preserve the bind-mounted inode — rename(2)
would fail with EBUSY).

Schema validation forced the redesign mid-session: first attempt put
`mcpServers` directly in settings.json, got rejected. Switched to
start_script.sh registration without losing the goal.

**Outcome.** After next `make rebuild` of the docker image, every new
sandbox container will:
1. Have `codegraph` on PATH.
2. Register the MCP server at boot (printed `codegraph: ON v0.9.9`).
3. SessionStart hook kicks off first-time `codegraph init -i` in
   background on every git-tracked workdir.
4. Subsequent sessions in the same workdir re-use the existing SQLite
   index; watcher inside MCP server keeps it current.

Follow-ups:
- Operator needs to run `make rebuild` (forced rebuild, `--no-cache --pull`,
  added in commit b3d1795) to actually bake the codegraph install layer.
  Cache-friendly `make build` would not invalidate the apt/npm layers.
- Per-repo `.codegraph/` should be added to that repo's `.gitignore` —
  it's a per-workdir artifact, not source.
- Worth measuring actual token / tool-call savings on a real workload
  once a sandbox is rebuilt and codegraph-enabled. Maintainer's bench
  numbers (~16% cheaper, ~58% fewer calls) are directional; real-world
  delta depends on how much grep+Read dominates the operator's typical
  tasks.

## 2026-07-09T00:00:00Z  — RC bridge socket path fix, paused before rebuild

**Context.** Branch `feat/unix-socket-remote-control` (commit 4b6f464)
added ANTHROPIC_UNIX_SOCKET bridge to bypass Claude Code's client-side
Remote Control gate (which rejects any ANTHROPIC_BASE_URL host != 
api.anthropic.com when HEADROOM proxy is in use). Container failed to
start after that commit: socat could not bind at /run/anthropic-headroom.sock.

**Decision / action.** Moved socket path to /tmp/anthropic-headroom.sock
in `docker/start_script.sh:111` and `docs/REMOTE_CONTROL.md` (all
occurrences). Committed as 626c310. Left uncommitted `run_claude_docker.sh`
version pin (SANDBOX_DOCKER_VERSION=0.0.1, operator's temporary rollback
to a pre-bridge image so the sandbox stays runnable) and settings.json
effort tweak (xhigh→high) alone.

**Why.** `start_script.sh` runs as the unprivileged `claude` user —
`uid-fixup-entrypoint.sh` exec's `gosu claude` before dropping into the
script. `/run` is root-owned mode 0755, so both `rm -f "$RC_SOCK"` and
socat's UNIX-LISTEN bind failed with EACCES. `set -euo pipefail` at the
top of start_script.sh means either failure kills the process, the
container exits before the operator ever sees a prompt. /tmp is
world-writable; mode=0600 on the socket file keeps single-user access.

**Evidence.** Container failure reported by operator ("permissions
denied with socat"). Confirmed via reading uid-fixup-entrypoint.sh
(runs `exec gosu claude "${@:-${DEFAULT_CMD[@]}}"`) and Dockerfile:74
(claude user is UID 1015, no write perms on /run).

**Outcome.** Bridge should now bind cleanly. Still not tested end-to-end
— requires image rebuild at 0.0.2 (VERSION already bumped in Makefile
by operator, commit 0e1f422), realignment of SANDBOX_DOCKER_VERSION pin
in run_claude_docker.sh, and interactive Remote Control pairing on a
real device. Verification checklist in docs/REMOTE_CONTROL.md.

**Follow-ups (parked, operator returning later):**
1. Optional: apply dev-iteration speedup patches (bind-mount 
   start_script.sh into the container, BuildKit cache mounts on
   pip/apt/cargo, fold socat into main apt install layer).
2. Rebuild image at 0.0.2.
3. Realign run_claude_docker.sh version pin.
4. Walk 7-step verification checklist in docs/REMOTE_CONTROL.md.

**Sanity check on headroom during this session:** operator ran
`curl -sf http://127.0.0.1:8787/stats` — 30 api_requests, 26 compressed,
113k tokens saved this session, $0.57 in headroom compression savings +
$21.29 in Anthropic prompt-cache savings. Confirms headroom pipeline
end-to-end (Claude Code → socat → headroom → api.anthropic.com) during
the current sandbox session, so at least the bridge-plus-headroom path
was functional for interactive use, distinct from the Remote Control
gate acceptance which still needs its own test.

## 2026-08-25T19:45:00Z  — issue #12 fiss-mcp data bridge: validated end-to-end

**Context.** Branch fix/issue-12-fiss-data-bridge (06d1561). Needed a live
test of the fiss-mcp → shell data bridge before PR. Relaunched sandbox;
env showed FISS_DOWNLOADS_HOST=/juffowup2/claude_projects/fiss_downloads,
FISS_DOWNLOADS=/workspace/fiss_downloads, HOST_WORKSPACE_DIR set; dir existed.

**Action.** Used the failed Terra submission
a796e260-.../5e141e05-... (workspace jts_tmp_Malaria..._Gambia_Large_Joint_Calling)
as test material. Pulled files via download_gcs_file into the host bridge
path and verified they surfaced in the container shell.

**Evidence.**
- Small file: call-ImportGVCFsIntoGenomicsDB/shard-1/attempt-2/stderr
  (9095 B) — appeared at $FISS_DOWNLOADS, md5 vCn1OmaHx21jbyTchrEjzw==
  matched GCS.
- Large file: gs://broad-dsp-pf8-mirror/gvcf_reblocked/FP0010-CW.rb.g.vcf.gz
  (23,013,184 B) — the failure class from the issue (>10 MB killed
  read_gcs_object). Downloaded clean, md5 BG02RVLWMfUnj0CheCfEbw== matched,
  gzip -t OK, zcat streamed whole file: sample FP0010-CW, contig Pf3D7_01_v3,
  1,540,736 variant records counted. No session death.
- Ownership: files written by the host fiss-mcp process show as claude:claude
  in the container (HOST_UID alignment holds).

**Outcome.** Bridge works for both small and large (23 MB) transfers with
integrity intact and correct ownership — issue #12 bullets 1 & 2 resolved,
and bullet 3's common case (download then run local tools) confirmed via
zcat/gzip on the pulled GVCF. Fix is PR-ready pending `make build` for the
baked start_script.sh log line.

**Side finding.** The Terra run's real failure is not OOM but a duplicate
sample map entry: "Found two mappings for the same sample: PA0658-CW"
(same GVCF path listed twice) in GenomicsDBImport. Dedupe to fix.

## 2026-08-28T15:15:00Z  — Bumped ponytail, headroom, caveman (3 independent branches)

**Context.** Operator asked whether upstream developments in the pinned
caveman/ponytail/headroom warranted upgrades, and to branch + test each.

**Actions / findings.**
- ponytail v4.8.4 -> v4.9.0 (branch chore/bump-ponytail-4.9.0, 5f67388).
  Bug fixes hit our exact setup: stdin-crash guard in mode-tracker (#227),
  combined-statusline preservation (#374), CLAUDE_CONFIG_DIR nudge (#338).
  Re-vendored whole (no engine bloat). Tested badge + mode-tracker.
- headroom 0.24.0 -> 0.37.0 (branch chore/bump-headroom-0.37.0, 08f6772).
  Fixes the 1M-context cap we'd flagged (0.36 honors [1m]); Vertex SSRF
  patch; more compression. KEY: default model changed to kompress-v2-base
  at 0.25 — updated HEADROOM_MODEL_REPO + added allow_patterns to fetch
  only the int8 ONNX + tokenizer (~269MB vs the full 1.5GB repo). Verified
  empirically: installed 0.37 in a throwaway venv, confirmed it starts
  with our flags and pulls kompress-v2-base; confirmed the allow_patterns
  snapshot_download fetches the right 269MB file set.
- caveman v1.8.2 -> v2.3.1 (branch chore/bump-caveman-2.3.1, 6e7578d).
  Caveman v2 split: MIT skill (what we use) + BSL engine (we don't). Repo
  ballooned to 27MB. Vendored PRUNED (plugin-only subset, 1.2MB) after
  verifying hooks require only builtins + local files and nothing in
  src/skills references the pruned engine dirs. Tested activate + badge.

**Why pruned caveman.** Vendoring 27MB of unused BSL engine source is
wasteful; the plugin loader only needs .claude-plugin/src/skills/commands/
agents. Fallback (extraKnownMarketplaces) covers a wrong prune by cloning
upstream.

**Outcome.** Three independent branches, unpushed. headroom + caveman need
`make build` (baked pins). Full plugin-load / headroom-runtime are the
operator's final on-host checks.

## 2026-09-08T00:00:00Z  — GPU-loss watchdog hook

**Context.** GPU-enabled sandboxes occasionally lose GPU access mid-run
(user report). Goal: surface it automatically instead of discovering it via
a failed CUDA call.

**Decision / action.** Added `claude-sandbox-shared/.claude/hooks/gpu-watch.sh`,
wired on `UserPromptSubmit` in `settings.json`. Launcher now captures the GPU
count at launch (`run_claude_docker.sh:838`) and forwards
`CLAUDE_SANDBOX_GPU` + `CLAUDE_SANDBOX_GPU_COUNT` into the container
(`run_claude_docker.sh:992-993`). Hook no-ops unless `CLAUDE_SANDBOX_GPU=1`,
else runs `nvidia-smi` (timeout-bounded) and warns if it fails, if nvidia-smi
vanished, or if the visible GPU count dropped below launch.

**Why.** Root cause is the known nvidia-container-toolkit cgroup-drop bug
(NVML "Unknown Error" after a host `systemctl daemon-reload`), where
`/dev/nvidia*` may persist but CUDA is dead — so a device-node existence check
is insufficient; must actually query nvidia-smi. UserPromptSubmit chosen over
PreToolUse for cadence: one cheap check per turn, output injected as context so
the agent relays it. All work is host-side (launcher) + mounted shared hook —
no image rebuild, pull + relaunch suffices. Gated hard on the launch flag so
CPU/macOS sandboxes pay zero cost (matches the audit-hook no-op-when-off
precedent).

**Evidence.** `bash -n` clean on both files; settings.json validates.
Exercised both branches in-container (no GPU here): `CLAUDE_SANDBOX_GPU=0` →
silent exit 0; `CLAUDE_SANDBOX_GPU=1` → prints the "nvidia-smi not present"
warning, exit 0.

**Outcome.** GPU drop now surfaces at the next prompt in any GPU sandbox.
Recovery path documented in README GPU section. New env contract:
`CLAUDE_SANDBOX_GPU` / `CLAUDE_SANDBOX_GPU_COUNT` (launcher-set, not user config).

## 2026-09-08T00:30:00Z  — GPU watchdog: also fire on Stop, with dedup'd email

**Context.** User runs long prompts and wants GPU loss surfaced sooner — at
turn end, not only at their next prompt.

**Decision / action.** Wired `gpu-watch.sh` on `Stop` in addition to
`UserPromptSubmit`. Made the hook event-aware: same nvidia-smi health check,
but on `Stop` (where hook stdout is only visible in transcript mode) it also
sends an email via the same `curl smtp://<default-gw>:25` path as
`notify-if-long.sh`, gated on `CLAUDE_NOTIFY_EMAIL`. Deduped through a
per-instance state file `~/.claude/cache/.gpu-watch-last` so it emails once on
the healthy→lost transition, not every turn while the GPU stays down.

**Why.** Claude Code surfaces hook stdout differently per event: injected as
context on UserPromptSubmit, transcript-only on Stop. So a bare Stop echo would
be easy to miss — the repo's other Stop hooks already notify out-of-band via
email, so I reused that. State file lives in `~/.claude/cache` because that dir
is bind-mounted PER-INSTANCE even in shared mode (unlike the rest of the shared
`~/.claude`), so two GPU sandboxes don't clobber each other's last-known state.
Event parsed with a grep (not a python/jq fork) and only in the lost path, so
the healthy path stays one nvidia-smi call.

**Evidence.** `bash -n` clean; settings.json validates and shows gpu-watch on
both UserPromptSubmit and Stop. Exercised: off → silent; Stop + GPU-absent →
prints warning, writes state=lost; second Stop → stays lost (email would be
deduped).

**Outcome.** GPU drop now caught at whichever comes first — next prompt or
turn end — and emails you once when email is configured. Commit on branch
feat/gpu-watch-hook.
