# Task: Triage and resolve 5 pre-existing red bats tests on ai-ralph

Run inside `ai-ralph/` (this repo). You have the full codebase. No external context required.

## Background

`bats tests/unit/` returns **961 ok / 5 not-ok** on `origin/main`. The 5 failures pre-date recent feature work (workspace `--repos` / `--exclude` filter and `--parallel-plan N` both landed clean — refer to `tests/unit/test_workspace_repo_filter.bats` and `tests/unit/test_parallel_plan.bats` for the green baseline). The 5 failing tests have been red on `main` for at least the duration of the last several merges; admin-merge has been used to bypass them. We want them green so future PRs do not need `--admin`.

The failing test IDs and names:

| # | Name |
|---|------|
| 103 | `API limit prompt defaults to wait in unattended mode` |
| 118 | `validate_claude_command is called before loop in ralph_loop.sh` |
| 343 | `startup resets stale exit signals before main loop` |
| 346 | `API limit user-exit path calls reset_session` |
| 405 | `ralph_loop.sh has startup integrity check before main loop` |

The exact suite + test file each lives in is whatever `bats tests/unit/ 2>&1 | grep -B1 'not ok '` reports. Find the test files first; do not assume.

## What to do

For each failing test, classify it as one of:

1. **Real bug** — the production code does not do what the test asserts. Fix the production code. Do not weaken the assertion.
2. **Stale test** — the test grep / source assertion targets code that has been refactored (renamed, relocated, restructured) but still exists with equivalent behavior. Update the test to match current reality.
3. **Flaky / timing** — test is non-deterministic. Stabilize the test (mock the clock, replace sleeps with explicit waits, etc.). Do not add retries.
4. **Won't-fix** — test asserts a behavior that is no longer expected, and removing the test is justifiable. Document the reason in the commit message; remove the test.

Tests 118 and 405 are source-code grep style — likely stale after refactors. Tests 103, 343, 346 are behavioral (rate-limit prompts, exit signals, session reset paths) and may be real bugs in error / exit paths.

## Method

Loop per failing test:

1. Read the test source. Note the file path, the line number, the exact assertion that fails.
2. Run the test in isolation: `bats tests/unit/<file>.bats --filter 'test name fragment'`.
3. Read the production code the test targets. Locate the relevant function or grep target.
4. Decide which classification (1–4) applies. Capture the rationale in your commit message.
5. Apply the fix (production-code change for class 1; test update for class 2; stabilization for class 3; deletion for class 4).
6. Re-run the single test green.
7. Run the whole unit suite (`bats tests/unit/`) and verify the count is `(961 + N) ok / (5 - N) not-ok` where N is the number of tests fixed so far. Zero new regressions.
8. Move to the next failing test.

After all 5 are green:

- Run the integration suite: `bats tests/integration/`. If any new regression appears, root-cause it before claiming done. Likely none, since changes are scoped to specific tests.
- Run `bash -n` on every shell file you touched.
- Update `CHANGELOG.md` if there is one (check `git log --oneline -- CHANGELOG.md | head`).

## Branching and PRs

- Create branch `fix/red-test-triage` from `origin/main`.
- One commit per test fix is preferred (5 commits total). Use Conventional Commits format:
  - `fix(test): unstale test 118 — validate_claude_command grep target moved to lib/cli_modern.sh` (example).
  - `fix(rate-limit): default to wait in unattended mode (test 103)` (example for production-code class 1).
- Push to both remotes: `origin` (amit-t) and `inv` (Invenco-Cloud-Systems-ICS).
- Open 4 PRs, all with the same title `fix: green up 5 pre-existing red bats tests`:
  - `amit-t/ai-ralph` base `main`
  - `amit-t/ai-ralph` base `dev`
  - `Invenco-Cloud-Systems-ICS/ai-ralph` base `main`
  - `Invenco-Cloud-Systems-ICS/ai-ralph` base `dev`
- For amit-t PRs use `gh auth switch -u amit-t` first. For Invenco PRs use `gh auth switch -u amit-tiwari_vnt`.
- If `dev` has diverged from `main`, merge `origin/dev` into the feature branch before opening the dev-targeted PR. Same for `inv/main` and `inv/dev`. (See recent PR history: `git log --merges --oneline -- main dev` for the established pattern.)
- Do **not** admin-merge. The whole point is to get the suite green so admin-merge stops being needed. Wait for CI to confirm green, then ask for human review or merge normally.

## PR body template

```
## Summary

Triage and fix 5 pre-existing red bats tests on `tests/unit/`. Suite goes from 961 ok / 5 not-ok to 966 ok / 0 not-ok.

## Test-by-test

| # | Test | Classification | Fix |
|---|------|---------------|-----|
| 103 | API limit prompt defaults to wait in unattended mode | <class> | <one-line summary> |
| 118 | validate_claude_command is called before loop in ralph_loop.sh | <class> | <one-line summary> |
| 343 | startup resets stale exit signals before main loop | <class> | <one-line summary> |
| 346 | API limit user-exit path calls reset_session | <class> | <one-line summary> |
| 405 | ralph_loop.sh has startup integrity check before main loop | <class> | <one-line summary> |

## Test plan

- [x] `bats tests/unit/` — 966/966
- [x] `bats tests/integration/` — no new regressions
- [x] `bash -n` on every modified shell file
```

## Constraints

- **Do not** weaken existing assertions to make a failing test green. If a test is hard to satisfy, re-read the production code; the failure usually points at a real gap.
- **Do not** add retry loops or `sleep` to make timing flakiness disappear. Mock the time source.
- **Do not** delete a test without a written rationale in the commit message and PR body.
- **Do not** introduce backwards-compatibility shims, feature flags, or unrelated refactors. Scope is strictly the 5 tests.
- **Do not** touch `tests/unit/test_workspace_repo_filter.bats` or `tests/unit/test_parallel_plan.bats` — those are recent and green.
- **Do not** modify `CHANGELOG.md` cosmetically beyond noting the test fixes.
- If you discover a 6th red test introduced by your changes, root-cause it before continuing. Do not let it ride.

## Done means

- `bats tests/unit/` returns 966/966.
- `bats tests/integration/` clean.
- 4 PRs open (or merged, if CI is green and you have authority).
- Per-PR body explains the classification and fix for each of the 5 tests.

## Helpful starting commands

```bash
# Find each failing test's home file
bats tests/unit/ 2>&1 | grep -B1 'not ok '

# Run one suite verbosely
bats tests/unit/test_<name>.bats --verbose-run

# Single test by name fragment
bats tests/unit/test_<name>.bats --filter 'API limit prompt'

# After a fix, full unit suite
bats tests/unit/ 2>&1 | tail -5
bats tests/unit/ 2>&1 | grep -cE '^ok '
bats tests/unit/ 2>&1 | grep -cE '^not ok '
```

## Out of scope

- New tests (only fix the 5).
- Production-code refactors beyond the minimal change to satisfy class-1 fixes.
- Doc rewrites in `README.md` / `docs/` unless directly tied to a fix.
- Changes to `lib/workspace_manager.sh` or `lib/workspace_plan.sh` (recent surface, untouched by these tests).

Begin.
