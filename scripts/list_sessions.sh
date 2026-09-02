#!/usr/bin/env bash
# list_sessions.sh — list every Claude Code session across all state-dir
# layouts (current persistent-states/, pre-refactor
# claude-sandbox-persistent-state-*, and shared), most-recent-first.
#
#   scripts/list_sessions.sh                 # all sessions, newest last-activity first
#   scripts/list_sessions.sh <instance>      # only that instance (e.g. main, WHB)
#
# Thin wrapper over find_session.sh, which does the scanning. Use
# find_session.sh <name> to search by title/content instead.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FILTER="${1:-}"
out="$("$SCRIPT_DIR/find_session.sh" --all)" || { printf '%s\n' "$out"; exit 1; }

# Rows start with a layout keyword; header/sep/footer are everything else.
header="$(printf '%s\n' "$out" | grep -nE '^LAYOUT|^-+$' | tail -1 | cut -d: -f1)"
printf '%s\n' "$out" | sed -n "1,${header}p"          # column header + rule

rows="$(printf '%s\n' "$out" | grep -E '^(current|OLD|shared) ')"
[ -n "$FILTER" ] && rows="$(printf '%s\n' "$rows" | awk -v f="$FILTER" '$2==f')"
# Sort by the LAST column (field 4) descending — most recently active first.
printf '%s\n' "$rows" | sort -k4,4r

# Footer (the resume hint / OLD-layout note from find_session.sh).
printf '%s\n' "$out" | grep -vE '^(current|OLD|shared) |^LAYOUT|^-+$'
