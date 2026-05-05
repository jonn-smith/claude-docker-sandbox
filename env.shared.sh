#!/usr/bin/env bash
# Shared-state instance — settings, skills, plugins, hooks, memory, and
# sessions come from claude-sandbox-shared/.claude (populated by
# ./migrate_to_shared.sh).
#
# Existing instances (main, B, WHB) are untouched and keep using their own
# per-instance state. Promote them to shared mode later by adding
# CLAUDE_SANDBOX_USE_SHARED=1 to their env.<INSTANCE>.sh.

export CLAUDE_SANDBOX_INSTANCE=shared
export CLAUDE_SANDBOX_USE_SHARED=1

export CLAUDE_SANDBOX_CONTEXT_DIR=/juffowup2/claude_projects/context_reference

# Select your project dir:
export CLAUDE_SANDBOX_PROJECTS_DIR=/juffowup2/claude_projects
