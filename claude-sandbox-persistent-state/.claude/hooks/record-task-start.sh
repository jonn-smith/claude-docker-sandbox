#!/usr/bin/env bash

exec >> ~/claude-hook-debug.log 2>&1
set -x

TIMESTAMP_FILE="/tmp/.claude_task_start_$(basename $PWD)"
PROMPT_FILE="/tmp/.claude_task_prompt_$(basename $PWD)"

PAYLOAD=$(cat)

date +%s > "$TIMESTAMP_FILE"

echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
prompt = d.get('prompt', '')
open('$PROMPT_FILE', 'w').write(prompt)
"
