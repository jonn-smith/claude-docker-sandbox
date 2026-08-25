# persistent-states/

Per-instance persistent sandbox state, one subdirectory per workspace:
`persistent-states/<INSTANCE>/`. Each maps 1:1 to an env script
(`envs/env.<INSTANCE>.sh`, whose `CLAUDE_SANDBOX_INSTANCE=<INSTANCE>`).

A subdir holds that instance's `.claude/` (cache, file-history, backups,
shell-snapshots, session-env, projects/, history.jsonl) and its
`.claude.json`. It is created and seeded automatically by
`run_claude_docker.sh` on first launch — you never make one by hand.

Everything under here is runtime state and is gitignored (only this
README is tracked). Wiping a subdir resets that instance to a clean
login on next launch. Session transcripts can be snapshotted first with
`SESSION_ARCHIVE/archive_sessions.sh`.
