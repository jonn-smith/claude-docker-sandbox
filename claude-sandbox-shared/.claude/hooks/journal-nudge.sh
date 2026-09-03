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
# envs/env.<INSTANCE>.sh) to also append a guaranteed record of the
# conversation to a plain log — distinct from the curated JOURNAL.md.
# Format: one "UTC-timestamp <TAB> ROLE <TAB> text" line per turn, where
# ROLE is USER (the full prompt) or CLAUDE (the full response, gathered
# from the transcript on Stop). Text is untruncated; embedded newlines/tabs
# are flattened to spaces so each turn stays one grep-able line. Path
# overridable via CLAUDE_JOURNAL_AUDIT_FILE (default /workspace/.journal-audit.log).
#
# Wired on SessionStart, UserPromptSubmit, and Stop in settings.json.

payload="$(cat 2>/dev/null)"

# Only the event name is needed to decide what to do; prompt/transcript are
# extracted lazily below so the common no-op case (e.g. Stop with the audit
# trail off) costs a single jq fork, not several.
command -v jq >/dev/null 2>&1 || exit 0
event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"

# --- optional raw audit trail (opt-in) -------------------------------------
# One flattened line per turn. USER line on prompt submit; CLAUDE line on
# Stop (the response is only in the transcript by then, so read it back).
if [[ "${CLAUDE_JOURNAL_AUDIT:-0}" == "1" ]]; then
  audit="${CLAUDE_JOURNAL_AUDIT_FILE:-/workspace/.journal-audit.log}"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date)"

  if [[ "$event" == "UserPromptSubmit" ]]; then
    prompt="$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)"
    if [[ -n "$prompt" ]]; then
      line="$(printf '%s' "$prompt" | tr '\n\t' '  ')"
      printf '%s\tUSER\t%s\n' "$ts" "$line" >> "$audit" 2>/dev/null || true
    fi
  elif [[ "$event" == "Stop" ]]; then
    transcript="$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)"
    if [[ -f "$transcript" ]]; then
      # All assistant text since the last user message = this turn's response.
      # (assistant turns can span several records around tool calls.)
      resp="$(jq -rs '
        (map(.type) | rindex("user")) as $u
        | (if $u == null then . else .[($u+1):] end)
        | map(select(.type=="assistant")
              | (.message.content // [])
              | map(.text // empty) | join(""))
        | map(select(. != "")) | join("\n")
      ' "$transcript" 2>/dev/null | tr '\n\t' '  ')"
      [[ -n "$resp" ]] && printf '%s\tCLAUDE\t%s\n' "$ts" "$resp" >> "$audit" 2>/dev/null || true
    fi
  fi
fi

# --- reminder (injected as context) ----------------------------------------
# SessionStart: fuller, once per session. UserPromptSubmit: one terse line.
# Any other event (e.g. Stop, used only for the audit trail above) prints
# nothing — we don't want to inject a reminder there.
if [[ "$event" == "SessionStart" ]]; then
  cat <<'MSG'
JOURNAL REMINDER (per CLAUDE.md): maintain the append-only research journal at
/workspace/JOURNAL.md (or /workspace/JOURNAL/YYYY-MM-DD.md if that dir exists).
Append a UTC-timestamped entry for each MEANINGFUL step — a decision, a
hypothesis, an action with non-obvious effect, an observation that changed the
plan, or a dead end. Skip routine single-file edits. Never overwrite; always
append. Add a "Session summary" entry before you finish.
MSG
elif [[ "$event" == "UserPromptSubmit" ]]; then
  echo "Journal reminder: append meaningful steps (decisions, non-obvious effects, dead ends) to /workspace/JOURNAL.md as you go — skip routine edits; never overwrite."
fi
exit 0
