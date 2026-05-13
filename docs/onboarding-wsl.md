# Running ai-ralph on WSL2

ai-ralph is supported on WSL2 Ubuntu (bash 5.x). The shell scripts assume a
GNU coreutils environment (e.g. `timeout`, `date -d`), which WSL2 provides by
default. macOS support continues to use the Homebrew coreutils prefix
(`gtimeout`, `gdate`) and is gated by `uname` at runtime.

## Prereqs

Install the base toolchain:

```bash
sudo apt update
sudo apt install -y jq gh git
```

Node.js is also required for the `claude` engine. Use the official Node 18+
build (nvm, NodeSource, or the Ubuntu Snap, your choice).

## Filesystem location (important)

Clone target repos under `$HOME`, not under `/mnt/c/` (or any other DrvFs
mount). DrvFs paths are roughly 10x slower for the small-file IO that ralph
performs, and `fsync` semantics differ enough to surprise scripts that assume
durable writes are cheap.

If you must work on a Windows-hosted checkout, expect long planning runs and
keep an eye on the logs under `.ralph/logs/`.

## Quick start

```bash
git clone https://github.com/amit-t/ai-ralph ~/ralph
bash ~/ralph/install.sh

cd /path/to/your/repo
ralph-enable        # interactive wizard
# or
ralph-enable-ci     # non-interactive variant for automation

ralph --monitor
```

## Common issues

- `command not found: gtimeout`: false positive. The code branches on `uname`
  and picks plain `timeout` on Linux. If you still see this message, the
  shell hit a stale cached install, run `ralph.upgrade` or reinstall.
- `CRLF detected` (or unexpected diff churn on shell scripts): the repo
  enforces LF via `.gitattributes`. If you cloned before that file landed,
  run `git add --renormalize . && git commit -m 'chore: renormalize line endings'`.
- `claude: command not found`: install Anthropic's Claude Code CLI (e.g.
  `npm install -g @anthropic-ai/claude-code`) or set
  `CLAUDE_CODE_CMD="npx @anthropic-ai/claude-code"` in `.ralphrc`.

## Smoke test

A local mirror of the CI smoke workflow lives at
[`tests/integration/smoke-ralph.bash`](../tests/integration/smoke-ralph.bash).
It builds a tiny fixture repo in a temp sandbox, runs the installer, calls
`ralph_enable_ci.sh` against the fixture, and asserts `.ralph/fix_plan.md`
exists at the end. Run it from the repo root:

```bash
bash tests/integration/smoke-ralph.bash
```

It cleans up its temp directory on exit (trap-cleanup) and isolates `HOME`
so a developer machine's real `~/.ralph` is untouched.

## Verification

Run `bats tests/unit/lib_date_utils.bats tests/unit/lib_timeout_utils.bats` to
confirm date/timeout fallbacks pin correctly on your machine.
