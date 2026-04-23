# Claude Code Sandbox

A Docker-based sandbox for running the [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) CLI with local filesystem isolation. The container sees only a designated workspace directory and its own persistent state — the host's home directory, `/etc`, and everything else on the host remain invisible to the agent.

The image is a batteries-included dev environment, so `pip install`, `cargo install`, and `sudo apt install` work without network delay on launch.

## What's in the image

Base: `node:22-slim`.

- **Claude Code CLI** — `claude`, installed globally via npm.
- **Python 3** — venv at `/opt/claude-venv` (on `PATH`, writable by the sandbox user), preloaded with: `numpy`, `pandas`, `matplotlib`, `scipy`, `scikit-learn`, `seaborn`, `ipython`, `jupyter`, `requests`.
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

## Mounts

| Host path | Container path | Purpose |
|---|---|---|
| `$PROJECTS_DIR` | `/workspace` | Read/write workspace. CWD on launch. |
| `$SANDBOX_HOME/.claude/` | `/home/claude/.claude` | Settings, memory, sessions, plugins. |
| `$SANDBOX_HOME/.claude.json` | `/home/claude/.claude.json` | Onboarding state, project history, theme, cached OAuth account info. |
| `~/.claude/.credentials.json` | `/home/claude/.claude/.credentials.json` | OAuth token. Writable so refreshes land on the host; host and sandbox share one auth lifecycle. |

`$PROJECTS_DIR` and `$SANDBOX_HOME` are defined at the top of `run_claude_docker.sh`. `$SANDBOX_HOME` can also be overridden via the `CLAUDE_SANDBOX_HOME` environment variable.

Nothing else on the host is visible to the container.

## Persistence

- **Preserved across runs** (in `$SANDBOX_HOME`): Claude Code settings, memory, session history, installed plugins, onboarding state, project-specific config.
- **Shared with the host**: OAuth credentials (single token refreshed by whichever process needs it first).
- **Ephemeral** (gone on `--rm` container exit): anything written outside the mounts — `pip install`, `cargo install`, `sudo apt install`, files in `/tmp`, etc. If you want these to persist, either rebuild the image with them baked in, or add the relevant directories (e.g. `/opt/claude-venv`, `/usr/local/cargo`) to `$SANDBOX_HOME` as additional mounts.

## Customization

- **Add Python packages**: extend the `pip install` line in the `Dockerfile` and rebuild. Pin versions there if you want reproducibility (`numpy==1.26.4`, etc.).
- **Add system packages**: extend the `apt-get install` line.
- **Switch Java versions**: change the `FROM eclipse-temurin:17-jdk AS temurin` line to e.g. `21-jdk`.
- **Rust channels**: change `--default-toolchain stable` to `nightly` or a specific version.

## Isolation scope

This sandbox restricts **filesystem access only**. Network access from inside the container is unrestricted — the agent can reach the Claude API, npm, PyPI, crates.io, and the open internet. This is intentional: the goal is to keep the agent out of the host's home directory and system files, not to firewall its tool use. If you need network restrictions too, combine this with `--network none`, a custom Docker network, or the official Claude Code devcontainer's firewall (which is a separate, more restrictive setup).

## Adapting paths for your machine

The launcher script hardcodes `PROJECTS_DIR` and `PERSISTENT_STATE_DIR` to the author's layout. If you're reusing this outside that setup, edit those two lines at the top of `run_claude_docker.sh` — everything else is path-independent.
