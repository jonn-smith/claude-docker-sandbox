#!/usr/bin/env bash
# journal-nudge.sh — keep the append-only research journal (per CLAUDE.md)
# from being forgotten. The journal directive is passive prose, so it drifts;
# this hook re-injects a terse reminder as context on SessionStart and each
# UserPromptSubmit (the same mechanism that keeps caveman/ponytail active).
#
# It does NOT write journal entries itself — a shell hook only knows the
# timestamp and the raw prompt, not the decision / why / evidence / outcome
# the journal wants, and per-prompt auto-append would violate the journal's
# own "meaningful steps only, quality over quantity" rule. The agent writes
# the entries; this only raises salience.
#
# OPTIONAL raw audit trail: set CLAUDE_JOURNAL_AUDIT=1 (e.g. in your
# envs/env.<INSTANCE>.sh) to also append a guaranteed timestamp+prompt line
# per turn to a plain log — distinct from the curated JOURNAL.md. Path
# overridable via CLAUDE_JOURNAL_AUDIT_FILE (default /workspace/.journal-audit.log).
#
# Wired on both SessionStart and UserPromptSubmit in settings.json.

payload="$(cat 2>/dev/null)"

event=""
prompt=""
if command -v jq >/dev/null 2>&1; then
  event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
  prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)"
fi

# --- optional raw audit trail (opt-in) -------------------------------------
if [[ "${CLAUDE_JOURNAL_AUDIT:-0}" == "1" && "$event" == "UserPromptSubmit" ]]; then
  audit="${CLAUDE_JOURNAL_AUDIT_FILE:-/workspace/.journal-audit.log}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"
  line="$(printf '%s' "$prompt" | tr '\n\t' '  ' | cut -c1-500)"
  printf '%s\t%s\n' "$ts" "$line" >> "$audit" 2>/dev/null || true
fi

# --- reminder (injected as context) ----------------------------------------
# SessionStart: fuller, once per session. UserPromptSubmit: one terse line.
if [[ "$event" == "SessionStart" ]]; then
  cat <<'MSG'
JOURNAL REMINDER (per CLAUDE.md): maintain the append-only research journal at
/workspace/JOURNAL.md (or /workspace/JOURNAL/YYYY-MM-DD.md if that dir exists).
Append a UTC-timestamped entry for each MEANINGFUL step — a decision, a
hypothesis, an action with non-obvious effect, an observation that changed the
plan, or a dead end. Skip routine single-file edits. Never overwrite; always
append. Add a "Session summary" entry before you finish.
MSG
else
  echo "Journal reminder: append meaningful steps (decisions, non-obvious effects, dead ends) to /workspace/JOURNAL.md as you go — skip routine edits; never overwrite."
fi
exit 0
