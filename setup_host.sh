#!/usr/bin/env bash
# setup_host.sh — host bootstrap dispatcher.
#
# Detects the host OS via `uname -s` and forwards execution to the
# OS-specific helper under scripts/. Users always invoke this script,
# not the helpers, so the entry point stays the same across platforms.
#
# Supported helpers:
#   scripts/setup_host_linux.sh   (Linux: Debian/Ubuntu apt path)
#   scripts/setup_host_macos.sh   (macOS: Homebrew + Docker Desktop/OrbStack)
#
# Args + env are forwarded verbatim. To force a specific helper for
# testing, set SETUP_HOST_OS=linux or SETUP_HOST_OS=macos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

OS_KEY="${SETUP_HOST_OS:-}"
if [[ -z "$OS_KEY" ]]; then
  case "$(uname -s)" in
    Linux)  OS_KEY=linux ;;
    Darwin) OS_KEY=macos ;;
    *)
      echo "setup_host.sh: unsupported host OS '$(uname -s)'." >&2
      echo "                Supported: Linux (Debian/Ubuntu), macOS." >&2
      exit 1
      ;;
  esac
fi

HELPER="${SCRIPT_DIR}/scripts/setup_host_${OS_KEY}.sh"
if [[ ! -x "$HELPER" ]]; then
  if [[ -f "$HELPER" ]]; then
    echo "setup_host.sh: helper exists but is not executable: $HELPER" >&2
    echo "                Run: chmod +x $HELPER" >&2
  else
    echo "setup_host.sh: no helper for OS '$OS_KEY' at $HELPER" >&2
  fi
  exit 1
fi

echo "setup_host.sh: dispatching to $(basename "$HELPER")"
exec "$HELPER" "$@"
