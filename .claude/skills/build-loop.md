---
name: build-loop
description: Autonomous build loop — work through all issues, PRs, and tasks non-stop until TagBag is fully built, tested, and running
user_invocable: true
---

You are in autonomous build mode. Your goal is to make TagBag a fully working, production-quality self-hosted GitHub replacement. Work continuously through every task until the full vision is complete.

## How to work

1. **Check the current state.** Read CLAUDE.md, check `git status`, check `docker compose ps`, read open GitHub issues with `gh issue list`.

2. **Pick the highest-priority unfinished work.** If there are open GitHub issues, work on the highest priority one. If not, identify what's missing or broken and create an issue for it, then work on it.

3. **For each unit of work:**
   - Create a git branch: `git checkout -b <descriptive-branch-name>`
   - Do the work (code, config, docs)
   - Run the pre-commit checks: `git hook run pre-commit`
   - Commit with a clear message
   - Push the branch: `git push -u origin <branch-name>`
   - Create a PR: `gh pr create --title "..." --body "..."`
   - Merge the PR: `gh pr merge --squash --delete-branch`
   - Pull main: `git checkout main && git pull`
   - Bump version and tag: `./scripts/bump-version.sh && git push && git push --tags`

4. **After completing a unit of work**, update CLAUDE.md and README.md if relevant. Update memory if you learned something non-obvious.

5. **Keep going.** Do not stop after one task. Check for more issues, identify more work, and continue. The loop only ends when everything in the vision is built, tested, and running.

## The full vision

- [ ] All 16 Docker services build from source and start successfully
- [ ] Gitea is accessible at localhost:3000 with an admin account
- [ ] Plane is accessible at localhost:8080 with a workspace
- [ ] Woodpecker is accessible at localhost:9080 connected to Gitea
- [ ] Gitea OAuth2 SSO works for both Plane and Woodpecker
- [ ] The `tagbag` CLI works: login, whoami, status, and all service commands
- [ ] Pre-commit hooks pass
- [ ] CI passes on GitHub Actions
- [ ] README.md is comprehensive and accurate
- [ ] All docs are up to date
- [ ] Version is tagged and pushed

## Rules

- Always use Claude Opus 4.6 (configured in .claude/settings.json)
- Never skip the pre-commit hook
- Every change goes through a branch + PR (no direct commits to main)
- Bump minor version after each merged PR
- Keep README.md and CLAUDE.md current
- Create GitHub issues for discovered problems
- Use `gh` CLI for all GitHub operations
