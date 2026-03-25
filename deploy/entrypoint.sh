#!/bin/bash
set -euo pipefail

# =============================================================================
# Symphony entrypoint for Fly.io
#
# Expects:
#   - /data/workspaces  (Fly volume) — workspace root
#   - /data/claude-auth (Fly volume) — ~/.claude symlinked here
#   - /data/logs        (Fly volume) — log output
#   - GIT_SSH_KEY       (Fly secret, optional) — deploy key for private repos
#   - LINEAR_API_KEY    (Fly secret) — Linear API token
#   - GITHUB_TOKEN      (Fly secret, optional) — for gh CLI in agent sessions
# =============================================================================

echo "[symphony] Starting Symphony orchestrator..."

# --- Git SSH key setup (if provided as a Fly secret) ---
if [ -n "${GIT_SSH_KEY:-}" ]; then
    echo "[symphony] Configuring Git SSH deploy key..."
    mkdir -p ~/.ssh
    echo "$GIT_SSH_KEY" > ~/.ssh/id_ed25519
    chmod 600 ~/.ssh/id_ed25519
    # Ensure known_hosts has github.com
    ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null || true
fi

# --- Git identity for commits made by the agent ---
git config --global user.name "Symphony"
git config --global user.email "symphony@usetemi.com"

# --- Ensure workspace root exists ---
mkdir -p /data/workspaces

# --- Claude auth check ---
if [ ! -f /data/claude-auth/.credentials.json ] && [ ! -f /data/claude-auth/credentials.json ]; then
    echo "[symphony] WARNING: No Claude auth found in /data/claude-auth/"
    echo "[symphony] Run 'fly ssh console' and then 'claude setup-token' to authenticate."
fi

# --- Launch Symphony ---
exec /usr/local/bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port 4000 \
    --logs-root /data/logs \
    /home/symphony/WORKFLOW.md
