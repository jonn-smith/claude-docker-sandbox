# macOS testing checklist

Walk through this on a Mac (Apple Silicon or Intel, macOS 12+) to validate
the `feat/macos-support` branch end-to-end. Each section is a checkpoint
— stop, capture the output, and (if it differs from "expected") flag
which step broke. The Linux-side script logic is mechanical and verified
on a Linux build host; everything new is in the BSD-vs-GNU
coreutils paths, the Docker Desktop / OrbStack interfaces, and the
runtime-detection branches.

## 0. Prep

```bash
# Fresh clone, fresh state. No prior Docker images / settings.
git clone <repo-url> claude-docker-sandbox
cd claude-docker-sandbox
git checkout feat/macos-support
uname -srm    # capture: arch + kernel version
sw_vers       # capture: macOS version
```

## 1. setup_host.sh dispatch

```bash
./setup_host.sh
```

**Expected**: prints `setup_host.sh: dispatching to setup_host_macos.sh`,
then the macOS bootstrap walks through arch detection, Homebrew install
(if missing), Docker Desktop install, supporting CLI install, fiss-mcp
venv build, gcloud check, and the mail-relay note.

**Common breaks**:

- `bash: ./setup_host.sh: /usr/bin/env: bad interpreter` → file mode
  isn't `+x`. `chmod +x setup_host.sh`.
- Homebrew installer asks for sudo password → expected, that's the
  real Homebrew installer.
- `brew install --cask docker` fails with "Cask 'docker' is unavailable"
  → Homebrew taps not refreshed. `brew update && brew install --cask docker`.
- `brew install python@3.12` works but `python3` still points elsewhere
  → setup script doesn't rely on a specific `python3` location; the
  fiss-mcp install.sh resolves it from PATH. If `python3 --version` <
  3.10 in your shell, `brew link python@3.12 --force --overwrite`.

After this step, **launch Docker Desktop manually once** from /Applications
to complete its first-run privacy prompts. Then verify:

```bash
docker version    # expect: Client + Server reachable
docker run --rm hello-world
```

## 2. SCRIPT_DIR resolution

The portable `__resolve_dir` shim is exercised every time you invoke one
of the user-facing scripts. Quick test:

```bash
mkdir /tmp/symlink-test && cd /tmp/symlink-test
ln -s ~/claude-docker-sandbox/setup_host.sh ./setup_host.sh
SETUP_HOST_OS=macos bash -x ./setup_host.sh 2>&1 | head -20
```

**Expected**: `+ SCRIPT_DIR=/Users/<you>/claude-docker-sandbox`
(or wherever the real repo is — not `/tmp/symlink-test`).

If you see SCRIPT_DIR pointing at the symlink dir, `__resolve_dir` failed
to follow the symlink — likely a BSD `readlink` invocation difference.
Capture the line and report.

```bash
cd ~/claude-docker-sandbox    # back to real repo
rm -rf /tmp/symlink-test
```

## 3. Build the image

```bash
cd docker && make
cd ..
```

**Expected**: image build succeeds, tags `claude-sandbox:0.0.1` and
`claude-sandbox:latest`. Apple Silicon: builds native arm64 (image is
~3 GB; allow 20-40 min first time).

**Common breaks**:

- `arm64` vs `linux/amd64` confusion. Check `docker image inspect
  claude-sandbox:latest --format '{{.Architecture}}'`. Expect `arm64`
  on Apple Silicon. If you get `amd64` and slow image performance,
  Docker Desktop's Rosetta emulation is being used; under Docker
  Desktop > Settings > General, confirm "Use Rosetta for x86_64/amd64
  emulation on Apple Silicon" is OFF for native arm64 builds.
- `eclipse-temurin:17-jdk` base image pull stalls — usually a
  Docker Desktop network glitch; `docker system prune -a` and retry.

## 4. First-launch + login flow

```bash
source env.example.sh
./run_claude_docker.sh
```

**Expected boot output** (lines of interest):
- `layout: shared (SHARED_HOME=..., hot=...)`
- `fiss-mcp: host server pid=... url=http://host.docker.internal:.../mcp/`
- `macOS host: no sysbox-runc (using default runc), no GPU passthrough, no DinD.`
- `codegraph: ON v0.9.9`
- `pin-check (caveman): OK at 63a91eca...` *(after caveman plugin
  re-resolves on first launch — see step 6)*

Then the container drops into a `claude` prompt with `[CAVEMAN]` in the
statusline. First prompt:

```
/login
```

Expected: OAuth browser flow, then `Login successful`. Send another
prompt to confirm token persisted (NOT the bug seen on Linux earlier).

**Common breaks**:

- `fiss-mcp: server did not come up` → check that the host can bind to
  127.0.0.1 (it always can) and that `host_fiss_mcp/venv/bin/python`
  exists. Re-run setup if not.
- `LAUNCH ABORTED: directory where a file should be` → stale state from
  a prior failed launch. `rm -rf claude-sandbox-shared/.claude/.credentials.json`
  if it shows up as a directory (it shouldn't on a clean clone, but the
  guard is there for exactly this).
- `Not logged in` on second prompt → the credentials-write bug we hit
  on Linux. Should NOT happen here because the credentials file lives
  inside the shared `.claude/` directory bind mount (not a file mount);
  rename should work. If it doesn't, capture `ls -la
  claude-sandbox-shared/.claude/.credentials.json` after /login.

Exit the container (`/exit` or `Ctrl+D`). Verify creds persisted:

```bash
ls -la claude-sandbox-shared/.claude/.credentials.json
# expected: ~400-500 bytes, non-empty
```

## 5. Second launch — should not re-prompt

```bash
./run_claude_docker.sh
```

**Expected**: drops straight to a session, no /login prompt. If it
re-prompts, the credentials write didn't persist properly.

## 6. Caveman plugin auto-install + statusline

On the very first claude session, caveman's plugin needs to be installed
from its pinned ref. Watch boot output for:

- `pin-check (caveman): marketplace not yet installed — will resolve at pinned ref on first use.` *(first launch only)*
- After a few seconds in-session, `claude plugin list` should show
  `caveman@caveman (active)`.
- Statusline shows `[CAVEMAN]` (yellow chip near bottom).
- Subsequent launches: `pin-check (caveman): OK at 63a91eca...`

## 7. CodeGraph indexing

```bash
# Inside the container, after /login:
ls /workspace
# Workspace will be empty on first launch (env.example.sh defaults to
# workspace/ which is gitignored). Drop a small git repo in there:
cd /workspace
git clone https://github.com/colbymchenry/codegraph .    # or any repo
exit                                                     # leave claude
exit                                                     # leave container
```

Relaunch (`./run_claude_docker.sh`). Watch for:

```
codegraph: background indexing started (tail /workspace/.codegraph/init.log)
```

Then in-session, ask claude something like `find the function that
parses tree-sitter output`. Expected: it uses `mcp__codegraph__search`
or similar instead of grep + Read chains. The first few queries may
return partial results (indexing still running); subsequent queries hit
the full index.

**Common breaks**:

- `codegraph: command not found` → image build missed the install layer.
  `cd docker && make rebuild`.
- Indexing never finishes → tail `/workspace/.codegraph/init.log`.
  Permission errors usually mean Docker Desktop's virtio-fs path
  translation has UID issues. Check that the bind-mounted path owners
  match the container's `claude` user (UID inside is your host UID,
  remapped by uid-fixup-entrypoint).

## 8. RO mounts

```bash
echo "demo dataset" > /tmp/demo-ro-mount/dataset.txt 2>/dev/null || {
    mkdir /tmp/demo-ro-mount
    echo "demo dataset" > /tmp/demo-ro-mount/dataset.txt
}
echo 'export CLAUDE_SANDBOX_RO_MOUNTS="/tmp/demo-ro-mount"' >> env.example.sh
source env.example.sh
./run_claude_docker.sh
```

Expected: boot log includes `ro-mount: /tmp/demo-ro-mount ->
/read-only-reference/demo-ro-mount`. In-container:

```bash
cat /read-only-reference/demo-ro-mount/dataset.txt   # works
touch /read-only-reference/demo-ro-mount/new.txt     # EROFS
```

Clean up the env file after:

```bash
# Remove the line you added.
```

## 9. start_sandbox.sh interactive picker

```bash
./start_sandbox.sh
```

**Expected**: fzf area picker shows the `main` area. Preview pane shows
workdir + flags + RO mounts summary. Select `main`, then session
picker shows existing sessions + `▶ NEW SESSION`. Launch flow proceeds.

**Common breaks**:

- `fzf: command not found` → `brew install fzf`.
- Colors broken or escape sequences leak through → terminal doesn't
  support 256-color; not a sandbox bug. Test in iTerm2 or Terminal.app.

## 10. Vertex mode (optional)

If you use Vertex / GCP:

```bash
brew install --cask google-cloud-sdk
gcloud auth login
gcloud auth application-default login
cp SET_VERTEX_MODE.example.sh SET_VERTEX_MODE.sh
$EDITOR SET_VERTEX_MODE.sh    # set ANTHROPIC_VERTEX_PROJECT_ID + CLOUD_ML_REGION
source SET_VERTEX_MODE.sh
./run_claude_docker.sh
```

Expected: boot log includes `vertex_proxy: host server pid=... url=...`,
container traffic routes through the host proxy.

## What to report back

For each step:
- ✓ if it worked exactly as described, or
- ✗ + the exact output + step number if it broke.

Pay particular attention to:
- Whether `__resolve_dir` correctly handled any symlinked invocation
  (step 2).
- Whether `host.docker.internal:<port>` actually reaches the host
  127.0.0.1-bound fiss-mcp / vertex_proxy (steps 4 + 10).
- Whether `/login` persisted (steps 4-5).
- Caveman plugin actually installs on first launch from the pinned ref
  (step 6).
- Any other BSD-vs-GNU surface bugs that surface during normal use
  (`stat`, `sed -i`, `date`, etc.).

Capture the launcher output (`./run_claude_docker.sh 2>&1 | tee
~/sandbox-bootlog.txt`) for any failure; that's almost always enough
to localize the bug to a specific line.
