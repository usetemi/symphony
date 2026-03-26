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
      # Cache this workspace as template for future runs
      rm -rf /data/template-workspace
      cp -a "$(cd ../.. && pwd)" /data/template-workspace
    fi
  before_run: |
    export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
    chown -R claude:claude .
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

**If the issue state is `Merging`**, skip the entire implementation pipeline and go directly to the Merge step below.

### Merge (Merging state only)

The human has approved this issue. Squash-merge the PR and clean up:

```bash
PR_NUMBER=$(gh pr list --search "{{ issue.identifier }}" --json number --jq '.[0].number')
gh pr merge $PR_NUMBER --squash --delete-branch
linear issue update {{ issue.identifier }} --state "Done"
```

If the merge fails (e.g., CI checks pending, merge conflicts), post a comment to Linear explaining the blocker and move back to Human Review.

After merging, stop. Do not continue to the implementation steps.

---

Follow these steps in order for **Todo** and **Rework** states.

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

### 8. Post proof to Linear (REQUIRED)

You MUST post proof before moving to Human Review. Do not skip this step.

**Step 8a: Post verify results.** Run `npm run verify` in `apps/usetemi`, capture the output, and post it as a comment on the Linear issue using `linear issue comment {{ issue.identifier }}`. Include typecheck and test results.

**Step 8b: Take and post screenshots (if UI change).** If the change affects anything visible in the browser:

1. Start the dev server: `cd apps/usetemi && npm run dev &` and wait ~15 seconds for it to compile
2. Take a screenshot: `npx playwright screenshot --full-page http://localhost:3000/<affected-page> /tmp/proof.png`
3. Upload to Linear using their file upload API:

```bash
SIZE=$(stat -c%s /tmp/proof.png)
UPLOAD_RESPONSE=$(curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d "{\"query\": \"mutation { fileUpload(size: $SIZE, contentType: \\\"image/png\\\", filename: \\\"proof.png\\\", makePublic: true) { success uploadFile { uploadUrl assetUrl headers { key value } } } }\"}")
UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['uploadUrl'])")
ASSET_URL=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['fileUpload']['uploadFile']['assetUrl'])")
curl -s -X PUT \
  -H "Content-Type: image/png" \
  -H "x-goog-content-length-range: $SIZE,$SIZE" \
  -H "Content-Disposition: attachment; filename=\"proof.png\"" \
  --data-binary @/tmp/proof.png "$UPLOAD_URL"
```

4. Post to Linear: `linear issue comment add {{ issue.identifier }} "## Screenshot\n\n![proof]($ASSET_URL)"`
5. Clean up: `kill %1 2>/dev/null`

Take multiple screenshots if needed. Use `--viewport-size 1280,720` for consistent sizing.

### 9. Move to Human Review

```bash
linear issue update {{ issue.identifier }} --state "Human Review"
```

## Tools available

- `linear` CLI for Linear operations (already authenticated)
- `gh` CLI for GitHub operations (already authenticated)
- `npx playwright screenshot` for page screenshots (`npx playwright screenshot --full-page <url> <path>`)
- Standard Claude Code tools (Read, Edit, Write, Bash, Glob, Grep)

## Rules

- Only modify files in `apps/usetemi/` and root config files
- Do not ask for human input -- this is unattended
- If blocked, move to Human Review with a note explaining the blocker
- If the issue state is `Done`, `Backlog`, or `Human Review`, do nothing
- If the issue state is `Merging`, squash-merge the PR and move to Done (skip implementation)
- On Rework, always read feedback first and push to the existing branch
- NEVER move to Human Review without posting proof to Linear first (step 8)
- If screenshots fail, still post test/verify results as proof
