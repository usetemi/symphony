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
if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "[symphony] Configuring GitHub token auth..."
    # Rewrite SSH clone URLs to HTTPS with token
    git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
    # Also rewrite plain HTTPS URLs (use --add to keep both insteadOf entries)
    git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

# --- Git identity for commits made by the agent ---
git config --global user.name "Symphony"
git config --global user.email "symphony@usetemi.com"

# --- Ensure workspace root exists ---
mkdir -p /data/workspaces

# --- Write Linear MCP config for Claude Code ---
cat > /home/symphony/mcp-linear.json <<MCPEOF
{
  "mcpServers": {
    "linear": {
      "type": "http",
      "url": "https://mcp.linear.app/mcp"
    }
  }
}
MCPEOF
echo "[symphony] Linear MCP config written"

# --- Claude auth check ---
if [ ! -d /data/claude-auth ] || [ -z "$(ls -A /data/claude-auth 2>/dev/null)" ]; then
    echo "[symphony] WARNING: No Claude auth found in /data/claude-auth/"
    echo "[symphony] Run 'fly ssh console' and then 'claude setup-token' to authenticate."
fi

# --- Launch Symphony ---
exec /usr/local/bin/symphony \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --port 4000 \
    --logs-root /data/logs \
    /home/symphony/WORKFLOW.md
