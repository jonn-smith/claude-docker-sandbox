# Claude Code Sandbox

A Docker-based sandbox for running the [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) CLI with local filesystem isolation. The container sees only a designated workspace directory and its own persistent state — the host's home directory, `/etc`, and everything else on the host remain invisible to the agent.

The image is a batteries-included dev environment, so `pip install`, `cargo install`, and `sudo apt install` work without network delay on launch.

## What's in the image

Base: `node:22-slim`.

- **Claude Code CLI** — `claude`, installed globally via npm.
- **Python 3** — venv at `/opt/claude-venv` (on `PATH`, writable by the sandbox user), preloaded with: `numpy`, `pandas`, `matplotlib`, `scipy`, `scikit-learn`, `seaborn`, `ipython`, `jupyter`, `requests`, `headroom-ai[proxy]`.
- **Rust** — stable toolchain (`rustc`, `cargo`, `rustup`) at `/usr/local/{cargo,rustup}`.
- **Java 17** — Eclipse Temurin JDK at `/opt/java/openjdk`, `JAVA_HOME` exported.
- **Dev tooling** — `git`, `curl`, `ripgrep`, `vim`, `build-essential`.
- **Passwordless `sudo`** for the container's `claude` user (UID 1015, GID 1016 — matches the host owner so files written to the mount are owned correctly on the host).

Approximate image size: ~3 GB.

## Prerequisites

- Docker (tested on Docker 29.x).
- A working Claude Code install on the host with OAuth credentials at `~/.claude/.credentials.json`. Obtain by running `claude` on the host once and completing `/login`.

## Build

```bash
cd claude-sandbox_docker
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

## Mounts

State is split between a **shared** dir (one copy across all instances) and a **per-instance** dir (write-hot state only). Shared mount lands first; per-instance subdirs are then bind-mounted on top to override the write-hot paths.

| Host path | Container path | Purpose | Scope |
|---|---|---|---|
| `$PROJECTS_DIR` | `/workspace` | Read/write workspace. CWD on launch. | per-instance (caller-supplied) |
| `$SHARED_HOME/.claude/` | `/home/claude/.claude` | settings, skills, plugins, hooks, projects (memory), plans, tasks, sessions. | shared |
| `$SHARED_HOME/.claude.json` | `/home/claude/.claude.json` | Onboarding state, project history, theme, cached OAuth account info. | shared |
| `$SANDBOX_HOME/.claude/cache` | `/home/claude/.claude/cache` | Claude runtime cache. | per-instance |
| `$SANDBOX_HOME/.claude/file-history` | `/home/claude/.claude/file-history` | Per-edit snapshots. | per-instance |
| `$SANDBOX_HOME/.claude/backups` | `/home/claude/.claude/backups` | Auto-backups of edited files. | per-instance |
| `$SANDBOX_HOME/.claude/shell-snapshots` | `/home/claude/.claude/shell-snapshots` | Per-shell state. | per-instance |
| `$SANDBOX_HOME/.claude/session-env` | `/home/claude/.claude/session-env` | Per-shell env captures. | per-instance |
| `$SANDBOX_HOME/.claude/history.jsonl` | `/home/claude/.claude/history.jsonl` | Append-on-event log; would race if shared. | per-instance |
| `~/.claude/.credentials.json` | `/home/claude/.claude/.credentials.json` | OAuth token. Writable so refreshes land on the host. | host-shared |

`$SHARED_HOME` defaults to `claude-sandbox-shared/` next to `run_claude_docker.sh` (override: `CLAUDE_SANDBOX_SHARED`). `$SANDBOX_HOME` defaults to `claude-sandbox-persistent-state-${CLAUDE_SANDBOX_INSTANCE}/` (override: `CLAUDE_SANDBOX_HOME`). Both must be absolute paths.

Nothing else on the host is visible to the container.

### Migrating from a per-instance-only layout

If you already have populated `claude-sandbox-persistent-state-*` dirs from before this split, run once on the host:

```bash
./migrate_to_shared.sh --dry-run    # preview
./migrate_to_shared.sh              # do it
```

Union-merges `settings.json`, `skills/`, `plugins/`, `hooks/`, `plans/`, `tasks/`, `projects/`, `sessions/`, and `.claude.json` from every instance into `claude-sandbox-shared/` (main wins conflicts), then renames the per-instance copies to `*.preshared.bak` for rollback.

### Concurrency caveats

Hot dirs (cache, file-history, history.jsonl, etc.) are per-instance — no race. Shared items are write-rare in practice, but two instances writing the same shared file at the same time can interleave or last-write-wins:

- **Sessions**: each session is its own file (`sessions/<id>.json`). Two instances using the same session id concurrently would corrupt it. Sessions are uuid-named so practical overlap is near zero.
- **Plugin install/upgrade**: if you install a plugin in one instance while another reads `installed_plugins.json`, restart the second to pick it up cleanly.
- **Memory (`projects/`)**: per-file atomic writes; rare contention.

If concurrent overlap on a specific session ever matters, add a launch-time guard that scans `docker ps` for other claude containers using the same `--resume <id>` arg.

## Persistence

- **Shared across all instances** (in `$SHARED_HOME`): settings, skills, installed plugins, hooks, memory, sessions, plans, tasks, onboarding state.
- **Preserved per-instance** (in `$SANDBOX_HOME`): cache, file-history, backups, shell-snapshots, session-env, history.jsonl.
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

The launcher script hardcodes `PROJECTS_DIR` and `PERSISTENT_STATE_DIR` to the author's layout. If you're reusing this outside that setup, edit those two lines at the top of `run_claude_docker.sh` — everything else is path-independent.
