# SESSION_ARCHIVE

Point-in-time copies of Claude Code **session history** — the full
transcript of every sandbox session that has run, plus each instance's
command-history log — and tooling to attribute those sessions to
projects and sort them into `by-project/`.

## Layout

```
SESSION_ARCHIVE/
  <source>/projects/       archived transcripts, grouped by source (below)
  <source>/history.jsonl   that instance's command-history log
  by-project/<label>/      sessions sorted by project (derived; gitignored)
  INDEX.md                 per-session index for eyeballing (gitignored)
  CLASSIFIED.md            hand-attribution: session -> project (gitignored)
  archive_sessions.sh      pull history out of the live state dirs
  index_sessions.sh        build INDEX.md
  classify_sessions.py     keyword auto-classifier (best-effort)
  bucket_sessions.py       sort into by-project/, prune sidecars
  view_session.sh          render one transcript as readable text
  README.md
```

`<source>` is an instance name (`B`, `GATK`, `WHB`, `main`, …) from a
per-instance state dir `claude-sandbox-persistent-state-<INSTANCE>`, or
`shared` from `claude-sandbox-shared` — the one state dir all
`CLAUDE_SANDBOX_USE_SHARED=1` instances write into. Shared-mode
transcripts can't be attributed back to a single instance: every shared
instance writes to one `projects/` directory.

Only the scripts + this README are tracked in git. The transcripts,
`by-project/`, `INDEX.md`, and `CLASSIFIED.md` are gitignored — hundreds
of MB of session content (full command + output history across every
project), regenerable from the live state dirs, and not something to
push to a remote.

## The workflow

Five steps. Only the first is required; the rest are for teasing a flat
pile of sessions apart into projects.

### 1. Archive — `archive_sessions.sh`

```bash
bash SESSION_ARCHIVE/archive_sessions.sh
```

Auto-discovers every `claude-sandbox-persistent-state-*` dir plus
`claude-sandbox-shared`, copies each source's `projects/` transcripts and
`history.jsonl` into `SESSION_ARCHIVE/<source>/`, prints a per-source
count.

On-demand only — nothing archives automatically. The live state dirs
already persist history across restarts; this is a manual snapshot for
before you wipe a state dir, before a refactor, or for long-term keeping.

Idempotent: re-running overwrites with the current live copy. Transcripts
are frozen once a session ends, so overwriting never loses data; new
sessions get added. It never **deletes** from the archive — a transcript
stays even after its source state dir is wiped (except when you `--prune`
in step 4).

### 2. Index — `index_sessions.sh`

```bash
bash SESSION_ARCHIVE/index_sessions.sh
```

Builds `INDEX.md`: one row per archived session — **date**, **title**
(Claude Code's auto session title), **first prompt** (the opening ask),
**hints** (git remotes + distinctive `/workspace/<sub>` paths). Grouped
by source, sorted by date. Read it to recognize your own work.

Why needed: in shared mode all sessions share one flat `projects/` dir,
and the in-container cwd is always `/workspace` regardless of which host
project was mounted — so a transcript has no clean "which project" field.
The index surfaces the signals that *do* survive.

### 3. (optional) Auto-classify — `classify_sessions.py`

```bash
python3 SESSION_ARCHIVE/classify_sessions.py    # writes CLASSIFIED.md
```

Best-effort keyword classifier against a fixed project list. Useful as a
first pass, but keyword matching alone mis-buckets — sandbox-infra tokens
(`ponytail`, `caveman`, `CLAUDE_SANDBOX_`, statusline) are injected into
every transcript by hooks, so they identify the sandbox, not the project.
Treat its output as a draft to hand-correct, not ground truth.

### 4. Hand-attribute — `CLASSIFIED.md`

The authoritative attribution. A table, one line per session (or per
same-project group), with a `project` column you edit by hand. Vocabulary:

- a **project name** — real work.
- **`sidecar`** — title-gen, notification-summary, empty shard, or test
  ping. No project substance. (See below.)

Use `view_session.sh` to open any session whose attribution isn't obvious
from the index.

### 5. Bucket — `bucket_sessions.py`

```bash
python3 SESSION_ARCHIVE/bucket_sessions.py              # dry-run: manifest + counts
python3 SESSION_ARCHIVE/bucket_sessions.py --go         # copy real sessions -> by-project/
python3 SESSION_ARCHIVE/bucket_sessions.py --go --prune # also delete sidecars from the archive
```

Copies each real session into `by-project/<label>/`, filenames prefixed
`<source>__<id>.jsonl` so the same session archived from two state dirs
(e.g. `a0575475` in both `main` and `shared`) doesn't collide. Dry-run by
default — prints the file→bucket manifest and touches nothing.

Flags:
- `--go` — perform the copy into `by-project/`.
- `--prune` — delete `_sidecar` transcripts from the archive copies.
- `--keep-sidecars` — with `--go`, copy sidecars into `by-project/_sidecar/`
  instead of skipping them.

The attribution rules live in the script (`DATE_DEFAULT` + `ID_OVERRIDE`
+ a couple of content disambiguations), transcribed from `CLASSIFIED.md`.
When you re-attribute a new archive run, update those rules to match your
edited `CLASSIFIED.md`.

Pruning deletes only from the archive copies (layer 2). The originals in
the live state dirs are never touched, and `archive_sessions.sh`
regenerates a pruned transcript if you ever want it back.

## Viewing a transcript — `view_session.sh`

```bash
./SESSION_ARCHIVE/view_session.sh <session-id>        # 8-char prefix ok
./SESSION_ARCHIVE/view_session.sh path/to/file.jsonl
./SESSION_ARCHIVE/view_session.sh <id> | less -R      # long ones
```

Renders user + assistant text turns, skipping tool spam. For replaying a
real session interactively instead, use `claude --resume <session-id>`
against the live state dir.

## What a "sidecar" is

A sidecar is a throwaway session Claude Code spawns for itself, not work
you did:

- **title-gen** — `"Summarize this task in 5 words or fewer…"` (naming a
  session).
- **notification-summary** — `"You are summarizing a completed Claude
  Code task for an email…"` (the notify hook).
- **empty shards** and **test pings** (`/model`, "reply with ok").

Sidecars carry no attribution signal — cwd is always `/workspace`,
gitBranch always `main`, no embedded parent text, and `parentUuid` links
turns *within* the file, not to the real session that spawned it. They
can't be tied to any project, so they're pruned rather than bucketed.
