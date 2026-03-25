# Symphony Orchestrator — Claude Code adapter
# Multi-stage build: compile escript, then assemble runtime with Claude Code CLI

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-26.2.5.2-debian-bookworm-20260316-slim

# =============================================================================
# Stage 1: Build the Elixir escript
# =============================================================================
FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY elixir/ ./
RUN mix escript.build

# =============================================================================
# Stage 2: Runtime image
# Uses the same Elixir base (includes Erlang) + adds Node.js and Claude Code
# =============================================================================
FROM ${ELIXIR_IMAGE} AS runtime

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      xz-utils \
      gnupg && \
    # Node.js 24.x (required for Claude Code CLI and npm install in workspace hooks)
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI and Linear CLI globally
RUN npm install -g @anthropic-ai/claude-code @kyaukyuai/linear-cli

# Create non-root user
RUN useradd -m -s /bin/bash symphony

# Copy escript binary
COPY --from=build /app/bin/symphony /usr/local/bin/symphony
RUN chmod +x /usr/local/bin/symphony

# Copy entrypoint
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create volume mount points
RUN mkdir -p /data/workspaces /data/claude-auth /data/logs && \
    chown -R symphony:symphony /data

# Switch to non-root user
USER symphony
WORKDIR /home/symphony

# Symlink Claude auth to persistent volume
RUN ln -s /data/claude-auth /home/symphony/.claude

# SSH known_hosts for GitHub (fallback if using SSH instead of token)
RUN mkdir -p /home/symphony/.ssh && \
    ssh-keyscan github.com >> /home/symphony/.ssh/known_hosts 2>/dev/null

# Copy Temi WORKFLOW.md (workspace root adjusted for /data/workspaces)
COPY --chown=symphony:symphony deploy/WORKFLOW.md /home/symphony/WORKFLOW.md

EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
