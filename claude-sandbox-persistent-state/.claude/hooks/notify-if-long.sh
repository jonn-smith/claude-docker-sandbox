#!/usr/bin/env bash

################################################################################
exec >> ~/claude-hook-debug.log 2>&1
set -x
################################################################################

THRESHOLD=120
TIMESTAMP_FILE="/tmp/.claude_task_start_$(basename $PWD)"
HOST_IP=172.17.0.1
SMTP_PORT=25

CLAUDE_FROM_ADDRESS="claude-sandbox"
REAL_HOST_NAME="dsde-methods-jonn-juffowup"
YOUR_EMAIL="jonn@broadinstitute.org"

################################################################################

if [ ! -f "$TIMESTAMP_FILE" ]; then
  echo "No timestamp file found, skipping"
  exit 0
fi

################################################################################

START=$(cat "$TIMESTAMP_FILE")
NOW=$(date +%s)
ELAPSED=$((NOW - START))
rm -f "$TIMESTAMP_FILE"

PROMPT_FILE="/tmp/.claude_task_prompt_$(basename $PWD)"
PROMPT=$(cat "$PROMPT_FILE" 2>/dev/null || echo "(prompt unavailable)")
rm -f "$PROMPT_FILE"

PAYLOAD=$(cat)

if [ "$ELAPSED" -ge "$THRESHOLD" ]; then

  LAST_MESSAGE=$(echo "$PAYLOAD" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('last_assistant_message', ''))
")

  TRANSCRIPT_PATH=$(echo "$PAYLOAD" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('transcript_path', ''))
")

  BODY=$(python3 -c "
import json, sys
path = '$TRANSCRIPT_PATH'
try:
    with open(path) as f:
        lines = []
        for line in f:
            msg = json.loads(line)
            content = msg.get('content', '')
            if msg.get('role') == 'assistant':
                if isinstance(content, list):
                    text = ' '.join(b.get('text','') for b in content if b.get('type') == 'text')
                else:
                    text = str(content)
                if text.strip():
                    lines.extend(text.strip().splitlines())
    print('\n'.join(lines[-20:]))
except Exception as e:
    print(f'(could not read transcript: {e})')
")

  SUBJECT_SUMMARY=$(echo "$LAST_MESSAGE" | head -1 | cut -c1-60)
  SUBJECT="[Claude] Task Done: ${SUBJECT_SUMMARY} - pwd:$(basename $PWD) (${ELAPSED}s)"

curl smtp://${HOST_IP}:${SMTP_PORT} \
  --insecure \
  --mail-from "${CLAUDE_FROM_ADDRESS}@${REAL_HOST_NAME}" \
  --mail-rcpt "${YOUR_EMAIL}" \
  --upload-file - <<EOF
Message-ID: <$(date +%s%N)@${REAL_HOST_NAME}>
Date: $(date -R)
Subject: ${SUBJECT}
From: ${CLAUDE_FROM_ADDRESS}@${REAL_HOST_NAME}
To: ${YOUR_EMAIL}

Project: $(basename $PWD)
Duration: ${ELAPSED}s
Prompt: ${PROMPT}

--- Last 20 lines of output ---
${BODY}

${LAST_MESSAGE}

EOF

fi
