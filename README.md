# Claude Code Sandbox _FOR LINUX_

A Docker-based sandbox for running the [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) CLI with local filesystem isolation. The container sees only a designated workspace directory and its own persistent state — the host's home directory, `/etc`, and everything else on the host remain invisible to the agent.

The image is a batteries-included dev environment, so `pip install`, `cargo install`, and `sudo apt install` work without network delay on launch.

# Features
Look, this uses a heavy docker image, and it's suited to my (Jonn's) needs.  Nevertheless you may find it useful.

Beyond the normal setup and build features, this sandbox has:
- Automated email notifications for prompts that take longer than <CONFIGURABLE> seconds to complete (default 120)
- A built-in, pre-configured [headroom](https://github.com/chopratejas/headroom) installation (runtime-disable-able)
- A built-in [fiss-mcp](https://github.com/broadinstitute/fiss-mcp) server for interacting with Terra. The server runs on the **host**, not inside the container, so the sandbox has no `gcloud` / `gsutil` / `google-cloud-*` libs and no `~/.config/gcloud` mount — the only path from inside the sandbox to Terra/GCP is the MCP tools the server exposes. Read-only by default; opt-in write mode via `FISS_MCP_ALLOW_WRITES=1`, which prints a loud red ASCII-art banner on the host **and** inside the container so it is impossible to miss (banner is pre-rendered, no `figlet` dependency).

I've tried to include everything I need for my typical work.

This is still Linux only.  Mac build might be coming soon.

## Quick start (fresh clone)

```bash
# 1. Install host prerequisites (sysbox runtime, postfix mynetworks)
./setup_host.sh

# 2. Authenticate Claude Code on the host once. Creates
#    ~/.claude/.credentials.json which the sandbox bind-mounts in.
claude   # then /login

# 3. Build the image
# NOTE: This step takes ~2200s or 36 minutes.
cd docker && make && cd ..

# 4. Launch the default "main" shared-mode instance.
#    env.example.sh defaults to in-repo workspace/ + context_reference/.
source env.example.sh
./run_claude_docker.sh
```

### At first run, after initial setup, make sure to:

1. Install the [caveman](https://github.com/JuliusBrussee/caveman) plugin:
```
claude plugin marketplace add JuliusBrussee/caveman && claude plugin install caveman@caveman
```

### Multi-instance mode

For a second concurrent instance, copy the template and change the instance name:

```bash
cp env.example.sh env.B.sh
$EDITOR env.B.sh   # set CLAUDE_SANDBOX_INSTANCE=B (and PROJECTS_DIR if different)
source env.B.sh && ./run_claude_docker.sh
```

`env.*.sh` (other than `env.example.sh`) is gitignored — your per-instance files won't accidentally land in commits.

For details on per-instance vs shared layouts and parallel launches, see [Mounts](#mounts).

## What's in the image

Base: `node:22-slim`.

- **Claude Code CLI** — `claude`, installed globally via npm.
- **Python 3** — venv at `/opt/claude-venv` (on `PATH`, writable by the sandbox user), preloaded with: `numpy`, `pandas`, `matplotlib`, `scipy`, `scikit-learn`, `seaborn`, `ipython`, `jupyter`, `requests`, `headroom-ai[proxy]`.
- **Rust** — stable toolchain (`rustc`, `cargo`, `rustup`) at `/usr/local/{cargo,rustup}`.
- **Java 17** — Eclipse Temurin JDK at `/opt/java/openjdk`, `JAVA_HOME` exported.
- **Dev tooling** — `git`, `curl`, `ripgrep`, `vim`, `build-essential`.
- **Passwordless `sudo`** for the container's `claude` user. UID/GID are remapped at container start to match the host invoker (`HOST_UID` / `HOST_GID` env vars supplied by `run_claude_docker.sh`), so a single image is shareable across hosts with different user IDs — no rebuild needed.

Approximate image size: ~3 GB.

## Prerequisites

- Docker (tested on Docker 29.x).
- A working Claude Code install on the host with OAuth credentials at `~/.claude/.credentials.json`. Obtain by running `claude` on the host once and completing `/login`.

## Build

```bash
cd docker
make
```

Tags the image as `claude-sandbox:0.0.1` and `claude-sandbox:latest`. First build pulls the Temurin JDK image, the Rust toolchain, and a few hundred MB of Python wheels — expect several minutes.

## Run

The launcher script (`run_claude_docker.sh`) forwards any arguments to `claude` inside the container:

```bash
./run_claude_docker.sh                                     # fresh session
./run_claude_docker.sh --continue                          # resume most recent
./run_claude_docker.sh --resume <session-id>               # resume specific
./run_claude_docker.sh --dangerously-skip-permissions      # no prompts
./run_claude_docker.sh --continue --dangerously-skip-permissions
```

To drop into a shell instead of `claude`, change the trailing `claude "$@"` in `run_claude_docker.sh` to `/bin/bash`.

## Headroom proxy (token compression)

The image bundles [Headroom](https://github.com/chopratejas/headroom), a local HTTP proxy that compresses prompts, tool outputs, and history before forwarding to the Claude API. Off by default. Toggle per launch:

```bash
HEADROOM=1 ./run_claude_docker.sh                  # on
./run_claude_docker.sh                             # off
HEADROOM=1 ./run_claude_docker.sh --continue       # on + resume
HEADROOM_PORT=9000 HEADROOM=1 ./run_claude_docker.sh   # custom port
```

How it works: when `HEADROOM=1`, `start_script.sh` launches `headroom proxy` on `127.0.0.1:$HEADROOM_PORT` (default 8787) and exports `ANTHROPIC_BASE_URL` so `claude` routes through it. The proxy applies AST-aware code compression, JSON-output stripping, prompt-cache prefix alignment, and recovery-on-demand for dropped messages, then forwards to `api.anthropic.com` using the existing OAuth token. Process dies with the container; nothing persists across runs. Stats: `curl http://127.0.0.1:8787/stats` from inside the container.

Trust model: the proxy reads every byte of every request — that's how compression works. It runs entirely inside the same container as `claude`, so it sees the same OAuth token Claude already has and no wider trust boundary is opened. Code is Apache-2.0; pin the version in `Dockerfile`. If you don't want a third-party dep in the request path, leave `HEADROOM` unset and traffic goes direct.

Per-instance default: add `export HEADROOM=1` to the matching `env.<INSTANCE>.sh` to make it sticky for that sandbox.

## fiss-mcp (Terra MCP server) — runs on the host

The launcher spawns [fiss-mcp](https://github.com/broadinstitute/fiss-mcp) as a host-side HTTP MCP server before starting the container, then advertises its URL to the container via `FISS_MCP_URL`. The in-container `start_script.sh` registers an HTTP MCP entry in `~/.claude.json` pointing at `http://host.docker.internal:<PORT>/mcp/`. When `run_claude_docker.sh` exits (or you ^C it), a bash `EXIT` trap kills the host process.

**Why host-side**: the container never sees `gcloud`, `gsutil`, `google-cloud-*` libs, `~/.config/gcloud`, or any service-account key file. The agent's only reachable path to Terra/GCP is the MCP tools the host server exposes — which are read-only by default. There is no shell-level bypass.

**Install**: `setup_host.sh` runs `host_fiss_mcp/install.sh` once. It clones fiss-mcp into `host_fiss_mcp/fiss-mcp/` (next to the script in this repo) and creates a venv at `host_fiss_mcp/venv/` — both gitignored — so everything is self-contained inside the checkout and isolated from any other Python install on the host. Requires Python 3.10+ on the host (apt-installed by `setup_host.sh` if missing). If you launch `run_claude_docker.sh` with `FISS_MCP=1` and the install dir is absent, the run script errors out and tells you to run `./setup_host.sh`.

The installer pins fiss-mcp to a specific release tag **and** verifies the resolved commit SHA against a recorded value. If the upstream tag has been moved, the install aborts rather than silently building a different version. A marker file in the venv encodes the pinned ref + SHA; a re-install runs automatically the next time you bump either constant in `host_fiss_mcp/install.sh`.

**Auth**: the host server inherits the host's gcloud credentials directly — no mount, no env var forwarding. Set up once on the host:

```bash
gcloud auth login                              # user creds (the Terra-registered identity)
gcloud auth application-default login          # ADC (FISS uses this)
```

On a GCE VM with a default service account, the metadata server is picked up automatically — but Terra is user-identity-based, so a workspace-registered Google account is generally required.

**Toggle and write-access:**

```bash
./run_claude_docker.sh                            # fiss-mcp on, read-only (default)
FISS_MCP=0 ./run_claude_docker.sh                 # off (no spawn, no registration)
FISS_MCP_ALLOW_WRITES=1 ./run_claude_docker.sh    # on, WRITE MODE (loud banner)
```

> **Warning**: `FISS_MCP_ALLOW_WRITES=1` lets the agent submit workflows, mutate workspace attributes, and spend money on your Terra/GCP account. Both `run_claude_docker.sh` and `start_script.sh` print a red ASCII-art banner (pre-rendered figlet output, no host or image dependency) when write mode is on, on the host and inside the container respectively, so the warning shows up no matter where you're reading the terminal.

**Ports**: each instance gets a deterministic port in `39000-39999` hashed from `CLAUDE_SANDBOX_INSTANCE`, so concurrent sandboxes don't collide. Override with `FISS_MCP_PORT=<port>` if the auto-pick clashes with something else on the host.

**Container connectivity**: `run_claude_docker.sh` adds `--add-host=host.docker.internal:host-gateway` so the container can reach the host on a stable name. Works with `sysbox-runc` because it's a Docker daemon flag, not a runtime concern.

**Bind address**: the host server binds **only** the docker bridge gateway IP (auto-detected via `docker network inspect bridge`), not `0.0.0.0` and not `127.0.0.1`. That's the same address the container reaches us at via `host.docker.internal`, so container ingress is unchanged — but the listener is not present on `eth0` / `wlan0` / any external interface, so no iptables fence is required to keep it off the host's outside-world network. If the bridge gateway can't be determined (broken docker setup), the launcher fails fast rather than silently widening the bind to `0.0.0.0`.

**Lifecycle**: trap on `EXIT INT TERM` kills the host fastmcp process. If the launcher is `kill -9`'d, the orphan can be reaped with `pkill -f run-server.py`. The MCP log lives at `${SANDBOX_HOME}/.claude/host_fiss_mcp.log`.

Per-instance default: set `FISS_MCP` / `FISS_MCP_ALLOW_WRITES` / `FISS_MCP_PORT` in `env.<INSTANCE>.sh`.

## Mounts

Two layout modes, picked per launch by `CLAUDE_SANDBOX_USE_SHARED`:

- **Per-instance (default, `=0` or unset)** — full Claude state lives in `$SANDBOX_HOME/.claude` for this one instance. Original behavior; instances are fully independent. No shared dir touched.
- **Shared (`=1`)** — settings/skills/plugins/hooks/projects/plans/tasks/sessions come from `$SHARED_HOME` (one copy across all shared-mode instances). `.claude.json` plus write-hot dirs (cache, file-history, backups, shell-snapshots, session-env, history.jsonl) stay in `$SANDBOX_HOME` and bind-mount on top of the shared `.claude`. `.claude.json` is per-instance because it's rewritten whole on every change and holds per-project allowedTools/mcpServers/history that would race if shared.

### Per-instance mode (default)

| Host path | Container path | Purpose |
|---|---|---|
| `$PROJECTS_DIR` | `/workspace` | Read/write workspace. CWD on launch. |
| `$SANDBOX_HOME/.claude/` | `/home/claude/.claude` | All Claude state (settings, memory, sessions, plugins, caches). |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | Onboarding state, project history. |
| `~/.claude/.credentials.json` | `/home/claude/.claude/.credentials.json` | OAuth token (RW; refreshes land on host). |

(fiss-mcp / Terra creds are **not** mounted — the MCP server runs on the host. See [fiss-mcp section](#fiss-mcp-terra-mcp-server--runs-on-the-host).)

### Shared mode (opt-in)

| Host path | Container path | Scope |
|---|---|---|
| `$PROJECTS_DIR` | `/workspace` | per-instance (caller-supplied) |
| `$SHARED_HOME/.claude/` | `/home/claude/.claude` | shared — settings, skills, plugins, hooks, projects, plans, tasks, sessions |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | per-instance — onboarding state, per-project allowedTools/mcpServers/history. Rewritten whole on every change, would race if shared. |
| `$SANDBOX_HOME/.claude/cache` | `/home/claude/.claude/cache` | per-instance |
| `$SANDBOX_HOME/.claude/file-history` | `/home/claude/.claude/file-history` | per-instance |
| `$SANDBOX_HOME/.claude/backups` | `/home/claude/.claude/backups` | per-instance |
| `$SANDBOX_HOME/.claude/shell-snapshots` | `/home/claude/.claude/shell-snapshots` | per-instance |
| `$SANDBOX_HOME/.claude/session-env` | `/home/claude/.claude/session-env` | per-instance |
| `$SANDBOX_HOME/.claude/history.jsonl` | `/home/claude/.claude/history.jsonl` | per-instance |
| `~/.claude/.credentials.json` | `/home/claude/.claude/.credentials.json` | host-shared |

`$SHARED_HOME` defaults to `claude-sandbox-shared/` next to `run_claude_docker.sh` (override: `CLAUDE_SANDBOX_SHARED`). `$SANDBOX_HOME` defaults to `claude-sandbox-persistent-state-${CLAUDE_SANDBOX_INSTANCE}/` (override: `CLAUDE_SANDBOX_HOME`). Both must be absolute paths.

Nothing else on the host is visible to the container.

### Adopting shared mode safely (no risk to existing instances)

Existing `main` / `B` / etc. keep working in per-instance mode untouched. Opt a sandbox into shared mode by adding `export CLAUDE_SANDBOX_USE_SHARED=1` to its `env.<INSTANCE>.sh`. First launch populates `claude-sandbox-shared/` from the seeded defaults; subsequent launches reuse it. Switch back any time by removing that line.

### Concurrency caveats (shared mode)

Hot dirs are per-instance — no race. Shared items are write-rare in practice, but two shared-mode instances writing the same file at the same time can interleave or last-write-wins:

- **Sessions**: each session is its own file (`sessions/<id>.json`). Two instances using the same session id concurrently would corrupt it. Sessions are uuid-named so practical overlap is near zero.
- **Plugin install/upgrade**: if you install a plugin in one instance while another reads `installed_plugins.json`, restart the second to pick it up cleanly.
- **Memory (`projects/`)**: per-file atomic writes; rare contention.

## Persistence

- **Per-instance mode** — everything in `$SANDBOX_HOME` (settings + state + sessions + caches), preserved across runs of that instance only.
- **Shared mode** — settings, skills, plugins, hooks, memory, sessions, plans, tasks, onboarding live in `$SHARED_HOME` (visible to all shared-mode instances). Cache, file-history, backups, shell-snapshots, session-env, history.jsonl stay per-instance.
- **Shared with the host**: OAuth credentials (single token refreshed by whichever process needs it first).
- **Ephemeral** (gone on `--rm` container exit): anything written outside the mounts — `pip install`, `cargo install`, `sudo apt install`, files in `/tmp`, etc. If you want these to persist, either rebuild the image with them baked in, or add the relevant directories (e.g. `/opt/claude-venv`, `/usr/local/cargo`) as additional mounts.

## Customization

- **Add Python packages**: extend the `pip install` line in the `Dockerfile` and rebuild. Pin versions there if you want reproducibility (`numpy==1.26.4`, etc.).
- **Add system packages**: extend the `apt-get install` line.
- **Switch Java versions**: change the `FROM eclipse-temurin:17-jdk AS temurin` line to e.g. `21-jdk`.
- **Rust channels**: change `--default-toolchain stable` to `nightly` or a specific version.

## Isolation scope

This sandbox restricts **filesystem access only**. Network access from inside the container is unrestricted — the agent can reach the Claude API, npm, PyPI, crates.io, and the open internet. This is intentional: the goal is to keep the agent out of the host's home directory and system files, not to firewall its tool use. If you need network restrictions too, combine this with `--network none`, a custom Docker network, or the official Claude Code devcontainer's firewall (which is a separate, more restrictive setup).

## Adapting paths for your machine

Paths are driven by environment variables — nothing is hardcoded in `run_claude_docker.sh`. Set these in your `env.<INSTANCE>.sh` (start from `env.example.sh`):

- `CLAUDE_SANDBOX_PROJECTS_DIR` — host dir mounted at `/workspace` (required).
- `CLAUDE_SANDBOX_CONTEXT_DIR` — host dir mounted at `/context` (required).
- `CLAUDE_SANDBOX_INSTANCE` — unique instance name (required; suffixes container, DinD volume, state dir).
- `CLAUDE_SANDBOX_HOME` — override the per-instance state dir (default: `claude-sandbox-persistent-state-<INSTANCE>/` alongside the launcher).
- `CLAUDE_SANDBOX_SHARED` — override the shared dir in shared mode (default: `claude-sandbox-shared/`).

Per-instance overrides also cover `HEADROOM`, `HEADROOM_PORT`, `FISS_MCP`, `FISS_MCP_ALLOW_WRITES`, `FISS_MCP_PORT`, and `CLAUDE_SANDBOX_USE_SHARED` — set whichever you want sticky for that sandbox.
