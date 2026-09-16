# Restart notes — 2026-09-16

## Read this before rebuilding

**All four fixes are on branch `jts_fable_reasoning_extraction_fix`, not `main`.**
`docker/Makefile` builds from the working tree, so rebuild while that branch is
checked out — or merge it to main first. Rebuilding from `main` gets you none of
the image fixes.

```
be55208  fix(headroom): protect Bash tool results from lossy compression
4cd9d26  docs(claude-md): restore rationale wording in the journal directive
3bb1719  fix(docker): install iproute2 explicitly
727b9c7  fix(claude-md): drop CoT-extraction phrasing that blocks Fable 5.1
```

Nothing is pushed.

## What takes effect when

| fix | where it lives | needs |
|---|---|---|
| Fable refusal (CLAUDE.md wording) | `/workspace/CLAUDE.md`, `claude-sandbox-shared/.claude/CLAUDE.md` (bind mount, inode 29367256) | **already live** — survives restart on any image |
| `ip: command not found` in Stop hook | `docker/Dockerfile:14` (`iproute2`) | **image rebuild** |
| headroom corrupting Bash output | `docker/start_script.sh:42` (`--protect-tool-results Bash`), COPY'd at `Dockerfile:121` | **image rebuild** |

`make -C docker build` (or `rebuild` for --no-cache).

A plain container restart on the current image fixes Fable and nothing else.

## Post-restart checklist

1. `ip route` resolves — Stop hook stops erroring.
2. `pgrep -af "headroom proxy"` shows `--protect-tool-results Bash`.
3. Fable answers a prompt. `claude --model claude-fable-5-1 -p "what time is it?"`
4. Re-run the corruption probe: write 300 identical-form lines, `cat` them
   through Bash in a long session, confirm no `[N words compressed to M]` footer
   and no emptied lines. **This is the one thing still unverified** — see below.

## Open

- **headroom fix is unproven end to end.** The lossy path only ever reproduced
  in a real long-running session; a sub-agent and a synthetic `/v1/messages`
  replay both came back byte-exact. The flag is documented by headroom's own
  `config.py`, but "it fixes it" is inference, not measurement. Step 4 above is
  the actual test.
- **Plugin pins in `settings.json` are inert.** `plugins/cache/` is what loads:
  caveman is **v1.6.0** (April), not the pinned v2.3.1; ponytail is 4.8.4, not
  v4.9.0. Upstream is v2.7.0 / v4.10.0. Recommendation was: `claude plugin
  update caveman` + restart, skip ponytail (its 4 plugin-path commits are all
  other-host plumbing). Not done — needs the `runy.sh` A/B first.
- Untouched, low priority: `/workspace` at 84% full; `.codegraph/codegraph.db`
  last written Sep 3 (possibly stale); dead plugin `bin/` PATH entries.

## Reproduction harness

`$SCRATCH/fablebisect/` — `mkcfg.sh` (isolated CLAUDE_CONFIG_DIR clone),
`runy.sh <name> <project-md>` (full-stack A/B on one variable), plus `run.sh`
/ `run2.sh` / `run3.sh` / `runx.sh` for narrower bisects. Scratch is
session-scoped and will not survive the restart — copy it out if you want it.
