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

  # Reclaim image-baked claude-owned dirs that have the OLD numeric uid.
  # /home/claude is small. /opt/claude-venv has lots of files but they are
  # world-readable; only chown if claude needs to write back (e.g., pip
  # installs into the shared venv). Cheapest: chown only -home- and the
  # writable cargo/rustup roots.
  chown -R "$TARGET_UID":"${TARGET_GID:-$CUR_GID}" \
    /home/claude \
    /opt/claude-venv \
    /usr/local/cargo \
    /usr/local/rustup 2>/dev/null || true
fi

# Drop to claude and run the real entrypoint. exec-form so signals reach it.
exec gosu claude "${@:-${DEFAULT_CMD[@]}}"
