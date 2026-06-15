# Claude Code Instructions — ai-ralph

## Repository

This is a fork of [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code).
The user's own fork is **`amit-t/ai-ralph`**.

## Pull Requests

**Never target the upstream `frankbria/ralph-claude-code`.** Always pass `--repo` explicitly — without it, `gh pr create` defaults to the upstream fork.

The repo has a single remote:

| Remote | URL | gh account | Repo slug |
|---|---|---|---|
| `origin` | `github.com-at:amit-t/ai-ralph` | `amit-t` | `amit-t/ai-ralph` |

`origin` has `main` and `dev` branches.

When the user asks for "PRs to main and dev", open **2 PRs** against `origin`: `origin/main`, `origin/dev`. Push the branch to `origin` first, then create the PRs on the `amit-t` account:

```bash
# Push to origin
git push origin <branch>

# amit-t PRs
gh auth switch --user amit-t
gh pr create --repo amit-t/ai-ralph --base main --head <branch> ...
gh pr create --repo amit-t/ai-ralph --base dev  --head <branch> ...
```

If the user asks for a single PR with no remote specified, default to `amit-t/ai-ralph` on the `amit-t` account.

## Branch Safety

**Never delete `dev` or `main` branches — locally or on any remote.** These are long-lived shared branches. All branch cleanup commands (`git branch -d`, `git branch -D`, `git push --delete`) must exclude `dev` and `main`. This applies even when the user asks for broad cleanup.

## Worktrees

Long docs/refactor tasks are often delegated to a subagent with `isolation: worktree`. The worktree lives at `.claude/worktrees/agent-<id>/` and is a sibling checkout sharing the same `.git/`.

- Access the worktree with `git -C <absolute-path>` — `cd` into a path starting with `.claude/` can fail depending on shell state; absolute paths always work.
- The branch created inside the worktree is visible from the main checkout once pushed. Push and open PRs from the main checkout using `git -C <worktree-path> push <remote> <branch>`, not by `cd`-ing in.
- Don't delete the worktree until the user has reviewed; `git worktree list` shows active ones, and they appear as `locked` while the agent session is live.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current
