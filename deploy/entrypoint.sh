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

# --- Git identity and safe directory ---
git config --global user.name "Symphony"
git config --global user.email "symphony@usetemi.com"
git config --global --add safe.directory '*'
git config --global core.fileMode false

# --- Ensure volume directories exist ---
mkdir -p /data/workspaces /data/claude-auth /data/logs

# --- Configure git and permissions for claude user (non-root for Claude Code CLI) ---
cp /root/.gitconfig /home/claude/.gitconfig
chown claude:claude /home/claude/.gitconfig
chown -R claude:claude /data/claude-auth
chmod -R 777 /data/workspaces

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

# --- Template workspace preparation is deferred ---
# Skipped at startup to avoid OOM (npm install competes with workspace setup).
# The template is populated by the after_create hook on the first successful run.

# --- Launch Symphony ---
exec /usr/local/bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port 4000 \
    --logs-root /data/logs \
    /root/WORKFLOW.md
