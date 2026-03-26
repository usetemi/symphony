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
  command: su claude -c 'claude --print --dangerously-skip-permissions --output-format stream-json --verbose --model claude-opus-4-6'
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

## Pipeline

Follow these steps in order.

### 1. Move to In Progress

```bash
linear issue update {{ issue.identifier }} --state "In Progress"
```

### 2. Read feedback (Rework only)

If this issue's state is `Rework`, there is an existing PR with review feedback. Before implementing, read all feedback:

```bash
# Find the existing PR for this issue
PR_NUMBER=$(gh pr list --search "{{ issue.identifier }}" --json number --jq '.[0].number')

# Read GitHub PR review comments
gh api repos/usetemi/temi/pulls/$PR_NUMBER/reviews --jq '.[] | {user: .user.login, state: .state, body: .body}'
gh api repos/usetemi/temi/pulls/$PR_NUMBER/comments --jq '.[] | {user: .user.login, path: .path, line: .line, body: .body}'

# Read Linear issue comments
linear issue comments {{ issue.identifier }}
```

Synthesize the feedback into a plan. Address every requested change. Push new commits to the **existing branch** (do not create a new PR).

### 3. Read CLAUDE.md

Read `CLAUDE.md` at the repo root for project conventions.

### 4. Implement the change

Only modify files in `apps/usetemi/` and root config files. Write or update tests for the change when appropriate.

### 5. Verify locally

```bash
cd apps/usetemi && npm run verify
```

Fix any typecheck, lint, or test failures before proceeding.

### 6. Commit and push

For **new work** (Todo):
```bash
git checkout -b symphony/{{ issue.identifier | downcase }}-fix
git add -A
git commit -m "description of change

Closes {{ issue.identifier }}"
git push -u origin symphony/{{ issue.identifier | downcase }}-fix
```

For **rework** (existing PR):
```bash
git add -A
git commit -m "address review feedback

Closes {{ issue.identifier }}"
git push
```

### 7. Create PR (new work only)

Skip this step if reworking an existing PR.

```bash
gh pr create --title "description of change" --body "Closes {{ issue.identifier }}"
```

### 8. Post proof to Linear

Post evidence that the change works to the Linear issue so reviewers can verify without pulling the branch.

#### 8a. Test results

Capture test output and post a summary:

```bash
cd apps/usetemi
TEST_OUTPUT=$(npm test 2>&1 | tail -30)
TYPECHECK_OUTPUT=$(npm run typecheck 2>&1 | tail -5)

linear issue comment {{ issue.identifier }} --body "## Verification

### Typecheck
\`\`\`
$TYPECHECK_OUTPUT
\`\`\`

### Tests
\`\`\`
$TEST_OUTPUT
\`\`\`
"
```

#### 8b. Screenshots (if UI change)

If the change affects UI, start the dev server, take screenshots, and post them:

```bash
cd apps/usetemi

# Start dev server in background
npm run dev &
DEV_PID=$!
sleep 10

# Take screenshots of affected pages
web http://localhost:3000/<affected-page> --screenshot /tmp/proof-1.png

# Upload to GitHub draft release for hosting
PR_NUMBER=$(gh pr list --search "{{ issue.identifier }}" --json number --jq '.[0].number')
gh release create pr-${PR_NUMBER}-assets --title "PR #${PR_NUMBER} assets" --notes "" --draft 2>/dev/null || true
gh release upload pr-${PR_NUMBER}-assets /tmp/proof-1.png --clobber
SCREENSHOT_URL=$(gh release view pr-${PR_NUMBER}-assets --json assets --jq '.assets[0].url')

# Post screenshot to Linear
linear issue comment {{ issue.identifier }} --body "## Screenshot

![proof]($SCREENSHOT_URL)"

# Clean up
kill $DEV_PID 2>/dev/null
```

Adapt the URLs and number of screenshots to the specific change. Take before/after screenshots when helpful.

### 9. Move to Human Review

```bash
linear issue update {{ issue.identifier }} --state "Human Review"
```

## Tools available

- `linear` CLI for Linear operations (already authenticated)
- `gh` CLI for GitHub operations (already authenticated)
- `web` CLI for page screenshots (`web <url> --screenshot <path>`)
- Standard Claude Code tools (Read, Edit, Write, Bash, Glob, Grep)

## Rules

- Only modify files in `apps/usetemi/` and root config files
- Do not ask for human input -- this is unattended
- If blocked, move to Human Review with a note explaining the blocker
- If the issue state is `Done`, `Backlog`, or `Human Review`, do nothing
- On Rework, always read feedback first and push to the existing branch
- Always post verification results to Linear before moving to Human Review
