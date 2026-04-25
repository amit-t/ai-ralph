# Claude Code Instructions — ai-ralph

## Repository

This is a fork of [frankbria/ralph-claude-code](https://github.com/frankbria/ralph-claude-code).
The user's own fork is **`amit-t/ai-ralph`**.

## Pull Requests

**Always create PRs against `amit-t/ai-ralph`, never the upstream `frankbria/ralph-claude-code`.**

Use `--repo amit-t/ai-ralph` explicitly — without it, `gh pr create` defaults to the upstream fork:

```bash
gh pr create --repo amit-t/ai-ralph --base main --head <branch>
```

## GitHub Account

The correct `gh` account for this repo is `amit-t`. If `gh auth status` shows `amit-tiwari_vnt` as active (enterprise managed user), switch first:

```bash
gh auth switch --user amit-t
```

## Branch Safety

**Never delete `dev` or `main` branches — locally or on any remote.** These are long-lived shared branches. All branch cleanup commands (`git branch -d`, `git branch -D`, `git push --delete`) must exclude `dev` and `main`. This applies even when the user asks for broad cleanup.

## graphify

This project has a graphify knowledge graph at graphify-out/.

Rules:
- Before answering architecture or codebase questions, read graphify-out/GRAPH_REPORT.md for god nodes and community structure
- If graphify-out/wiki/index.md exists, navigate it instead of reading raw files
- After modifying code files in this session, run `python3 -c "from graphify.watch import _rebuild_code; from pathlib import Path; _rebuild_code(Path('.'))"` to keep the graph current
