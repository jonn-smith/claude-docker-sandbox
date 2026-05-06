#!/usr/bin/env bash
# uid-fixup-entrypoint.sh — runs as root, remaps the bundled "claude" user
# to match the host invoker's UID/GID (passed via HOST_UID / HOST_GID), then
# drops privileges and execs the real entrypoint as claude. Lets a single
# image be shared across hosts with different user IDs without rebuilding.
set -euo pipefail

DEFAULT_CMD=(/home/claude/start_script.sh)
TARGET_UID="${HOST_UID:-}"
TARGET_GID="${HOST_GID:-}"

CUR_UID="$(id -u claude)"
CUR_GID="$(id -g claude)"

if [[ -n "$TARGET_GID" && "$TARGET_GID" != "$CUR_GID" ]]; then
  # -o allows duplicate gid (some hosts share gid with another system group)
  groupmod -o -g "$TARGET_GID" claude
fi

if [[ -n "$TARGET_UID" && "$TARGET_UID" != "$CUR_UID" ]]; then
  usermod -o -u "$TARGET_UID" claude

  # Only /home/claude needs ownership fixup — it has 644-mode dotfiles
  # (.bashrc, .msmtprc) that need to be writable by claude. /opt/claude-venv,
  # /usr/local/cargo, and /usr/local/rustup were chmod'd a+rwX at image
  # build time, so any UID can read+write them without a costly chown -R.
  chown -R "$TARGET_UID":"${TARGET_GID:-$CUR_GID}" /home/claude 2>/dev/null || true
fi

# Drop to claude and run the real entrypoint. exec-form so signals reach it.
exec gosu claude "${@:-${DEFAULT_CMD[@]}}"
