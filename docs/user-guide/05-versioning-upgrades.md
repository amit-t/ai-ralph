# Versioning and Upgrades

Ralph reads its version from a single `version.json` at the repo root and uses that file to decide when to nag you about updates and what to install when you upgrade. The same library powers other workbench tools, so the behavior described here is consistent across the suite.

## ralph.upgrade

Run `ralph.upgrade` to pull the latest stable Ralph and reinstall it.

The command:

1. Verifies your Ralph clone is on `main` and has no uncommitted changes. It refuses to run otherwise (exit code 2). Pass `--force` only if you understand what you are bypassing.
2. Records the prior commit so you can roll back in one step.
3. Runs `git pull --ff-only` against `origin`.
4. Re-runs `install.sh` so any new commands, library files, and shell wrappers land in `~/.local/bin` and `~/.local/share/wb-versioncheck/`. Pass `--skip-install` to skip this step if you only want the source updated.
5. Refuses to upgrade if the new version requires peers (for example, a specific ai-devkit version) you do not have installed (exit code 3). Pass `--force` to bypass at your own risk.

To roll back to the version you were on before the last upgrade:

```bash
ralph.upgrade --rollback
```

This resets your clone to the recorded prior commit and reinstalls. The rollback record is single-step, so it only undoes the most recent upgrade.

Pass `--yes` to skip the confirmation prompt in scripts.

## Update notifications

When you start `ralph` (or any wrapper that sources the version-check library), Ralph compares your local `version.json` against the upstream version on `main`. If a newer version is available, it prints a one-line banner to stderr and continues. The banner does not block your loop and is never written to stdout, so it does not pollute pipes or log captures.

Two design choices keep this fast and quiet:

- Results are cached for 12 hours under `~/.cache/wb-versioncheck/`. A fresh check happens at most once per TTL window per tool. Delete the cache file to force a refresh.
- The check uses `gh api` first (which is fast and authenticated) and falls back to a shallow `git ls-remote`/clone if `gh` is missing. If both fail (offline, rate limited, network down), the check fails open: no banner, no error, your loop continues.

Override the upstream you check against by exporting `WB_UPSTREAM_OWNER` (defaults to `amit-t`) or `WB_UPSTREAM_REPO`. Override the local Ralph clone path with `RALPH_CLONE` if you installed somewhere other than the default.

## Requires and `--force`

A `version.json` may declare peer requirements under `requires`, for example `{"ai-devkit": ">=1.2.0"}`. Before upgrading, `ralph.upgrade` reads the new `version.json` and resolves each peer against your installed version. If any peer constraint fails, the upgrade is blocked with exit code 3 and a message naming the offending peer.

`--force` bypasses both the peer-requires check and the dirty-tree refusal. Use it when you know the peer state is acceptable (for example, you are about to upgrade the peer next) or when you have local changes you intend to keep through the upgrade.

`--force` does not bypass the rollback record. The prior commit is still saved before the pull, so `ralph.upgrade --rollback` still works after a forced upgrade.

## Where things live after install

| Path | Purpose |
|------|---------|
| `~/.local/bin/ralph.upgrade` | Wrapper that runs `ralph-upgrade.sh` from your clone |
| `~/.local/share/wb-versioncheck/version-check.sh` | Shared library sourced by `ralph` and other tools |
| `~/.cache/wb-versioncheck/ralph.json` | Cached upstream check result, refreshed every 12h |
| `${RALPH_CLONE}/version.json` | Canonical version record for your clone |
