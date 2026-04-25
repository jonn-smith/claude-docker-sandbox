#!/usr/bin/env bash

################################################################################
# Debugging code.  If this works, you can comment this out.
echo "" >> ~/claude-hook-debug.log
echo "##################################################" >> ~/claude-hook-debug.log
echo "$(date +%s) - record-task-start.sh" >> ~/claude-hook-debug.log
echo "" >> ~/claude-hook-debug.log  

exec >> ~/claude-hook-debug.log 2>&1
set -x
################################################################################

TIMESTAMP_FILE="${HOME}/claude_task_start_$(basename $PWD)"
PROMPT_FILE="${HOME}/claude_task_prompt_$(basename $PWD)"

PAYLOAD=$(cat)

################################################################################

date +%s > "$TIMESTAMP_FILE"

echo "$PAYLOAD" | python3 -c "
import json, sys
d = json.load(sys.stdin)
prompt = d.get('prompt', '')
open('$PROMPT_FILE', 'w').write(prompt)
"

