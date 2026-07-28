# SESSION_ARCHIVE

Point-in-time copies of Claude Code **session history** — the full
transcript of every sandbox session that has run, plus each instance's
command-history log.

## What lands here

Running the archive script copies, for every sandbox instance that has
ever run:

- **`projects/`** — session transcripts (`<session-uuid>.jsonl`, one per
  session) and their sidecar directories (tool results, per-session
  memory).
- **`history.jsonl`** — the command-history log for that instance, when
  present.

Files are grouped by source:

```
SESSION_ARCHIVE/
  B/        projects/ + history.jsonl   from claude-sandbox-persistent-state-B
  GATK/     ...                          from claude-sandbox-persistent-state-GATK
  WHB/      ...                          from claude-sandbox-persistent-state-WHB
  main/     ...                          from claude-sandbox-persistent-state-main
  shared/   projects/                    from claude-sandbox-shared (USE_SHARED=1)
  archive_sessions.sh
  README.md
```

`<instance>/` folders come from per-instance state dirs
(`claude-sandbox-persistent-state-<INSTANCE>`). `shared/` comes from the
one state dir all `CLAUDE_SANDBOX_USE_SHARED=1` instances write into — its
transcripts can't be attributed back to a single instance, because in
shared mode every instance shares one `projects/` directory.

## On-demand only

Nothing archives automatically. The live state dirs already persist
session history across container restarts; this folder is a **manual,
explicit snapshot** you take when you want a copy that's independent of
the live dirs (before wiping a state dir, before a refactor, for
long-term keeping, etc.).

## How to run

From anywhere:

```bash
bash SESSION_ARCHIVE/archive_sessions.sh
```

or

```bash
./SESSION_ARCHIVE/archive_sessions.sh
```

The script auto-discovers every `claude-sandbox-persistent-state-*` dir
plus `claude-sandbox-shared`, and prints a per-source transcript count.

## Attributing sessions to projects — `index_sessions.sh`

In shared mode every instance dumps its sessions into one flat
`projects/` directory, and the in-container working dir is always
`/workspace` no matter which host project was mounted — so a transcript
carries no clean "which project was this" field. `index_sessions.sh`
builds `INDEX.md`, one row per archived session with the signals that
*do* survive, so you can attribute each session by eye:

```bash
bash SESSION_ARCHIVE/index_sessions.sh
```

Each row: **date** (first timestamp), **title** (Claude Code's
auto-generated session title), **first prompt** (the opening ask), and
**hints** (git remotes + distinctive `/workspace/<sub>` paths seen in the
transcript). Grouped by source, sorted by date.

It does **not** move or rename anything — attribution is a human read,
not an automatic classifier that could bucket a session into the wrong
project silently. Run the archive script first, then this.

`INDEX.md` is regenerated on demand and gitignored (it embeds prompt
snippets from every project).

## Re-running

Safe and idempotent. Re-running overwrites each destination with the
current live copy. Session transcripts are frozen once a session ends, so
overwriting never loses data; new sessions simply get added. The script
never **deletes** from the archive — a transcript stays here even after
its source state dir is wiped, which is the whole point.
