# TODO

## Next: multi-agent orchestration bake-off

**Goal.** Pick a coordination layer for running many Claude Code agents, each
inside its own `claude-sandbox` container, with a board-style UX and automatic
task dispatch. Many frameworks claim to do this; evaluate them against one
rubric before building anything.

**Hard constraints** (from the sandbox model; see `README.md`):

- Agent process runs **inside** a sandbox container launched by
  `run_claude_docker.sh`, never as a bare host process. Isolation, headroom,
  host-side fiss-mcp, codegraph, plugin pins, per-instance state must survive.
- Auth reuses the sandbox's own `.credentials.json` mount. Host `~/.claude` is
  never mounted.
- Host is a headless GCP VM. Framework needs a server/remote mode, or its
  desktop client must drive agents on the VM over SSH.

**Rubric** (score each candidate; evidence goes in `JOURNAL.md`):

| # | Criterion | Why it matters |
|---|---|---|
| 1 | Where does the agent process run? Container-native, SSH-remote, or host-spawn only | Host-spawn = disqualified (multica) |
| 2 | Status/telemetry crosses the container boundary | Hooks that POST to host loopback are dead inside a container |
| 3 | Git/worktree model works with the `/workspace` bind mount and one container per agent | Host-absolute `gitdir:` paths break inside the container |
| 4 | Headless-host story | `orca serve` needs Electron libs + Xvfb; others differ |
| 5 | Board UX + auto-dispatch quality | The actual want |
| 6 | Integration effort: LOC, image rebuild, launcher refactor | Rebuild is ~36 min; launcher is 1000 lines |
| 7 | License, telemetry, maintenance velocity | |

**Candidates**

| Tool | Status | Notes |
|---|---|---|
| [stablyai/orca](https://github.com/stablyai/orca) | Evaluated 2026-09-18, **fits** | Use its `environmentRecipes` (per-workspace SSH environment). Plan below. MIT. |
| [multica-ai/multica](https://github.com/multica-ai/multica) | Evaluated 2026-09-02, **no fit as-is** | Daemon spawns agent CLI as bare host process. License NOASSERTION. |
| Claude Code Agent Teams (native) | Unscreened | Launcher already forwards `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`. Single-container, in-process teammates. No board. |
| Others | Unscreened | Add here as found. Screen against criterion 1 first; it kills most of them fast. |

**Method.** One journal entry per candidate with file:line evidence, same
structure as the orca entries (2026-09-18T17:55Z, 18:20Z). Fill the table.
Prototype only the top one or two.

### Orca integration plan (ready to build)

Orca's per-workspace environment recipe makes each sandbox container the
execution host for one workspace. Orca dials in over its SSH relay, deploys the
relay and its managed Claude hooks inside the container, creates the worktree
inside, spawns `claude` in a container PTY. Full status fidelity, no path
mismatch. References: `skill-guides/orca-per-workspace-env.md` and
`references/{docker-ssh,ssh-host,failure-modes}.md` in the orca repo.

Sandbox changes:

1. **Image:** add `openssh-server`. Entrypoint branch: `ssh-keygen -A`, write
   `ORCA_SSH_PUBLIC_KEY` to `authorized_keys`, key-only auth, `exec sshd -D`.
2. **Launcher daemon mode:** `docker run -d -p 127.0.0.1::22` instead of
   `--rm -it`. `start_script.sh` does its normal setup then execs sshd instead
   of `claude`. Persist exported env (headroom `ANTHROPIC_BASE_URL`, `FISS_*`,
   `PATH`) to a profile-sourced file so SSH login shells see it.
3. **Host helpers:** fiss-mcp and vertex proxy currently die with the
   launcher's EXIT trap. Daemon mode tracks them by per-instance pidfile;
   `destroy` kills them.
4. **Recipe scripts:** `scripts/orca-vm/create.sh` maps `ORCA_VM_INSTANCE_ID`
   to `CLAUDE_SANDBOX_INSTANCE`, launches daemon mode, reads the published
   port via `docker port`, reads the container host key via `docker exec` into
   `known_hosts`, prints
   `{schemaVersion:1, connection:{type:"ssh", projectRoot:"/workspace/<repo>", target:{label, host:"127.0.0.1", port, username:"claude", identityFile, identitiesOnly:true}}}`.
   `destroy.sh` reads `recipeResult.userData.resourceId`, runs `docker rm -f`,
   kills host helpers. Register both in `orca.yaml` under `environmentRecipes`.
5. **Validate:** `orca vm recipe doctor <id> --repo-path <repo> --json`, then
   `--provision` loop.

Placement: orca puts SSH-host worktrees in sibling dirs
(`<repo>/../<repo>-<name>`), so with `projectRoot=/workspace/<repo>` they land
on the bind mount and persist on the host after destroy. Alternative:
`checkoutMode: provisioned-root` (schema 2) for a fresh clone per container.

Open items: orca writes managed hooks into the container's
`~/.claude/settings.json`, which is the shared
`claude-sandbox-shared/.claude/settings.json`. Guarded no-ops elsewhere, but
consider a per-instance overlay in daemon mode. Relay deploy inside a sysbox
container is untested. Desktop-on-laptop needs `jumpHost` through the VM.

Estimate: Dockerfile + entrypoint ~30 lines, launcher daemon mode ~80,
start_script branch ~20, recipe scripts ~80, `orca.yaml`. Plus rebuild.
