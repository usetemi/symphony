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
# Stage 2: Runtime image (runs as root — no user switching)
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
    # Node.js 24.x
    curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI and Linear CLI globally
RUN npm install -g @anthropic-ai/claude-code @kyaukyuai/linear-cli

# Install Playwright and Chromium for screenshot capture
RUN npx playwright install-deps chromium && \
    npx playwright install chromium

# Install `web` CLI tool (Go binary) for page screenshots
RUN curl -fsSL https://raw.githubusercontent.com/chrismccord/web/main/web-linux-amd64 \
      -o /usr/local/bin/web && \
    chmod +x /usr/local/bin/web

# Create a non-root user for Claude Code (which refuses --dangerously-skip-permissions as root)
# Symphony orchestrator and hooks run as root; only the claude CLI runs as this user.
RUN useradd -m -s /bin/bash claude && \
    ln -s /data/claude-auth /home/claude/.claude && \
    mkdir -p /home/claude/.ssh && \
    ssh-keyscan github.com >> /home/claude/.ssh/known_hosts 2>/dev/null

# Copy escript binary
COPY --from=build /app/bin/symphony /usr/local/bin/symphony
RUN chmod +x /usr/local/bin/symphony

# Copy entrypoint
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Create volume mount points and set up home
RUN mkdir -p /data/workspaces /data/claude-auth /data/logs && \
    ln -s /data/claude-auth /root/.claude && \
    mkdir -p /root/.ssh && \
    ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

# Copy workflow and scripts
COPY deploy/WORKFLOW.md /root/WORKFLOW.md
COPY deploy/prepare-template.sh /root/prepare-template.sh
RUN chmod +x /root/prepare-template.sh

WORKDIR /root
EXPOSE 4000
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
