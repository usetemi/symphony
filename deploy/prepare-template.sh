#!/bin/bash
set -euo pipefail

# =============================================================================
# Prepare a cached template workspace for Symphony.
#
# Clones the temi repo and installs node_modules into /data/template-workspace
# so that after_create hooks can copy from here instead of cloning + installing
# from scratch (~5 min → ~30 sec).
#
# Run as the symphony user (called from entrypoint after chown).
# =============================================================================

TEMPLATE_DIR="/data/template-workspace"
LOCK_FILE="/data/template-workspace.lock"
REPO_URL="git@github.com:usetemi/temi.git"

export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"

# Skip if another process is already preparing the template
if [ -f "$LOCK_FILE" ]; then
    echo "[template] Lock file exists, skipping template preparation"
    exit 0
fi

trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

if [ -d "$TEMPLATE_DIR/.git" ]; then
    echo "[template] Updating existing template workspace..."
    cd "$TEMPLATE_DIR"
    git fetch origin main --depth 1
    git reset --hard origin/main
    cd apps/usetemi
    npm install --prefer-offline 2>&1 | tail -1
else
    echo "[template] Creating template workspace from scratch..."
    rm -rf "$TEMPLATE_DIR"
    mkdir -p "$TEMPLATE_DIR"
    cd "$TEMPLATE_DIR"
    git clone --depth 1 "$REPO_URL" .
    cd apps/usetemi
    npm install 2>&1 | tail -1
fi

echo "[template] Template workspace ready at $TEMPLATE_DIR"
