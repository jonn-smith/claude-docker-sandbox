#!/usr/bin/env bash
# setup_host_macos.sh — macOS host bootstrap (called via setup_host.sh).
#
# STATUS: stub. Real implementation lands in a follow-up commit. Running
# this today just prints what WILL happen and exits non-zero so an
# operator isn't fooled into thinking setup completed.
#
# Planned coverage:
#   - Install Homebrew if missing.
#   - Install Docker Desktop (or document OrbStack as the faster alt).
#   - Install coreutils (greadlink + friends), python3, fzf, jq.
#   - Run host_fiss_mcp/install.sh (POSIX, same as Linux side).
#   - Document SMTP-AUTH relay setup for email notifications (Gmail/SES/
#     SendGrid) — credentials are personal, so no auto-config.
#   - Skip: docker group add (Docker Desktop handles), postfix mynetworks
#     (no host postfix path), sysbox / NVIDIA work (not applicable).
set -euo pipefail

RED=$'\033[1;31m'; YEL=$'\033[1;33m'; RST=$'\033[0m'

cat >&2 <<EOF
${YEL}setup_host_macos.sh: NOT YET IMPLEMENTED${RST}

This script is a placeholder. The macOS host bootstrap is being assembled
in a separate commit on the feat/macos-support branch. To stand a host up
manually in the meantime:

  brew install --cask docker        # or: brew install orbstack
  brew install coreutils python@3.12 fzf jq
  bash host_fiss_mcp/install.sh
  # Mail relay (optional): configure /etc/postfix/main.cf with smtp_auth
  # against Gmail/SES/SendGrid, or skip notifications entirely.

Then ./run_claude_docker.sh should work — it has macOS-aware branches.

${RED}Exiting non-zero so you don't think setup completed.${RST}
EOF
exit 1
