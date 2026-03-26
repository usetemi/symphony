---
tracker:
  kind: linear
  project_slug: "temi-dev-7a6288c73902"
  active_states:
    - Todo
    - In Progress
    - Merging
    - Rework
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 30000
workspace:
  root: /data/workspaces
hooks:
  timeout_ms: 600000
  after_create: |
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
    if [ -d /data/template-workspace/.git ]; then
      cp -a /data/template-workspace/. .
      git fetch origin main --depth 1
      git reset --hard origin/main
      cd apps/usetemi && npm install --prefer-offline
    else
      git clone --depth 1 git@github.com:usetemi/temi.git .
      cd apps/usetemi && npm install
    fi
  before_run: |
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
    cd apps/usetemi && git fetch origin main
  after_run: |
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
    cd apps/usetemi && npm run verify
agent:
  max_concurrent_agents: 3
  max_turns: 1
codex:
  command: claude --print --dangerously-skip-permissions --output-format stream-json --verbose --model claude-opus-4-6
  stall_timeout_ms: 3600000
server:
  port: 4000
  host: "0.0.0.0"
---

You are working on Linear ticket `{{ issue.identifier }}` for the Temi Health app. This is an autonomous, unattended session. Complete the full pipeline without human intervention.

{% if attempt %}This is retry attempt #{{ attempt }}. Resume from current workspace state. Do not repeat completed work.{% endif %}

## Your task

**{{ issue.identifier }}: {{ issue.title }}**
State: {{ issue.state }}
URL: {{ issue.url }}

{% if issue.description %}{{ issue.description }}{% else %}No description provided.{% endif %}

## What you must do (in order)

1. **Move to In Progress**: `linear issue update {{ issue.identifier }} --state "In Progress"`
2. **Read CLAUDE.md** for project conventions
3. **Implement the change** described above. Only modify files in `apps/usetemi/`.
4. **Create a branch and commit**:
   ```bash
   git checkout -b symphony/{{ issue.identifier | downcase }}-fix
   git add -A
   git commit -m "description of change

   Closes {{ issue.identifier }}"
   ```
5. **Push and create PR**:
   ```bash
   git push -u origin symphony/{{ issue.identifier | downcase }}-fix
   gh pr create --title "description of change" --body "Closes {{ issue.identifier }}"
   ```
6. **Move to Human Review**: `linear issue update {{ issue.identifier }} --state "Human Review"`

## Tools available

- `linear` CLI for Linear operations (already authenticated)
- `gh` CLI for GitHub operations (already authenticated)
- Standard Claude Code tools (Read, Edit, Write, Bash, Glob, Grep)

## Rules

- Only modify files in `apps/usetemi/` and root config files
- Do not ask for human input -- this is unattended
- If blocked, move to Human Review with a note explaining the blocker
- If the issue state is `Done`, `Backlog`, or `Human Review`, do nothing
