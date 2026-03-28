# Claude Code CLI Best Practices & Vibe Coding Guide (March 2026)

Comprehensive, actionable reference for configuring Claude Code for maximum autonomy,
productivity, and quality. Based on official Anthropic documentation and community
best practices as of March 2026.

---

## Table of Contents

1. [Model Configuration (Opus 4.6)](#1-model-configuration-opus-46)
2. [Settings & Permissions](#2-settings--permissions)
3. [CLAUDE.md Best Practices](#3-claudemd-best-practices)
4. [Hooks (Pre-commit & Beyond)](#4-hooks-pre-commit--beyond)
5. [Custom Skills & Slash Commands](#5-custom-skills--slash-commands)
6. [Git Worktrees for Parallel Development](#6-git-worktrees-for-parallel-development)
7. [Autonomous Loops](#7-autonomous-loops)
8. [GitHub Actions CI Integration](#8-github-actions-ci-integration)
9. [Semantic Versioning & Auto-Bump](#9-semantic-versioning--auto-bump)
10. [Vibe Coding Workflow](#10-vibe-coding-workflow)

---

## 1. Model Configuration (Opus 4.6)

### Available Model Aliases

| Alias         | Resolves To         | Use Case                              |
|---------------|---------------------|---------------------------------------|
| `default`     | Varies by plan tier | Recommended starting point            |
| `sonnet`      | Sonnet 4.6          | Daily coding tasks                    |
| `opus`        | Opus 4.6            | Complex reasoning                     |
| `haiku`       | Haiku               | Simple, fast tasks                    |
| `opus[1m]`    | Opus 4.6 + 1M ctx   | Long sessions, large codebases       |
| `sonnet[1m]`  | Sonnet 4.6 + 1M ctx | Long sessions (extra usage required)  |
| `opusplan`    | Opus for plan, Sonnet for execution | Best of both worlds |

### Setting Opus 4.6 as Default

**Method 1: Environment variable (highest priority)**
```bash
# In ~/.zshrc or ~/.bashrc
export ANTHROPIC_MODEL=opus
# Or for 1M context:
export ANTHROPIC_MODEL="opus[1m]"
```

**Method 2: Settings file**
```json
{
  "model": "opus"
}
```

**Method 3: At startup**
```bash
claude --model opus
```

**Method 4: During session**
```
/model opus
```

### Effort Levels (Opus 4.6 Exclusive: max)

Effort controls adaptive reasoning depth. Opus 4.6 defaults to `medium`.

| Level    | Use Case                            | Available On       |
|----------|-------------------------------------|--------------------|
| `low`    | Straightforward tasks               | Opus 4.6, Sonnet 4.6 |
| `medium` | Default, balanced (recommended)     | Opus 4.6, Sonnet 4.6 |
| `high`   | Hard debugging, architecture        | Opus 4.6, Sonnet 4.6 |
| `max`    | Deepest reasoning, no token limit   | **Opus 4.6 only**    |

```bash
# Set effort for a session
claude --effort high

# During session
/effort high

# One-off deep reasoning (include in prompt)
# Include the word "ultrathink" in your prompt

# Environment variable (persists across sessions)
export CLAUDE_CODE_EFFORT_LEVEL=high
```

### Pin Model Versions (for Bedrock/Vertex/Foundry)

```bash
export ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-6'
export ANTHROPIC_DEFAULT_SONNET_MODEL='claude-sonnet-4-6'
export ANTHROPIC_DEFAULT_HAIKU_MODEL='claude-haiku-4-6'

# With 1M context:
export ANTHROPIC_DEFAULT_OPUS_MODEL='claude-opus-4-6[1m]'
```

### Key Environment Variables

| Variable                              | Purpose                                  |
|---------------------------------------|------------------------------------------|
| `ANTHROPIC_MODEL`                     | Override model for all sessions          |
| `ANTHROPIC_DEFAULT_OPUS_MODEL`        | Pin opus alias to specific version       |
| `ANTHROPIC_DEFAULT_SONNET_MODEL`      | Pin sonnet alias to specific version     |
| `ANTHROPIC_DEFAULT_HAIKU_MODEL`       | Pin haiku alias to specific version      |
| `CLAUDE_CODE_SUBAGENT_MODEL`          | Model for subagents                      |
| `CLAUDE_CODE_EFFORT_LEVEL`            | Default effort level                     |
| `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING` | Set to `1` to use fixed thinking budget |
| `CLAUDE_CODE_DISABLE_1M_CONTEXT`      | Set to `1` to disable 1M context         |

---

## 2. Settings & Permissions

### Settings File Hierarchy (Highest to Lowest Priority)

| Scope     | Location                                | Shared?               |
|-----------|-----------------------------------------|-----------------------|
| Managed   | Server-managed / plist / registry       | Yes (deployed by IT)  |
| User      | `~/.claude/settings.json`               | No                    |
| Project   | `.claude/settings.json`                 | Yes (commit to git)   |
| Local     | `.claude/settings.local.json`           | No (gitignored)       |

**IMPORTANT**: `permissions.deny` rules have the highest precedence regardless of scope.
A deny rule in global config cannot be overridden by any allow rule anywhere.
When the same array-valued setting appears in multiple scopes, arrays are concatenated and deduplicated.

### Full settings.json Example for Maximum Autonomy

**~/.claude/settings.json** (user-level):
```json
{
  "model": "opus",
  "alwaysThinkingEnabled": true,
  "skipDangerousModePermissionPrompt": true,
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "osascript -e 'display notification \"Claude Code needs your attention\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
  }
}
```

**.claude/settings.json** (project-level, committed to git):
```json
{
  "permissions": {
    "allow": [
      "Bash(docker compose *)",
      "Bash(docker build *)",
      "Bash(docker exec *)",
      "Bash(docker logs *)",
      "Bash(docker ps *)",
      "Bash(git *)",
      "Bash(gh *)",
      "Bash(make *)",
      "Bash(go *)",
      "Bash(python *)",
      "Bash(pip *)",
      "Bash(pnpm *)",
      "Bash(npm *)",
      "Bash(npx *)",
      "Bash(node *)",
      "Bash(curl *)",
      "Bash(jq *)",
      "Bash(ls *)",
      "Bash(mkdir *)",
      "Bash(chmod *)",
      "Bash(cat *)",
      "Bash(head *)",
      "Bash(tail *)",
      "Bash(wc *)",
      "Bash(tree *)",
      "Bash(which *)",
      "Bash(bash *)",
      "Bash(sh *)",
      "Read(*)",
      "Edit(*)",
      "Write(*)",
      "Glob(*)",
      "Grep(*)"
    ],
    "deny": []
  },
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path' | xargs npx prettier --write 2>/dev/null || true"
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'Reminder: Check CLAUDE.md for project conventions. Current sprint focus: check git log.'"
          }
        ]
      }
    ]
  }
}
```

### Permission Modes

| Mode                              | How                                          | Safety          |
|-----------------------------------|----------------------------------------------|-----------------|
| Default                           | Prompts for each risky action                | Highest         |
| Auto mode                         | Classifier handles approvals                 | High            |
| Accept edits                      | `Shift+Tab` to cycle; auto-accepts file edits| Medium          |
| Plan mode                         | Read-only exploration                        | Safest          |
| `--dangerously-skip-permissions`  | Bypasses ALL checks                          | **None**        |

```bash
# Auto mode (recommended for autonomous work)
claude --permission-mode auto -p "fix all lint errors"

# Plan mode (safe exploration)
claude --permission-mode plan

# DANGEROUS: Only for disposable containers/CI
claude -p "run tests" --dangerously-skip-permissions
```

---

## 3. CLAUDE.md Best Practices

### Golden Rules

1. **Keep it under 200 lines** -- bloated files cause Claude to ignore instructions
2. **For each line, ask: "Would removing this cause Claude to make mistakes?"** If not, cut it
3. **Check it into git** -- the file compounds in value over time
4. **Run `/init` to generate a starter** then refine
5. **Use emphasis for critical rules**: "IMPORTANT" or "YOU MUST"

### What to Include vs. Exclude

| Include                                             | Exclude                                          |
|-----------------------------------------------------|--------------------------------------------------|
| Bash commands Claude cannot guess                   | Anything Claude can figure out from code         |
| Code style rules differing from defaults            | Standard language conventions Claude knows        |
| Testing instructions and preferred test runners     | Detailed API docs (link instead)                 |
| Repo etiquette (branch naming, PR conventions)      | Information that changes frequently              |
| Architectural decisions specific to your project    | Long explanations or tutorials                   |
| Developer environment quirks (required env vars)    | File-by-file codebase descriptions               |
| Common gotchas or non-obvious behaviors             | Self-evident practices like "write clean code"   |

### CLAUDE.md Locations

| Location                    | Applies To                    | Loaded           |
|-----------------------------|-------------------------------|------------------|
| `~/.claude/CLAUDE.md`      | All Claude sessions           | Always           |
| `./CLAUDE.md` (project root)| This project                 | Always           |
| Parent directories          | Monorepo inheritance          | Always           |
| Child directories           | Subdirectory context          | On demand        |

### Example CLAUDE.md Template

```markdown
# ProjectName

Brief one-line description of the project.

## Build & Test Commands

- `npm run build` -- build the project
- `npm run test` -- run all tests
- `npm run test -- path/to/test` -- run single test file
- `npm run lint` -- lint all files
- `npm run typecheck` -- TypeScript type checking

## Code Style

- Use ES modules (import/export), not CommonJS (require)
- Destructure imports when possible
- Use TypeScript strict mode
- Prefer functional components with hooks (React)

## Git Conventions

- Branch naming: `feat/description`, `fix/description`, `chore/description`
- Commit messages: conventional commits (feat:, fix:, chore:, docs:, test:)
- Always run `npm run test` and `npm run lint` before committing
- Create PRs against `main` branch

## Architecture

- src/api/ -- REST API routes (Express)
- src/services/ -- business logic
- src/models/ -- database models (Prisma)
- src/utils/ -- shared utilities

## Important Notes

- IMPORTANT: Never commit .env files
- Database migrations: use `npx prisma migrate dev`
- The API uses bearer token auth via middleware in src/middleware/auth.ts

## Imports with @

When importing files, reference other files to stay current:
- See @package.json for available npm commands
- See @tsconfig.json for TypeScript configuration
```

### CLAUDE.md vs. Hooks vs. Skills

| Mechanism  | Nature          | Reliability | Use For                                |
|------------|-----------------|-------------|----------------------------------------|
| CLAUDE.md  | Advisory        | ~80%        | Conventions, style, general guidance   |
| Hooks      | Deterministic   | 100%        | Formatting, linting, security gates    |
| Skills     | On-demand       | High        | Domain knowledge, reusable workflows   |

---

## 4. Hooks (Pre-commit & Beyond)

### Hook Lifecycle Events (21 Total as of March 2026)

| Event               | When it Fires                                          | Matcher Filters     |
|---------------------|--------------------------------------------------------|---------------------|
| `SessionStart`      | Session begins or resumes                              | startup/resume/clear/compact |
| `UserPromptSubmit`  | You submit a prompt                                    | No matcher support   |
| `PreToolUse`        | Before a tool call executes (can block)                | Tool name            |
| `PermissionRequest` | Permission dialog appears                              | Tool name            |
| `PostToolUse`       | After a tool call succeeds                             | Tool name            |
| `PostToolUseFailure`| After a tool call fails                                | Tool name            |
| `Notification`      | Claude needs attention                                 | Notification type    |
| `SubagentStart`     | Subagent spawned                                       | Agent type           |
| `SubagentStop`      | Subagent finishes                                      | Agent type           |
| `TaskCreated`       | Task created via TaskCreate                            | No matcher           |
| `TaskCompleted`     | Task marked completed                                  | No matcher           |
| `Stop`              | Claude finishes responding                             | No matcher           |
| `StopFailure`       | Turn ends due to API error                             | Error type           |
| `TeammateIdle`      | Agent team teammate about to go idle                   | No matcher           |
| `InstructionsLoaded`| CLAUDE.md or rules file loaded                         | Load reason          |
| `ConfigChange`      | Config file changes during session                     | Config source        |
| `CwdChanged`        | Working directory changes                              | No matcher           |
| `FileChanged`       | Watched file changes on disk                           | Filename             |
| `WorktreeCreate`    | Worktree being created                                 | No matcher           |
| `WorktreeRemove`    | Worktree being removed                                 | No matcher           |
| `PreCompact`        | Before context compaction                              | manual/auto          |
| `PostCompact`       | After context compaction                               | manual/auto          |
| `SessionEnd`        | Session terminates                                     | Exit reason          |

### Hook Types

| Type      | Description                                      |
|-----------|--------------------------------------------------|
| `command` | Run a shell command                              |
| `http`    | POST event data to a URL                         |
| `prompt`  | Single-turn LLM evaluation (Haiku by default)    |
| `agent`   | Multi-turn verification with tool access          |

### Exit Codes

| Code | Meaning                                                |
|------|--------------------------------------------------------|
| 0    | Allow the action. stdout added to context for some events |
| 2    | Block the action. stderr sent as feedback to Claude     |
| Other| Action proceeds. stderr logged but not shown to Claude  |

### Pre-commit Quality Check Hook

Since Claude Code lacks a dedicated PreCommit event, use `PreToolUse` with a matcher:

**.claude/settings.json:**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "if": "Bash(git commit *)",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-commit-check.sh"
          }
        ]
      }
    ]
  }
}
```

**.claude/hooks/pre-commit-check.sh:**
```bash
#!/bin/bash
# Pre-commit quality gate for Claude Code
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command')

# Run linter on staged files
STAGED=$(git diff --cached --name-only --diff-filter=ACM)
if [ -n "$STAGED" ]; then
  # Run lint check
  npx eslint $STAGED 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "Lint errors found. Fix before committing." >&2
    exit 2
  fi

  # Run type check
  npx tsc --noEmit 2>/dev/null
  if [ $? -ne 0 ]; then
    echo "TypeScript errors found. Fix before committing." >&2
    exit 2
  fi
fi

exit 0
```

```bash
chmod +x .claude/hooks/pre-commit-check.sh
```

### Auto-format After Edits

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "jq -r '.tool_input.file_path' | xargs npx prettier --write 2>/dev/null || true"
          }
        ]
      }
    ]
  }
}
```

### Block Edits to Protected Files

**.claude/hooks/protect-files.sh:**
```bash
#!/bin/bash
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

PROTECTED_PATTERNS=(".env" "package-lock.json" ".git/" "secrets")

for pattern in "${PROTECTED_PATTERNS[@]}"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "Blocked: $FILE_PATH matches protected pattern '$pattern'" >&2
    exit 2
  fi
done

exit 0
```

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/protect-files.sh"
          }
        ]
      }
    ]
  }
}
```

### Stop Hook: Verify All Tasks Complete

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Check if all tasks are complete. If not, respond with {\"ok\": false, \"reason\": \"what remains to be done\"}."
          }
        ]
      }
    ]
  }
}
```

### Agent-based Hook: Run Tests Before Stopping

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "agent",
            "prompt": "Verify that all unit tests pass. Run the test suite and check the results. $ARGUMENTS",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
```

### Notification Hook (Desktop Alerts)

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "osascript -e 'display notification \"Claude Code needs your attention\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
  }
}
```

---

## 5. Custom Skills & Slash Commands

### Key Facts (March 2026)

- Slash commands and skills have been **merged** since v2.1.3
- `.claude/commands/*.md` and `.claude/skills/*/SKILL.md` both create `/slash-command` interfaces
- Skills are recommended over commands (support frontmatter, supporting files, etc.)
- ~55 built-in commands + 5 bundled skills + unlimited custom skills

### Bundled Skills

| Skill                  | Purpose                                                       |
|------------------------|---------------------------------------------------------------|
| `/batch <instruction>` | Parallel changes across codebase using worktrees              |
| `/claude-api`          | Load Claude API reference for your language                   |
| `/debug [description]` | Enable debug logging and troubleshoot                         |
| `/loop [interval] <prompt>` | Run prompt repeatedly on interval                        |
| `/simplify [focus]`    | Review changed files for quality, fix issues                  |

### Skill File Locations

| Location    | Path                                        | Applies To              |
|-------------|---------------------------------------------|-------------------------|
| Enterprise  | Managed settings                            | All org users           |
| Personal    | `~/.claude/skills/<name>/SKILL.md`          | All your projects       |
| Project     | `.claude/skills/<name>/SKILL.md`            | This project only       |
| Plugin      | `<plugin>/skills/<name>/SKILL.md`           | Where plugin is enabled |

### SKILL.md Format

```yaml
---
name: my-skill-name
description: Clear description. Claude uses this to decide when to load it.
argument-hint: "[issue-number]"
disable-model-invocation: false
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash
model: opus
effort: high
context: fork
agent: Explore
paths: "src/**/*.ts"
---

# Skill Instructions

Your markdown instructions here. Claude follows these when the skill is invoked.

## Steps
1. First step
2. Second step

## Dynamic Context
- Current branch: !`git branch --show-current`
- Recent commits: !`git log --oneline -5`
```

### Frontmatter Fields Reference

| Field                      | Required?   | Description                                             |
|----------------------------|-------------|---------------------------------------------------------|
| `name`                     | No          | Display name, becomes /slash-command. Lowercase + hyphens. |
| `description`              | Recommended | What skill does and when to use. Claude uses for auto-invocation. |
| `argument-hint`            | No          | Hint shown during autocomplete, e.g. `[issue-number]`  |
| `disable-model-invocation` | No          | `true` = only manual /invoke. Default: `false`          |
| `user-invocable`           | No          | `false` = hidden from / menu. Default: `true`           |
| `allowed-tools`            | No          | Tools Claude can use without asking when skill is active |
| `model`                    | No          | Model to use when skill is active                       |
| `effort`                   | No          | Effort level override. Options: low, medium, high, max  |
| `context`                  | No          | `fork` to run in isolated subagent context              |
| `agent`                    | No          | Subagent type when context: fork (Explore, Plan, etc.)  |
| `hooks`                    | No          | Hooks scoped to this skill's lifecycle                  |
| `paths`                    | No          | Glob patterns limiting when skill auto-activates        |
| `shell`                    | No          | `bash` (default) or `powershell`                        |

### String Substitutions

| Variable              | Description                              |
|-----------------------|------------------------------------------|
| `$ARGUMENTS`          | All arguments passed to skill            |
| `$ARGUMENTS[N]`      | Specific argument by 0-based index       |
| `$N`                  | Shorthand for `$ARGUMENTS[N]`            |
| `${CLAUDE_SESSION_ID}`| Current session ID                       |
| `${CLAUDE_SKILL_DIR}` | Directory containing the SKILL.md file  |

### Example: Fix GitHub Issue Skill

**.claude/skills/fix-issue/SKILL.md:**
```yaml
---
name: fix-issue
description: Fix a GitHub issue by number
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash, Edit, Write
---

Fix GitHub issue #$ARGUMENTS:

1. Run `gh issue view $ARGUMENTS` to get issue details
2. Understand the problem described
3. Search the codebase for relevant files
4. Implement the fix
5. Write and run tests to verify
6. Ensure code passes linting and type checking
7. Create a descriptive conventional commit
8. Push and create a PR with `gh pr create`
```

Usage: `/fix-issue 42`

### Example: Deploy Skill (Manual Only)

**.claude/skills/deploy/SKILL.md:**
```yaml
---
name: deploy
description: Deploy the application to production
disable-model-invocation: true
context: fork
---

Deploy $ARGUMENTS to production:

1. Run the test suite: !`npm test`
2. Build the application: `npm run build`
3. Push to deployment target
4. Verify the deployment succeeded
```

### Example: Code Review Skill

**.claude/skills/review/SKILL.md:**
```yaml
---
name: review
description: Review code changes for quality, security, and conventions
context: fork
agent: Explore
allowed-tools: Read, Grep, Glob, Bash(gh *)
---

## Review Context
- PR diff: !`gh pr diff`
- PR comments: !`gh pr view --comments`
- Changed files: !`gh pr diff --name-only`

## Review Checklist
1. Security vulnerabilities (injection, auth flaws, secrets in code)
2. Error handling and edge cases
3. Performance concerns
4. Code style consistency with project conventions
5. Test coverage for new/changed code
6. Documentation for public APIs

Post findings as review comments.
```

---

## 6. Git Worktrees for Parallel Development

### Overview

Git worktrees create separate working directories sharing the same repository
history. Each Claude Code session gets its own files and branch without interference.

### Built-in Worktree Support

```bash
# Start Claude in a named worktree (creates branch worktree-feature-auth)
claude --worktree feature-auth
# or shorthand:
claude -w feature-auth

# Start another parallel session
claude -w bugfix-123

# Auto-generate a name
claude --worktree
```

Worktrees are created at `<repo>/.claude/worktrees/<name>` and branch from `origin/HEAD`.

### Add to .gitignore

```
.claude/worktrees/
```

### Copy Gitignored Files (.worktreeinclude)

Git worktrees do not include untracked files like `.env`. Create `.worktreeinclude` in project root:

```
.env
.env.local
config/secrets.json
```

Only files matching a pattern AND gitignored get copied.

### Subagent Worktrees

Configure isolated parallel subagents:

**.claude/agents/feature-worker.md:**
```yaml
---
name: feature-worker
description: Implements features in isolated worktree
isolation: worktree
tools: Read, Grep, Glob, Bash, Edit, Write
model: sonnet
---

You implement features in an isolated worktree.
Follow project conventions from CLAUDE.md.
Run tests before reporting completion.
```

Or ask Claude directly:
```
Use worktrees for your agents to implement these three features in parallel
```

### Worktree Cleanup

- **No changes**: worktree and branch removed automatically on exit
- **Changes exist**: Claude prompts to keep or remove

### Manual Worktree Management

```bash
# Create with specific branch
git worktree add ../project-feature-a -b feature-a

# Create from existing branch
git worktree add ../project-bugfix bugfix-123

# Start Claude in it
cd ../project-feature-a && claude

# List all worktrees
git worktree list

# Clean up
git worktree remove ../project-feature-a
```

### Re-sync origin/HEAD

If your remote default branch changed:
```bash
git remote set-head origin -a
```

### Practical Limits

Most developers find **3-5 parallel worktrees** is the practical upper bound,
limited by machine memory and CPU.

---

## 7. Autonomous Loops

### /loop Skill (In-Session)

Run a prompt repeatedly on an interval while the session stays open:

```
/loop 5m check if the deploy finished
/loop 10m run tests and fix any failures
/loop 30m check for new issues labeled "urgent" and triage them
```

Default interval is 10 minutes. Tasks cancel when you exit the session.

### Headless Mode for Scripts & CI

```bash
# One-off non-interactive execution
claude -p "fix all lint errors in src/" --output-format text

# With auto mode (classifier handles permissions)
claude --permission-mode auto -p "fix all lint errors"

# Streaming JSON for real-time processing
claude -p "analyze this codebase" --output-format stream-json

# DANGEROUS: fully unattended (only in disposable containers)
claude -p "run tests and fix failures" --dangerously-skip-permissions
```

### Fan-out Pattern (Parallel Batch Processing)

```bash
# Generate task list
claude -p "list all Python files needing migration" > files.txt

# Process in parallel
for file in $(cat files.txt); do
  claude -p "Migrate $file from React to Vue. Return OK or FAIL." \
    --allowedTools "Edit,Bash(git commit *)" &
done
wait
```

### Scheduled Tasks

| Method                   | Where it Runs              | Best For                              |
|--------------------------|----------------------------|---------------------------------------|
| Cloud scheduled tasks    | Anthropic infrastructure   | Tasks when computer is off            |
| Desktop scheduled tasks  | Your machine (desktop app) | Access to local files                 |
| GitHub Actions cron      | CI pipeline                | Repo-tied tasks                       |
| `/loop`                  | Current CLI session        | Quick polling while session is open   |

### Stop Hook to Prevent Premature Completion

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Check if all requested tasks are complete. If not, respond with {\"ok\": false, \"reason\": \"description of remaining work\"}."
          }
        ]
      }
    ]
  }
}
```

**Prevent infinite loops** -- check `stop_hook_active`:
```bash
#!/bin/bash
INPUT=$(cat)
if [ "$(echo "$INPUT" | jq -r '.stop_hook_active')" = "true" ]; then
  exit 0  # Allow Claude to stop
fi
# ... rest of hook logic
```

### Resume Sessions

```bash
claude --continue          # Resume most recent conversation
claude --resume            # Pick from recent sessions
claude --resume auth-work  # Resume by name
claude --from-pr 123       # Resume session linked to PR
```

---

## 8. GitHub Actions CI Integration

### Quick Setup

```
/install-github-app
```

This guides you through installing the Claude GitHub app and setting secrets.

### Basic Workflow

**.github/workflows/claude.yml:**
```yaml
name: Claude Code
on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]

jobs:
  claude:
    runs-on: ubuntu-latest
    steps:
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          # Responds to @claude mentions in comments
```

### PR Review Workflow

```yaml
name: Code Review
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  review:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: >
            Review this pull request for code quality, correctness,
            and security. Analyze the diff, then post findings as
            review comments.
          claude_args: "--max-turns 5 --model claude-opus-4-6"
```

### Scheduled Daily Report

```yaml
name: Daily Report
on:
  schedule:
    - cron: "0 9 * * *"

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: anthropics/claude-code-action@v1
        with:
          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
          prompt: "Generate a summary of yesterday's commits and open issues"
          claude_args: "--model opus"
```

### Action Parameters (v1)

| Parameter           | Description                                          | Required |
|---------------------|------------------------------------------------------|----------|
| `prompt`            | Instructions for Claude (plain text or skill name)   | No*      |
| `claude_args`       | CLI arguments passed to Claude Code                  | No       |
| `anthropic_api_key` | Claude API key                                       | Yes**    |
| `github_token`      | GitHub token for API access                          | No       |
| `trigger_phrase`    | Custom trigger phrase (default: "@claude")            | No       |
| `use_bedrock`       | Use AWS Bedrock                                      | No       |
| `use_vertex`        | Use Google Vertex AI                                 | No       |

*Optional for comments (auto-responds to trigger phrase)
**Required for direct API, not for Bedrock/Vertex

### Common claude_args

```yaml
claude_args: >
  --max-turns 10
  --model claude-opus-4-6
  --append-system-prompt "Follow our coding standards"
  --allowedTools "Read,Grep,Glob,Edit,Write,Bash"
```

---

## 9. Semantic Versioning & Auto-Bump

### Conventional Commits Format

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

| Prefix              | Version Bump | Example                              |
|---------------------|-------------|---------------------------------------|
| `fix:`              | PATCH       | `fix: handle null user in login`      |
| `feat:`             | MINOR       | `feat: add OAuth2 support`            |
| `BREAKING CHANGE:`  | MAJOR       | `feat!: redesign auth API`            |
| `chore:`            | None        | `chore: update dependencies`          |
| `docs:`             | None        | `docs: add API documentation`         |
| `test:`             | None        | `test: add auth edge case tests`      |

### CLAUDE.md Convention Enforcement

Add to your CLAUDE.md:
```markdown
## Git Conventions

- IMPORTANT: Use conventional commit messages: feat:, fix:, chore:, docs:, test:, refactor:
- Include scope when relevant: feat(auth): add OAuth2 support
- Use BREAKING CHANGE in footer for breaking changes
```

### Release-Please (Google) Setup

**.github/workflows/release.yml:**
```yaml
name: Release
on:
  push:
    branches:
      - main

permissions:
  contents: write
  pull-requests: write

jobs:
  release-please:
    runs-on: ubuntu-latest
    steps:
      - uses: googleapis/release-please-action@v4
        with:
          release-type: node
          # or: python, go, rust, etc.
```

**release-please-config.json:**
```json
{
  "packages": {
    ".": {
      "release-type": "node",
      "bump-minor-pre-major": true,
      "bump-patch-for-minor-pre-major": true,
      "changelog-sections": [
        { "type": "feat", "section": "Features" },
        { "type": "fix", "section": "Bug Fixes" },
        { "type": "chore", "section": "Miscellaneous" },
        { "type": "docs", "section": "Documentation" },
        { "type": "test", "section": "Tests" }
      ]
    }
  }
}
```

### Semantic-Release Setup

```bash
npm install --save-dev semantic-release @semantic-release/changelog @semantic-release/git
```

**.releaserc.json:**
```json
{
  "branches": ["main"],
  "plugins": [
    "@semantic-release/commit-analyzer",
    "@semantic-release/release-notes-generator",
    "@semantic-release/changelog",
    ["@semantic-release/npm", { "npmPublish": false }],
    "@semantic-release/git",
    "@semantic-release/github"
  ]
}
```

### Claude Code Conventional Commits Skill

**.claude/skills/conventional-commits/SKILL.md:**
```yaml
---
name: commit
description: Create a conventional commit with proper formatting
disable-model-invocation: true
allowed-tools: Bash(git *)
---

Create a conventional commit for the current changes:

1. Run `git diff --cached --stat` to see staged changes
2. Run `git diff --cached` to understand what changed
3. Determine the commit type:
   - feat: new feature
   - fix: bug fix
   - chore: maintenance
   - docs: documentation
   - test: tests
   - refactor: code restructure
4. Write a concise commit message following conventional commits format
5. Run `git commit -m "<type>(<scope>): <description>"`
6. If there are breaking changes, include `BREAKING CHANGE:` in the footer
```

---

## 10. Vibe Coding Workflow

### The Four-Phase Pattern

1. **Explore** (Plan Mode): Read files, understand the codebase
2. **Plan** (Plan Mode): Create detailed implementation plan
3. **Implement** (Normal Mode): Let Claude code, with verification
4. **Commit** (Normal Mode): Commit with descriptive message, create PR

```bash
# Start in plan mode
claude --permission-mode plan

# In the session:
# Phase 1: "read src/auth/ and understand how sessions work"
# Phase 2: "create a plan to add OAuth2 support"
# Press Ctrl+G to edit plan in your editor
# Shift+Tab to switch to Normal Mode
# Phase 3: "implement the OAuth flow from your plan. run tests."
# Phase 4: "commit with conventional message and open a PR"
```

### Agentic Engineering vs. Vibe Coding

| Aspect           | Vibe Coding              | Agentic Engineering         |
|------------------|--------------------------|-----------------------------|
| Planning         | Minimal                  | Structured (Plan Mode)      |
| Review           | Trust output             | Human-in-the-loop           |
| Testing          | Optional                 | Required verification       |
| Use Case         | Prototypes, internal tools| Production code             |
| Risk             | Technical debt            | Slower but reliable         |

**Best practice**: Use vibe coding for exploration and prototypes.
Switch to agentic engineering (plan, verify, review) for production code.

### Writer/Reviewer Pattern (Parallel Sessions)

| Session A (Writer)                                   | Session B (Reviewer)                                     |
|------------------------------------------------------|----------------------------------------------------------|
| `Implement rate limiter for API endpoints`           |                                                          |
|                                                      | `Review rate limiter in @src/middleware/rateLimiter.ts`   |
| `Address review feedback: [paste Session B output]`  |                                                          |

### Key Prompting Strategies

1. **Tell Claude WHAT, not HOW**: "Add user authentication" not "Create a file called auth.js and write a function..."
2. **Provide verification criteria**: "Write tests. Run them. Fix failures."
3. **Reference existing patterns**: "Follow the pattern in @src/widgets/HotDogWidget.php"
4. **Scope investigations**: "Use a subagent to investigate how auth works" (keeps main context clean)
5. **Let Claude interview you**: "Interview me about this feature using AskUserQuestion"

### Context Management

- `/clear` between unrelated tasks
- `/compact <instructions>` for targeted compaction
- `/btw` for side questions that do not enter conversation history
- After 2 failed corrections, `/clear` and rewrite with a better prompt
- Use subagents for research to keep main context clean

### Common Anti-Patterns to Avoid

| Anti-Pattern                | Fix                                              |
|-----------------------------|--------------------------------------------------|
| Kitchen sink session        | `/clear` between unrelated tasks                 |
| Correcting over and over    | After 2 failures, `/clear` + better prompt       |
| Over-specified CLAUDE.md    | Prune ruthlessly, convert to hooks               |
| Trust-then-verify gap       | Always provide tests/scripts/screenshots         |
| Infinite exploration        | Scope narrowly or use subagents                  |

---

## Quick Reference: New Features as of March 2026

| Feature                        | Description                                          |
|--------------------------------|------------------------------------------------------|
| Opus 4.6 (1M context)         | Default for Max/Team/Enterprise plans                |
| Adaptive reasoning             | Dynamic thinking allocation based on effort level    |
| `max` effort level             | Opus 4.6 only, deepest reasoning                     |
| Auto mode                      | Classifier-based permission handling                 |
| Built-in worktree support      | `claude --worktree` / `claude -w`                    |
| 21 hook lifecycle events       | Including agent/prompt/http hook types               |
| Skills/commands merged         | Unified SKILL.md format                              |
| `/loop` skill                  | Recurring task execution                             |
| `/batch` skill                 | Parallel changes using worktrees                     |
| Agent teams                    | Coordinated parallel sessions with messaging         |
| Subagent worktree isolation    | `isolation: worktree` in agent frontmatter           |
| `if` field on hooks            | Filter by tool name AND arguments                    |
| Prompt/agent hook types        | LLM-powered decision hooks                           |
| HTTP hooks                     | POST event data to external endpoints                |
| `.worktreeinclude`             | Copy gitignored files to worktrees                   |
| Cloud scheduled tasks          | Run on Anthropic infrastructure                      |
| Plugin marketplace             | `/plugin` to browse and install                      |
| `opusplan` model alias         | Opus for planning, Sonnet for execution              |

---

## Sources

- [Best Practices for Claude Code](https://code.claude.com/docs/en/best-practices)
- [Claude Code Settings](https://code.claude.com/docs/en/settings)
- [Automate Workflows with Hooks](https://code.claude.com/docs/en/hooks-guide)
- [Extend Claude with Skills](https://code.claude.com/docs/en/skills)
- [Model Configuration](https://code.claude.com/docs/en/model-config)
- [Common Workflows](https://code.claude.com/docs/en/common-workflows)
- [Claude Code GitHub Actions](https://code.claude.com/docs/en/github-actions)
- [Permission Modes](https://code.claude.com/docs/en/permission-modes)
- [Claude Code CLI Cheatsheet (Shipyard)](https://shipyard.build/blog/claude-code-cheat-sheet/)
- [CLAUDE.md Best Practices (UX Planet)](https://uxplanet.org/claude-md-best-practices-1ef4f861ce7c)
- [Claude Code Hooks Tutorial (Blake Crosley)](https://blakecrosley.com/blog/claude-code-hooks-tutorial)
- [Git Worktrees with Claude Code (incident.io)](https://incident.io/blog/shipping-faster-with-claude-code-and-git-worktrees)
- [Claude Code /loop Guide (Joe Njenga)](https://medium.com/@joe.njenga/claude-code-loop-create-new-native-autonomous-loops-that-work-29934d615402)
- [anthropics/claude-code-action (GitHub)](https://github.com/anthropics/claude-code-action)
- [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
- [Semantic Versioning Automation (OneUptime)](https://oneuptime.com/blog/post/2026-01-25-semantic-versioning-automation/view)
- [Vibe Coding: Complete Guide (sviluppatoremigliore)](https://sviluppatoremigliore.com/en/blog/vibe-coding-complete-guide-for-professional-developers)
- [From Vibe Coding to Agentic Engineering (Sau Sheong)](https://sausheong.com/from-vibe-coding-to-agentic-engineering-1ca3ca72b5ac)
