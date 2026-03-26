#!/bin/bash
set -euo pipefail

# =============================================================================
# Symphony entrypoint for Fly.io
#
# Expects:
#   - /data/workspaces  (Fly volume) — workspace root
#   - /data/claude-auth (Fly volume) — ~/.claude symlinked here
#   - /data/logs        (Fly volume) — log output
#   - LINEAR_API_KEY    (Fly secret) — Linear API token
#   - GITHUB_TOKEN      (Fly secret) — for git clone and gh CLI
# =============================================================================

echo "[symphony] Starting Symphony orchestrator..."

# --- GitHub auth via token (rewrites SSH and HTTPS URLs) ---
# Write git config to symphony user's home (not root's) so hooks and agents see it.
export HOME=/home/symphony
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "[symphony] Configuring GitHub token auth..."
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
    git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

# --- Git identity for commits made by the agent ---
git config --global user.name "Symphony"
git config --global user.email "symphony@usetemi.com"

# Reset HOME for remaining root operations
export HOME=/root

# --- Ensure volume directories exist (owned by symphony) ---
mkdir -p /data/workspaces /data/claude-auth /data/logs
chown -R symphony:symphony /data

# --- Configure Linear CLI auth (as symphony user so config lands in the right home) ---
if [ -n "${LINEAR_API_KEY:-}" ]; then
    echo "[symphony] Configuring Linear CLI auth..."
    su symphony -c "linear auth login --key '${LINEAR_API_KEY}' --plaintext" 2>/dev/null || true
fi

# --- Claude auth check ---
if [ ! -d /data/claude-auth ] || [ -z "$(ls -A /data/claude-auth 2>/dev/null)" ]; then
    echo "[symphony] WARNING: No Claude auth found in /data/claude-auth/"
    echo "[symphony] Run 'fly ssh console' and then 'claude setup-token' to authenticate."
fi

# --- Prepare template workspace in background (as symphony user) ---
echo "[symphony] Preparing template workspace in background..."
su symphony -c 'bash /home/symphony/prepare-template.sh' &

# --- Launch Symphony as symphony user ---
exec su symphony -c '/usr/local/bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port 4000 \
    --logs-root /data/logs \
    /home/symphony/WORKFLOW.md'
