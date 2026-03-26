#!/bin/bash
set -euo pipefail

# =============================================================================
# Symphony entrypoint for Fly.io (runs as root — no user switching)
#
# Expects:
#   - /data volume mounted (workspaces, claude-auth, logs)
#   - LINEAR_API_KEY    (Fly secret)
#   - GITHUB_TOKEN      (Fly secret)
#   - CLAUDE_CODE_OAUTH_TOKEN (Fly secret)
# =============================================================================

echo "[symphony] Starting Symphony orchestrator..."

# --- GitHub auth via token (rewrites SSH and HTTPS URLs) ---
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "[symphony] Configuring GitHub token auth..."
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
    git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

# --- Git identity for commits ---
git config --global user.name "Symphony"
git config --global user.email "symphony@usetemi.com"

# --- Ensure volume directories exist ---
mkdir -p /data/workspaces /data/claude-auth /data/logs

# --- Configure Linear CLI auth ---
if [ -n "${LINEAR_API_KEY:-}" ]; then
    echo "[symphony] Configuring Linear CLI auth..."
    linear auth login --key "${LINEAR_API_KEY}" --plaintext 2>/dev/null || true
fi

# --- Claude auth check ---
if [ ! -d /data/claude-auth ] || [ -z "$(ls -A /data/claude-auth 2>/dev/null)" ]; then
    echo "[symphony] WARNING: No Claude auth found in /data/claude-auth/"
    echo "[symphony] Run 'fly ssh console' and then 'claude setup-token' to authenticate."
fi

# --- Prepare template workspace in background ---
echo "[symphony] Preparing template workspace in background..."
bash /root/prepare-template.sh &

# --- Launch Symphony ---
exec /usr/local/bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port 4000 \
    --logs-root /data/logs \
    /root/WORKFLOW.md
