#!/usr/bin/env bash

################################################################################
# Debugging code.  If this works, you can comment this out.
#echo "" >> ~/claude-hook-debug.log
#echo "##################################################" >> ~/claude-hook-debug.log
#echo "$(date +%s) - notify-if-long.sh" >> ~/claude-hook-debug.log
#echo "" >> ~/claude-hook-debug.log  
#
#exec >> ~/claude-hook-debug.log 2>&1
#set -x
################################################################################

PROMPT_FILE="${HOME}/claude_task_prompt_$(basename $PWD)"

# Must determine dynamically:
HOST_IP=$(ip route | awk '/default/ {print $3}')
SMTP_PORT=25

# Notification config — set via env in env.<INSTANCE>.sh, forwarded by
# run_claude_docker.sh into the container. Hook is a no-op if
# CLAUDE_NOTIFY_EMAIL is unset/empty.
CLAUDE_FROM_ADDRESS="${CLAUDE_NOTIFY_FROM:-claude-sandbox}"
REAL_HOST_NAME="${CLAUDE_NOTIFY_HOSTNAME:-$(hostname -f 2>/dev/null || hostname)}"
YOUR_EMAIL="${CLAUDE_NOTIFY_EMAIL:-}"

################################################################################

if [[ -z "$YOUR_EMAIL" ]]; then
  exit 0
fi

################################################################################

NOW=$(date +%s)

PROMPT=$(cat "$PROMPT_FILE" 2>/dev/null || echo "(prompt unavailable)")
rm -f "$PROMPT_FILE"

PAYLOAD=$(cat)

# Exit cleanly if the payload is empty
if [ -z "$PAYLOAD" ]; then
  exit 0
fi

# Use Python to diagnose the exact cause of the stop event.
# Python will output a single line in the format: STATUS_CODE|DETAILED_MESSAGE
DIAGNOSIS=$(echo "$PAYLOAD" | python3 -c '
import sys, json

try:
    data = json.load(sys.stdin)
    
    # Extract fields safely
    stop_reason = data.get("stop_reason") or data.get("stopReason") or ""
    error = data.get("error") or {}
    error_type = error.get("type", "")
    error_msg = error.get("message", "")
    
    # 1. Check if maximum output token limit was hit
    if stop_reason == "max_tokens":
        print("MAX_TOKENS|Claude reached its maximum output token limit mid-task.")
        
    # 2. Check if it is a billing / credit exhaustion issue
    elif error_type == "insufficient_quota" or "balance" in error_msg.lower():
        print("QUOTA_EXHAUSTED|Claude ran out of account credits or API quota.")
        
    # 3. Check if it is any other type of failure (e.g., rate limits, network drops)
    elif error_type or error_msg:
        # Sanitize strings to prevent breaking Bash execution
        clean_type = str(error_type).replace("|", "-").replace("\"", "\x27")
        clean_msg = str(error_msg).replace("|", "-").replace("\"", "\x27")
        print(f"OTHER_FAILURE|API Error [{clean_type}]: {clean_msg}")
        
    else:
        print("NONE|")

except Exception as e:
    # Fail silently if JSON is corrupted or structural anomalies occur
    print("NONE|")
')

# Split the Python output by the pipe delimiter into STATUS and MSG variables
IFS='|' read -r STATUS MSG <<< "$DIAGNOSIS"

# If an actionable status was returned, execute the alerts
if [ "$STATUS" != "NONE" ] && [ -n "$STATUS" ]; then

SUBJECT="[Claude] ${STATUS} pwd:$(basename $PWD)"

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

${STATUS}
${MSG}

Project: $(basename $PWD)
Prompt: ${PROMPT}

--- FULL PAYLOAD ---

${PAYLOAD}

EOF

fi

