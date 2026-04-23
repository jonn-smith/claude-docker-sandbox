#!/usr/bin/env bash

THRESHOLD=120
TIMESTAMP_FILE="/tmp/.claude_task_start_$(basename $PWD)"
# NOTE: 172.17.0.1 is the default
#       Port 25 is SMTP
HOST_IP=172.17.0.1
SMTP_PORT=25

CLAUDE_FROM_ADDRESS="claude-sandbox"
REAL_HOST_NAME="dsde-methods-jonn-juffowup"
YOUR_EMAIL="jonn@broadinstitute.org"

PAYLOAD=$(cat)

if [ ! -f "$TIMESTAMP_FILE" ]; then
  date +%s > "$TIMESTAMP_FILE"
  exit 0
fi

START=$(cat "$TIMESTAMP_FILE")
NOW=$(date +%s)
ELAPSED=$((NOW - START))
rm -f "$TIMESTAMP_FILE"

if [ "$ELAPSED" -ge "$THRESHOLD" ]; then
  TRANSCRIPT=$(echo "$PAYLOAD" | python3 -c "
import json, sys
data = json.load(sys.stdin)
messages = data.get('transcript', [])
output = []
for msg in messages:
    role = msg.get('role', '')
    content = msg.get('content', '')
    if isinstance(content, list):
        text = ' '.join(b.get('text','') for b in content if b.get('type') == 'text')
    else:
        text = str(content)
    if text.strip():
        output.append(f'{role.upper()}: {text[:500]}')
print('\n\n'.join(output))
")

  SUBJECT_SUMMARY=$(echo "$TRANSCRIPT" | claude -p "Summarize this task in 5 words or fewer, \
no punctuation, no unicode, plain ASCII only. \
Examples: 'refactored auth module', 'fixed login bug', 'added unit tests'. \
Reply with only the summary, nothing else.")

  SUMMARY=$(echo "$TRANSCRIPT" | claude -p "You are summarizing a completed Claude Code task for a notification email. \
In 3-5 sentences, describe: what the user asked for, what was accomplished, \
and any important outcomes or files changed. Be specific and concrete. \
Do not start with 'The user' — write naturally as if briefing someone.")

  SUBJECT="[Claude] Task Done: ${SUBJECT_SUMMARY} - pwd:$(basename $PWD) (${ELAPSED}s)"
  BODY="Project: $(basename $PWD)
Duration: ${ELAPSED}s

${SUMMARY}"


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

${BODY}
EOF

fi

