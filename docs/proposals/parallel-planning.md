# Upstream ralph V2: parallel planning in `ralph-plan --workspace`

Status: draft (design only, not implementation).
Audience: ai-ralph maintainers. This doc lives in workbench because the workbench team is the primary requester; once accepted, the implementation PR moves to `ai-ralph`.
Author: ai-workbench team.
Date: 2026-04-26.

## 1. Problem statement

`ralph-plan --workspace` (shipped via `feat/workspace-plan-mode`) plans every registered repo in a single invocation and emits one merged `repos/.ralph/fix_plan.md`. The current implementation walks the repo list sequentially: it asks the configured engine (devin / claude / codex) to plan repo A, waits for the response, writes A's section, then plans repo B, and so on.

For a workspace with N repos, total wall-clock time for planning is approximately:

```
T_plan_total ≈ Σ T_engine(repo_i) + N × T_overhead
```

Where `T_engine(repo_i)` is the engine round-trip for repo i (typically tens of seconds with `--thinking ultra`) and `T_overhead` covers prompt assembly, file IO, and any per-repo setup.

Observed cost in early workbench instances:
- 2 repos: tolerable (≈45–90 s total).
- 4 repos: noticeable wait (≈2–3 min).
- 6+ repos: planning becomes the long pole of the morning kickoff.

Engines are network-bound and stateless across repos here. The repos do not share planning context (each has its own `ai/` inputs, its own `target_repos`-filtered artifacts). So sequential execution is leaving wall-clock time on the table for no correctness reason.

This doc proposes adding a `--parallel-plan N` flag (alias `--workers N`) to `ralph-plan --workspace` so the per-repo plan calls run concurrently up to N at a time.

## 2. Why sequential is the V1 default

Three reasons sequential won V1:

1. **Output ordering.** A single writer emitting sections in REPO list order produces a deterministic merged `fix_plan.md`. Easy to diff across runs; easy for humans to scan.
2. **Engine rate limits.** Devin and Claude both throttle. Bursting four concurrent calls into a single API key may trip 429s. Sequential is the safe default.
3. **No file-locking design needed.** A single writer cannot corrupt its own merged output. Concurrency forces us to design a locking or buffering scheme. V1 punted on that.

V2 needs to keep (1) deterministic output ordering and (2) rate-limit safety while paying down (3).

## 3. Proposed flag

Add to `ralph-plan` (workspace mode only):

```
--parallel-plan N      # number of concurrent per-repo plan workers
```

Single flag. No alias. (An earlier draft proposed `--workers` as an alias; dropped after self-review — a second name added confusion without a clear benefit, since `ralph --workspace --parallel N` already uses `--parallel` for executor concurrency and we want the planner-side knob distinguishable.)

Semantic:

- N = 1 ⇒ current sequential behavior. Identical output.
- N > 1 ⇒ up to N per-repo plan calls run concurrently. Output is collected into per-repo buffers, then written into the merged `fix_plan.md` in REPO list order (stable).
- N <= 0 ⇒ error: `--parallel-plan must be >= 1`. Negative values rejected.
- Non-integer ⇒ error: `--parallel-plan must be a positive integer`.
- N > len(REPOS) ⇒ silently capped at `len(REPOS)`, no warning required.

In per-repo mode (`ralph-plan` without `--workspace`) the flag is rejected with a clear error: parallelism is a workspace-mode concept.

## 4. Interaction with engine selection

`--engine claude | devin | codex` already governs which model planner is used. `--parallel-plan` is engine-orthogonal in spirit but engine-aware in defaults:

| Engine | Suggested parallel-plan default | Notes |
|--------|---------------------------------|-------|
| claude | 4                               | Anthropic API allows generous concurrency on org keys; tier-1 keys handle 4 streams comfortably. |
| devin  | 2                               | Devin sessions are more expensive to launch concurrently and per-key concurrency is lower. Conservative. |
| codex  | 2                               | OpenAI org keys throttle on RPM; 2 is the safe-default. |

If `--parallel-plan` is not passed and the engine is one of the above, ralph picks the table value. If the engine is unknown, default to 1 (sequential, current behavior).

The user can always override with the explicit flag.

When ralph hits a 429 / rate-limit error from any engine, it backs off and retries with exponential delay on that worker only. Other workers continue. If a worker fails three retries it is dropped and the merged output records `<no plan generated; see ralph-plan log>` in that repo's section, with the run still exiting non-zero.

## 5. File-locking semantics on `repos/.ralph/fix_plan.md`

Concurrent writers must not corrupt the merged plan. The chosen design is **buffer-then-merge**, not in-place concurrent writes:

1. Each invocation gets a per-run token (PID + epoch ms) and a private temp dir at `repos/.ralph/.plan-tmp/<token>/`. Each worker writes its repo's plan output to `repos/.ralph/.plan-tmp/<token>/<repo>.md`. No locking needed; each worker owns its own file, and two concurrent invocations cannot collide on temp paths.
2. Once all workers finish (or fail-out), the main process holds an advisory lock on `repos/.ralph/.plan.lock` via `flock`, then concatenates the per-repo temp files from `<token>/` into the final `repos/.ralph/fix_plan.md` in REPO list order.
3. On success, the per-run `<token>/` dir is removed. On failure it is preserved for debugging.
4. **Startup cleanup.** On every `ralph-plan --workspace` start, scan `repos/.ralph/.plan-tmp/` for any `<token>/` dirs whose owning PID is not alive. Delete them silently. This sweeps orphans from prior crashed runs without surprising a concurrent live run.

Why not concurrent in-place writes:
- `fix_plan.md` is a single markdown file with section headers like `## repo: <name>`. Concurrent appends would interleave lines.
- Locking the entire file across the duration of an engine call (tens of seconds) serializes the very thing we are trying to parallelize.

Why advisory `flock` on the merge step at all:
- A second invocation of `ralph-plan --workspace` against the same workspace (e.g., a stale `wb.ralph-plan` from another shell) must not write a half-merged file. The lock makes the merge step atomic at the workspace level.
- Workbench already uses `flock` on `.workbench-state/.lock` for its lifecycle writes; the convention transfers cleanly.

The lock file path is `repos/.ralph/.plan.lock`. It is created on demand and may be deleted at any time when no merge is in flight. The lock is non-blocking with a 30 s timeout; on timeout the second invocation exits with `another ralph-plan is already merging fix_plan.md, try again in a moment`.

## 6. Default value for N

Default resolution order (first match wins):

1. CLI flag `--parallel-plan N`.
2. Env var `RALPH_PLAN_PARALLEL`.
3. Per-engine default from the table in §4.
4. Hard fallback: 1 (sequential).

The current sequential behavior is preserved when no flag and no env var are set AND the engine is not in the table or the user explicitly wants the V1 path (set `RALPH_PLAN_PARALLEL=1`).

Recommendation for ai-ralph V2 ship: default to 1 for one minor version, then flip the per-engine defaults in the next minor. This gives users one release to spot rate-limit surprises before parallelism becomes implicit.

## 7. Env override path

Single env var: `RALPH_PLAN_PARALLEL`.

```
export RALPH_PLAN_PARALLEL=4
ralph-plan --workspace --engine claude
```

Equivalent to `--parallel-plan 4`. Same validation rules: must be a positive integer, capped at `len(REPOS)`, rejected in per-repo mode.

Workbench-side, `project.conf` will gain a parallel-plan knob in a follow-up workbench PR (see §10): `RALPH_PLAN_PARALLEL=""` empty by default, exported into the env if non-empty.

## 8. Back-compat for callers that do not pass the flag

Hard requirement: invocations that do not pass `--parallel-plan` and do not set `RALPH_PLAN_PARALLEL` must produce **byte-identical** `fix_plan.md` output to V1, given the same engine, the same inputs, and the same engine response (mocked in tests).

This is achieved by:

- Sequential code path remains in place. When N resolves to 1 the implementation calls the same per-repo planning function as V1, in the same loop order, writing directly to the final file (no temp dir). The new buffer-then-merge path is only taken when N > 1.
- Section header format, blank lines between sections, trailing newline, and section ordering are unchanged.
- Logging output for the sequential path is unchanged. Parallel runs add a new `[parallel-plan N=k]` prefix on the worker dispatch lines so log scrapers can spot the difference, but the per-repo planning lines stay the same shape.

CLI back-compat:

- All existing flags continue to work unchanged.
- `--parallel-plan` is additive; absence ⇒ V1 behavior (modulo engine-default lookup, which can be opted out via `RALPH_PLAN_PARALLEL=1`).
- The `--workers` alias is purely a convenience; it is not deprecated and not preferred either.

## 9. Rollout plan

Three-phase ship inside ai-ralph:

**Phase A (feature merged behind explicit flag, one minor release).**
- Implementation lands. Default stays sequential (no engine-default kicks in). Users opt in with `--parallel-plan N` or `RALPH_PLAN_PARALLEL=N`.
- Workbench docs updated to mention the flag exists, but not as the default.
- Telemetry (if ralph has any, currently it does not): count usage and rate-limit hits per engine.

**Phase B (engine defaults switch on, next minor).**
- Per-engine defaults from the table in §4 take effect. Users on shared / low-tier keys can revert with `RALPH_PLAN_PARALLEL=1`.
- Release notes call out the change and list the per-engine numbers.

**Phase C (workbench wires the flag through).**
- After Phase A merges, workbench ships its own follow-up PR (see §10) that adds `--parallel-plan` passthrough on `wb.ralph-plan` and a `RALPH_PLAN_PARALLEL` line in `project.conf.template`.

If Phase B uncovers rate-limit complaints, the ralph team can lower a default in a patch release without touching the flag surface.

## 10. Test coverage

ai-ralph side, new tests required:

| Test | Scope | Asserts |
|------|-------|---------|
| `--parallel-plan` flag parses | unit | N=1, N=4 accepted; N=0 errors; non-int errors |
| `--parallel-plan` rejected in per-repo mode | unit | error message names per-repo mode |
| Per-engine default lookup | unit | claude→4, devin→2, codex→2, unknown→1 |
| Env override picks up `RALPH_PLAN_PARALLEL` | unit | env=3 with no flag ⇒ 3 |
| CLI flag wins over env | unit | flag=4 with env=2 ⇒ 4 |
| Sequential output byte-identical to V1 | golden | snapshot before / after; no diff when N=1 |
| Parallel output equals sequential output | golden | with mocked engine, run with N=1 and N=4; outputs match |
| Section ordering stable under N>1 | golden | shuffle worker completion order; output order matches REPO list |
| Lock contention | integration | second `ralph-plan --workspace` while first is mid-merge ⇒ second fails after 30 s with the expected message |
| Worker failure isolation | integration | one worker fails three retries; other workers' sections appear; failed repo's section has the placeholder; exit code non-zero |
| Cap at len(REPOS) | unit | N=8, REPOS=3 ⇒ effective N=3, no warning |
| Temp dir cleanup | integration | success run leaves no `.plan-tmp/` |
| Temp dir preserved on failure | integration | a failing run leaves `.plan-tmp/` for inspection |

Workbench side, after the workbench follow-up PR (see §11):

- `bash tests/smoke.sh` continues to pass; smoke does not exercise ralph itself, only the workbench wrappers, so the assertion is just that the new flag passthrough does not break dry-run.
- A dry-run smoke assertion: `wb.ralph-plan --parallel-plan 4 --dry-run` echoes `--parallel-plan 4` in the printed ralph command.

## 11. What workbench changes when this lands

When the upstream `--parallel-plan` flag ships, workbench takes a small, scoped follow-up PR. Out of scope for this design doc; listed for traceability.

Files in workbench that change (later, not now):

- `scripts/ralph-plan.sh`:
  - Add `--parallel-plan N` and `--workers N` argument parsing.
  - Resolve in the order CLI > env `WB_RALPH_PLAN_PARALLEL` > `project.conf RALPH_PLAN_PARALLEL` > unset (let ralph pick its own default).
  - Pass through to the `ralph-plan --workspace` command line. Reject in per-repo mode.
  - Echo the resolved value in the `[wb.ralph-plan] mode=workspace engine=... parallel-plan=...` banner.

- `project.conf.template`:
  - Add `RALPH_PLAN_PARALLEL=""` near `RALPH_PLAN_ENGINE`.

- `CLAUDE.md` "Ralph adapter (quick reference)":
  - Update the `wb.ralph-plan` line to mention the new flag.

- `README.md` "Multi-repo execution with ralph":
  - Add a note that planning runs in parallel by default once your installed ralph is >= the version that ships parallel-plan, and how to opt out.

- `tests/smoke.sh`:
  - Add a dry-run assertion as described in §10.

No SKILL.md or steering rule changes are anticipated; this is a purely orchestration knob.

## 12. Open questions for the ralph maintainer

1. Is `--workers` worth adding as an alias, or do we prefer just `--parallel-plan`? The doc proposes both; the maintainer may strip the alias.
2. Should the per-engine default table live in code, in a config file shipped with ralph, or be pluggable? The doc assumes code-resident with sensible numbers; pluggable is overkill for V2.
3. Is 30 s the right lock timeout? Long-running engine calls under N=1 (sequential) plus a second invocation overlap can push past 30 s legitimately. A possible alternative is "wait until the in-flight merge step completes," with no engine-call window included. The buffer-then-merge design already keeps the lock window small (just the concatenate-and-write step), so 30 s should be plenty, but worth confirming.
4. Do we want to expose the per-repo temp file path under `repos/.ralph/.plan-tmp/<repo>.md` as a documented contract, or keep it internal? The doc treats it as internal; debugging tools may want a public name.
