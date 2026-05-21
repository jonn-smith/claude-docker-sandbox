#!/usr/bin/env bash

# Enable Vertex AI as the backend
export CLAUDE_CODE_USE_VERTEX=1

# Set the GCP project
export ANTHROPIC_VERTEX_PROJECT_ID=YOUR_PROJECT_ID

# Set the region
export CLOUD_ML_REGION=global

# Enable experimental features
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

# Set the default model
export ANTHROPIC_MODEL='claude-opus-4-7'


