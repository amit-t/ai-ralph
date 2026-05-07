# Upstream ralph V2: `--repos <subset>` filter for `ralph --workspace`

Status: draft (design only, not implementation).
Audience: ai-ralph maintainers. This doc lives in workbench because the workbench team is the primary requester; once accepted, the implementation PR moves to `ai-ralph`.
Author: ai-workbench team.
Date: 2026-04-29.

## 1. Problem statement

`ralph --workspace` (shipped via the workspace-mode work in `lib/workspace_manager.sh`) walks every git repo under `repos/` and either picks a single task (sequential) or fans out one task per repo (parallel). The repo set is fixed at runtime by `discover_workspace_repos()`: any directory under the workspace root that contains a `.git/` is in scope.

That worked for V1 when "the workspace" and "the active set of repos" were the same thing. In practice they have started to diverge:

- **One repo is mid-refactor.** The dev pair has a long-lived branch in `repos/web` that they do not want ralph to touch yet, but the other three repos in `repos/` are actively planned. Today the only ways to skip `web` are (a) move the directory out of `repos/`, which breaks `wb.sync-context` and `project.conf`, or (b) delete the `## web` section from `repos/.ralph/fix_plan.md` after every `wb.ralph-plan` run, which is brittle.
- **Bug-fix sprint on one service.** The dev wants ralph to focus on `repos/api` for the next two hours. They do not want to lose the merged `fix_plan.md` view across repos; they just want ralph to ignore everything except `api` for this run.
- **CI / scheduled runs that target one repo.** A future workbench cron might run `ralph --workspace` on a single service every hour while leaving the rest of the workspace alone. Today the only equivalent is `cd repos/api && ralph --live --monitor`, which loses workspace-mode telemetry, cross-repo task picking, and the merged fix_plan view.
- **Companion of `wb.ralph-plan --replan <repo>`.** The replan workflow already targets a single repo on the planning side. Execution has no symmetric flag, so a "plan one repo, execute one repo" loop is awkward.

This doc proposes adding two flags to `ralph --workspace`: `--repos <list>` (allowlist) and `--exclude <list>` (denylist), so the user can scope a workspace run to a subset of registered repos without changing on-disk layout or the merged fix_plan.

## 2. Why no filter exists today

Three reasons V1 did not ship a filter:

1. **Workspace was a closed set.** Early adopters had two or three repos and wanted ralph to plan and execute against all of them every loop. There was no demand for partial scope.
2. **Discovery is filesystem-driven.** `discover_workspace_repos()` returns whatever has `.git/`. Adding a filter at the discovery layer is straightforward but changes the contract of an exported function used elsewhere (`validate_workspace`, `_run_workspace_parallel`).
3. **Cross-repo tasks complicate the picture.** `repos/.ralph/fix_plan.md` supports a `## cross-repo` section. A naive subset filter that excludes a repo while leaving its cross-repo dependency in scope would let ralph pick up a cross-repo task that names the excluded repo. The design needs an explicit answer for this.

V2 needs to add a clean opt-in filter while keeping (1) the closed-set default and (2) cross-repo correctness.

## 3. Proposed flags

Add to `ralph` (workspace mode only):

```
--repos <comma-separated-list>     # allowlist: only these repos are in scope
--exclude <comma-separated-list>   # denylist: every repo except these
```

Both flags accept a comma-separated list of repo directory names (matching the names returned by `discover_workspace_repos()`, which is `basename` of each child directory). Whitespace around commas is ignored. Empty list is a parse error.

Semantics:

- Flags are mutually exclusive. `--repos a,b` together with `--exclude c` is a parse error: `--repos and --exclude cannot be combined`.
- Names are matched exact-string against the discovery output. No globs, no regex. If `repos/api-v2` exists but the user passes `--repos api`, that is a parse error: `unknown repo: api`.
- Names that resolve to no on-disk directory are an error, not a warning. The intent is to fail fast on typos.
- After applying the filter, the resulting set is empty ⇒ error: `--repos / --exclude filtered out every repository`.
- After applying the filter, the resulting set is one repo ⇒ workspace mode still runs (it is a one-repo workspace for this invocation). Sequential and parallel paths both handle N=1 correctly today.
- In per-repo (non-workspace) mode the flags are rejected with a clear error: `--repos / --exclude only apply to --workspace mode`.

## 4. Interaction with discovery

The filter is applied inside `discover_workspace_repos()` (or in a thin wrapper around it). Two options were considered:

| Option | Where the filter lives | Pros | Cons |
|--------|------------------------|------|------|
| A | Inside `discover_workspace_repos()` itself | Single chokepoint; everything downstream sees the filtered set automatically (`validate_workspace`, parallel picker, sequential picker). | Function takes on a global side effect via env. Breaks the "pure discovery" contract. |
| B | In a new wrapper `discover_workspace_repos_filtered()` called by `run_workspace_mode()` only | Discovery stays pure; explicit filter call site. | Two functions to keep in sync; downstream callers (e.g., future tooling) might still use the unfiltered version and mis-report scope. |

The doc recommends **Option A with an explicit argument**: extend `discover_workspace_repos()` to accept an optional second arg `repo_filter_spec`, which is parsed once at CLI entry and threaded through. Existing callers (one in `validate_workspace`, one in `run_workspace_mode`) pass through the filter spec; new callers default to empty (no filter). This keeps the chokepoint single, avoids env-var side effects, and preserves back-compat: callers that pass no second arg get unfiltered behavior identical to V1.

The filter spec is a simple struct in shell terms: two arrays `INCLUDE_REPOS` and `EXCLUDE_REPOS`, populated from the CLI flags at parse time. `discover_workspace_repos()` walks the filesystem, then drops any name not in `INCLUDE_REPOS` (when set) and any name in `EXCLUDE_REPOS` (when set), then sorts.

## 5. Interaction with cross-repo tasks

`fix_plan.md` may carry a `## cross-repo` section with tasks that name multiple repos in the body. Today both the sequential picker (`pick_workspace_task`) and the parallel picker (`pick_workspace_tasks_parallel`) skip the cross-repo section when picking by repo. Cross-repo execution is a separate codepath that workbench does not yet exercise.

Decision for V2:

- **`--repos` / `--exclude` ignore the `## cross-repo` section.** When a filter is active, cross-repo tasks are not picked. This is the safe default: a cross-repo task that needs `web` cannot be run safely if `web` is excluded, and "the user knows which repos this cross-repo task touches" is harder to validate than "skip cross-repo when scope is partial."
- **No `--include-cross-repo` opt-in in V2.** If demand appears, add it as a follow-up flag with an explicit reminder that the user is responsible for ensuring every named repo is in scope.
- The behavior is logged on entry: `[workspace] filter active: include=[a,b] exclude=[] cross-repo=skipped`.

This is documented in §11 as a workbench-side knob to expose later.

## 6. Default value for the filter

Default: **no filter**. Same set of repos as V1.

Resolution order (first non-empty wins):

1. CLI flags `--repos` / `--exclude`.
2. Env vars `RALPH_WORKSPACE_REPOS` (allowlist) / `RALPH_WORKSPACE_EXCLUDE` (denylist), same comma-separated format.
3. Empty (V1 behavior).

Env vars are mutually exclusive with each other for the same reason the flags are. Setting one when the other is non-empty is a parse error.

A CLI flag overrides the corresponding env var. Setting `--repos a` with `RALPH_WORKSPACE_EXCLUDE=b` set is a parse error (mixed sources of truth); the user must pick one and explicitly unset the other. The error message names both: `--repos conflicts with RALPH_WORKSPACE_EXCLUDE; unset the env var or use --exclude on the CLI`.

## 7. Env override path

```
export RALPH_WORKSPACE_REPOS=api,worker
ralph --workspace --parallel 2
```

Equivalent to `ralph --workspace --parallel 2 --repos api,worker`. Same validation rules apply.

```
export RALPH_WORKSPACE_EXCLUDE=web
ralph --workspace
```

Excludes only `web` from the discovered set.

Workbench-side, `project.conf` will gain a `WB_RALPH_DISPATCH_REPOS` and `WB_RALPH_DISPATCH_EXCLUDE` knob in a follow-up workbench PR (see §11), exported into the env if non-empty.

## 8. Back-compat for callers that do not pass the flag

Hard requirement: invocations that do not pass `--repos` or `--exclude` and do not set the env vars must produce **byte-identical** behavior to V1: same repo set, same task picking order, same output, same logging.

This is achieved by:

- `discover_workspace_repos()` second arg defaults to empty / unset. When unset, the function takes the V1 fast path (no filter loop). Snapshot tests on the function's output cover this.
- Sequential picker and parallel picker call the discovery function with the same filter spec the CLI parsed. When unset, they see the same list V1 saw.
- Validation messages remain unchanged when no filter is active. Only when a filter is active does ralph emit the new `[workspace] filter active: ...` line.
- Engine prompts (the `build_workspace_repo_context` block) do not reference the filter. Repos that survive the filter look identical to repos that would have been picked anyway.

CLI back-compat:

- All existing flags continue to work unchanged.
- `--repos` and `--exclude` are additive; absence ⇒ V1 behavior.
- `--workspace --parallel N --repos a,b` is a valid combination: parallelism is then capped at `min(N, len(filtered_set), repos_with_pending)` per the existing `get_workspace_parallel_limit()` logic. The filter feeds in upstream of that calculation.

## 9. Rollout plan

Two-phase ship inside ai-ralph:

**Phase A (feature merged behind explicit flag).**
- Implementation lands. Default is no filter (no behavior change).
- Both flags and both env vars are recognized.
- Workbench docs updated to mention the flags exist; workbench wrapper not yet wired.
- Telemetry (if ralph adds any in V2): count filter usage, flag-vs-env, allowlist-vs-denylist.

**Phase B (workbench wires the flag through).**
- After Phase A merges, workbench ships a follow-up PR (see §11) that adds `--repos` and `--exclude` passthrough on `wb.ralph-dispatch` and `WB_RALPH_DISPATCH_REPOS` / `WB_RALPH_DISPATCH_EXCLUDE` lines in `project.conf.template`.
- README "Multi-repo execution with ralph" section gains an "Subsetting a run" subsection.

No deprecation of any V1 behavior is planned. The filter is purely additive.

## 10. Test coverage

ai-ralph side, new tests required:

| Test | Scope | Asserts |
|------|-------|---------|
| `--repos` flag parses | unit | comma-separated list accepted; whitespace trimmed; empty list errors |
| `--exclude` flag parses | unit | same shape as `--repos` |
| `--repos` and `--exclude` mutually exclusive | unit | error names both flags |
| Unknown repo name | unit | `--repos foo` with no `repos/foo` ⇒ error names the missing repo |
| Empty result set | unit | filter that drops every repo ⇒ error with the resolved filter spec in the message |
| One-repo result | integration | `--repos api` with three repos on disk runs the sequential and parallel paths against `api` only |
| Filter rejected in per-repo mode | unit | `ralph --repos a` (no `--workspace`) ⇒ error names per-repo mode |
| Env var picked up | unit | `RALPH_WORKSPACE_REPOS=a,b` with no flag ⇒ same as `--repos a,b` |
| CLI flag wins over env | unit | flag=`a` with `RALPH_WORKSPACE_REPOS=b` ⇒ resolved to `a` |
| Mixed env vars rejected | unit | both env vars set non-empty ⇒ error |
| Mixed CLI / env across allowlist + denylist | unit | `--repos a` with `RALPH_WORKSPACE_EXCLUDE=b` ⇒ error |
| Sequential output unchanged when no filter | golden | snapshot before / after; no diff |
| Parallel limit recalculated post-filter | unit | filtered set of 2, `--parallel 4` ⇒ effective parallel = 2 |
| `## cross-repo` skipped under filter | integration | fix_plan with cross-repo task; filter active ⇒ cross-repo task is not picked, log mentions cross-repo=skipped |
| `discover_workspace_repos` second arg | unit | unset ⇒ V1 behavior; set ⇒ filtered output |
| `validate_workspace` honors filter | unit | warning about repo missing on disk only fires for repos in scope |

Workbench side (after the workbench follow-up PR in §11):

- `bash tests/smoke.sh` continues to pass; smoke does not exercise ralph itself.
- Dry-run smoke assertion: `wb.ralph-dispatch --repos api --dry-run` echoes `--repos api` in the printed ralph command.
- Dry-run smoke assertion: `wb.ralph-dispatch --exclude web --dry-run` echoes `--exclude web`.
- Dry-run smoke assertion: `WB_RALPH_DISPATCH_REPOS=api wb.ralph-dispatch --dry-run` echoes `--repos api`.
- Negative smoke assertion: `wb.ralph-dispatch --repos foo --dry-run` against a workspace with no `foo` repo exits non-zero before the ralph call.

## 11. What workbench changes when this lands

When the upstream `--repos` / `--exclude` flags ship, workbench takes a small, scoped follow-up PR. Out of scope for this design doc; listed for traceability.

Files in workbench that change (later, not now):

- `scripts/ralph-dispatch.sh`:
  - Add `--repos <list>` and `--exclude <list>` argument parsing.
  - Resolve in the order CLI > env (`WB_RALPH_DISPATCH_REPOS` / `WB_RALPH_DISPATCH_EXCLUDE`) > `project.conf` (`WB_RALPH_DISPATCH_REPOS` / `WB_RALPH_DISPATCH_EXCLUDE`) > unset (let ralph see no filter).
  - Validate names against `project.conf REPOS` before passing through, so a typo fails inside the workbench wrapper with the registered-repo list in the error.
  - Pass through to the `ralph --workspace` command line.
  - Reject `--repos` together with `--exclude` at the wrapper layer (matches ralph behavior; gives a faster error).
  - Echo the resolved spec in the `[wb.ralph-dispatch] parallel=N engine=... repos=...` banner.

- `project.conf.template`:
  - Add `WB_RALPH_DISPATCH_REPOS=""` and `WB_RALPH_DISPATCH_EXCLUDE=""` near `WB_RALPH_PARALLEL`.

- `CLAUDE.md` "Ralph adapter (quick reference)":
  - Update the `wb.ralph-dispatch` line to mention the new flags.
  - Add a sentence pairing them with `wb.ralph-plan --replan <repo>` for symmetric "plan one, execute one" runs.

- `README.md` "Multi-repo execution with ralph":
  - Add a "Subsetting a run" subsection with two examples (`--repos`, `--exclude`) and a note that cross-repo tasks are skipped under a filter.

- `tests/smoke.sh`:
  - Add the dry-run assertions described in §10 (workbench side).

No SKILL.md or steering rule changes are anticipated; this is a purely orchestration knob. The artifact validator (`scripts/validate-artifact.py`) is untouched: `target_repos:` frontmatter still names the artifact's audience; the dispatch filter is a runtime narrowing, not a re-routing of approved artifacts.

## 12. Open questions for the ralph maintainer

1. Is the `discover_workspace_repos()` second-argument approach (Option A in §4) preferred, or should the filter live in a wrapper at the call site (Option B)? The doc recommends A; happy to refactor if the maintainer prefers B for future extensibility.
2. Should the filter spec accept globs (`api-*`) in V2, or stay exact-name-only? The doc proposes exact-only; globs are easy to add later as a non-breaking change.
3. Should `--repos` honor section ordering from `fix_plan.md` over filesystem sort order, given that workbench cares about REPO list ordering in its merged plan? The doc proposes filesystem-sorted (matches V1 ordering of `discover_workspace_repos`). If maintainers prefer `fix_plan.md` order, the ordering change would be observable in the parallel path (which already iterates the filtered set in its own order) but not in the sequential picker (which is task-level, not repo-level).
4. Does cross-repo always skip under a filter (the doc proposes yes), or should there be a `--include-cross-repo` opt-in even in V2? The doc punts to a future flag; happy to ship it now if the maintainer wants the surface complete in one release.
5. Is exposing the filter through both flags AND env vars overkill? The doc keeps both because workbench's `project.conf` pipeline depends on env passthrough, but a maintainer who prefers a single surface could reasonably ship CLI-only and let the workbench wrapper translate from `project.conf` to flags.
