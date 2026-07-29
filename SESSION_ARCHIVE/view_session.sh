#!/usr/bin/env bash
# view_session.sh — render an archived transcript as readable text.
# Usage:
#   ./view_session.sh <session-id-or-8char>     # searches all sources
#   ./view_session.sh path/to/file.jsonl
# Shows user + assistant turns (text only), skips tool spam and the
# title-gen / notification boilerplate that marks a sidecar. Pipe to less
# yourself if long:  ./view_session.sh abc123 | less -R
set -euo pipefail
ARCHIVE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
arg="${1:?usage: view_session.sh <session-id|file.jsonl>}"

if [ -f "$arg" ]; then
    f="$arg"
else
    f=$(find "$ARCHIVE" -name "${arg}*.jsonl" | head -1)
    [ -n "$f" ] || { echo "no transcript matching '$arg'" >&2; exit 1; }
fi
echo "### $f" >&2

jq -r '
  select(.type=="user" or .type=="assistant")
  | .type as $role
  | (.message.content // .content)
  | (if type=="array" then (map(.text? // "") | join("")) else . end)
  | select(. != null and . != "")
  | "\n=== \($role|ascii_upcase) ===\n" + .
' "$f"
