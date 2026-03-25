# Symphony Orchestrator — Claude Code adapter
# Multi-stage build: compile escript, then assemble runtime with Claude Code CLI

# =============================================================================
# Stage 1: Build the Elixir escript
# =============================================================================
FROM hexpm/elixir:1.19.3-erlang-28.0.1-debian-bookworm-20250428-slim AS build

RUN apt-get update -y && \
    apt-get install -y --no-install-recommends build-essential git && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

# Cache deps
COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

# Build escript
COPY elixir/ ./
RUN mix escript.build

# =============================================================================
# Stage 2: Runtime image
# =============================================================================
FROM debian:bookworm-slim AS runtime

# Install Erlang runtime, Node.js 24, git, SSH, and other tools
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      gnupg && \
    # Erlang runtime
    curl -fsSL https://binaries2.erlang-solutions.com/debian/erlang_solutions.asc | gpg --dearmor -o /usr/share/keyrings/erlang-archive-keyring.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/erlang-archive-keyring.gpg] https://binaries2.erlang-solutions.com/debian bookworm contrib" > /etc/apt/sources.list.d/erlang.list && \
    apt-get update -y && \
    apt-get install -y --no-install-recommends esl-erlang && \
    # Node.js 24.x
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    # Cleanup
    rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI globally
RUN npm install -g @anthropic-ai/claude-code

# Create non-root user
RUN useradd -m -s /bin/bash symphony

# Copy escript binary
COPY --from=build /app/bin/symphony /usr/local/bin/symphony
RUN chmod +x /usr/local/bin/symphony

# Copy entrypoint (must be before USER switch for /usr/local/bin write access)
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

# SSH config for GitHub (pre-populate known_hosts)
RUN mkdir -p /home/symphony/.ssh && \
    ssh-keyscan github.com >> /home/symphony/.ssh/known_hosts 2>/dev/null

# Copy Temi WORKFLOW.md (workspace root adjusted for /data/workspaces)
COPY --chown=symphony:symphony deploy/WORKFLOW.md /home/symphony/WORKFLOW.md

EXPOSE 4000

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
