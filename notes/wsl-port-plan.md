# WSL2 Port — ai-ralph (Wave 2 / loop core)

**Master plan:** `/Users/amittiwari/.claude/plans/all-scripts-in-workbench-glowing-iverson.md`
**Wave:** 2 of 3 — **loop core**. Depends on Wave 1 (ai-devkit) PR 1b merging first; unblocks Wave 3 (ai-workbench) when PR 2b merges.
**Locked decisions:** WSL2 Ubuntu only; bash 5.x baseline; `ubuntu-latest` = WSL proxy in CI; sequential repos + phased PRs; non-breaking for existing macOS users.

---

## Scope (this repo only)

ai-ralph owns the loop, plan, and PR-creation machinery. Largest surface (~94 shell files; many `*.bash` and `*.sh`). The audit confirms the GNU/BSD divergence is **already handled** in `lib/date_utils.sh` (3-way fallback) and `lib/timeout_utils.sh` (uname switch). This wave is **verification-driven**: add lint + tests + smoke job that would have caught the friction devs report.

In scope:
- `.gitattributes` — LF policy
- `.github/workflows/lint.yml` (or extend existing test.yml) — bash -n + shellcheck on all shell files
- `.github/workflows/smoke-ralph.yml` — fresh-fresh `ralph install` + `ralph_enable.sh --workspace` smoke
- `tests/unit/lib_date_utils.bats` — pin GNU+BSD+manual-fallback behaviour
- `tests/unit/lib_timeout_utils.bats` — pin Linux=timeout / Darwin=gtimeout behaviour
- `tests/integration/smoke-ralph.bash` — local runner
- `docs/onboarding-wsl.md` — WSL-specific dev guide
- Shellcheck-warning cleanup across `lib/*.sh`, `*.sh`, `codex/`, `devin/` — phased

Out of scope:
- Rewriting `lib/date_utils.sh` or `lib/timeout_utils.sh` (already portable; only ADD tests)
- Rewriting `ralph_loop.sh`, `ralph_plan.sh` body beyond shellcheck-driven fixes
- Replacing `jq`, `gh`, `flock` (require, don't replace)
- Native windows-latest CI (deferred)
- Touching anything in `codex/` or `devin/` other than shellcheck fixes if those variants are active

---

## Existing patterns to reuse (do NOT rewrite)

- `lib/date_utils.sh:9-35,53-97` — 3-way fallback (GNU `date -d` → BSD `date -j` → manual epoch arithmetic with bash `=~`). WSL bash 5.x lands on the GNU branch immediately.
- `lib/timeout_utils.sh:15-50` — `uname` switch. WSL is `Linux` → uses standard `timeout`. macOS Darwin → `gtimeout` (or fallback to `timeout`).
- `install.sh` — already has `os_type=$(uname)` early; respects Linux vs Darwin.

These are the patterns to **pin via tests**, not rewrite.

---

## PRs in this wave

### PR 2a — `chore(ci): add lint matrix + .gitattributes`

**Create:**
- `.gitattributes`:
  ```
  * text=auto eol=lf
  *.sh text eol=lf
  *.bash text eol=lf
  *.py text eol=lf
  *.md text eol=lf
  *.png binary
  ```
- `.github/workflows/lint.yml` (or extend `.github/workflows/test.yml` with new jobs):
  - **shell-lint** matrix `[ubuntu-latest, macos-latest]`:
    1. `apt-get install -y shellcheck` (linux) / `brew install shellcheck` (mac)
    2. `bash -n $(git ls-files '*.sh' '*.bash')`
    3. `shellcheck -x -e SC1091 $(git ls-files '*.sh' '*.bash')` — **severity=error** for PR 2a; tighten to `warning` in PR 2c after cleanup

**Verification:**
- CI green both matrix slots.
- Local: `find . -name '*.sh' -o -name '*.bash' | xargs -n1 bash -n` exits 0.
- Local: `shellcheck -S error -x $(git ls-files '*.sh' '*.bash')` exits 0.

**Done when:** PR merged. CI gate established.

---

### PR 2b — `test(lib): pin date_utils + timeout_utils behaviour on Linux + macOS`

**Create:**
- `tests/unit/lib_date_utils.bats`:
  ```bats
  load 'helpers'
  source "$BATS_TEST_DIRNAME/../../lib/date_utils.sh"

  @test "get_iso_timestamp returns RFC3339-ish UTC string" {
    run get_iso_timestamp
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
    [[ "$output" =~ (\+00:00|Z)$ ]]
  }

  @test "parse_iso_to_epoch round-trips a canonical ISO string" {
    iso=$(get_iso_timestamp)
    epoch=$(parse_iso_to_epoch "$iso")
    now=$(date +%s)
    diff=$((epoch - now))
    [ "${diff#-}" -le 2 ]
  }

  @test "get_next_hour_time returns valid HH:MM:SS" {
    run get_next_hour_time
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]
  }

  @test "parse_iso_to_epoch falls back to current epoch on empty/null input" {
    epoch=$(parse_iso_to_epoch "")
    [[ "$epoch" =~ ^[0-9]+$ ]]
    epoch=$(parse_iso_to_epoch "null")
    [[ "$epoch" =~ ^[0-9]+$ ]]
  }
  ```
- `tests/unit/lib_timeout_utils.bats`:
  ```bats
  source "$BATS_TEST_DIRNAME/../../lib/timeout_utils.sh"

  @test "detect_timeout_command resolves to a non-empty command name" {
    reset_timeout_detection
    run detect_timeout_command
    [ "$status" -eq 0 ]
    [ -n "$output" ]
  }

  @test "portable_timeout returns 124 on timeout" {
    run portable_timeout 1s sleep 5
    [ "$status" -eq 124 ]
  }

  @test "portable_timeout returns 0 on quick success" {
    run portable_timeout 5s echo ok
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
  }

  @test "detect_timeout_command on Linux returns 'timeout'" {
    [[ "$(uname)" == "Linux" ]] || skip "Linux-only assertion"
    reset_timeout_detection
    run detect_timeout_command
    [ "$output" = "timeout" ]
  }

  @test "detect_timeout_command on Darwin returns 'gtimeout' when available" {
    [[ "$(uname)" == "Darwin" ]] || skip "Darwin-only assertion"
    command -v gtimeout >/dev/null 2>&1 || skip "gtimeout not installed"
    reset_timeout_detection
    run detect_timeout_command
    [ "$output" = "gtimeout" ]
  }
  ```

**Modify (only if a test surfaces a real bug):** `lib/date_utils.sh` or `lib/timeout_utils.sh`. Audit says no.

**Verification:**
- New bats tests green on both matrix slots.
- macos-latest may need `brew install coreutils` to get `gtimeout` for the Darwin-specific assertion — add that to the CI setup step.

**Done when:** PR merged. **Wave 3 (ai-workbench) unblocked.**

---

### PR 2c — `chore(lint): shellcheck warning cleanup (phased by directory)`

Commits inside this PR:
1. `chore(lint): shellcheck warning cleanup for lib/`
2. `chore(lint): shellcheck warning cleanup for top-level *.sh`
3. `chore(lint): shellcheck warning cleanup for codex/`
4. `chore(lint): shellcheck warning cleanup for devin/`
5. `ci: tighten shellcheck severity to warning`

For each commit:
- Run `shellcheck -S warning -x <subset>` in the local repo
- Fix only mechanical findings (quote variables, prefer `[[ ]]`, use `$(...)` not backticks, etc.)
- Avoid behaviour changes; preserve existing logic exactly
- Commit small, with `chore(lint):` prefix

**Verification:**
- `shellcheck -S warning -x $(git ls-files '*.sh' '*.bash')` exits 0 at end.
- All existing tests still green.

**Done when:** PR merged.

---

### PR 2d — `ci(smoke): ralph install + enable workspace end-to-end on ubuntu-latest`

**Create:**
- `.github/workflows/smoke-ralph.yml` — `runs-on: ubuntu-latest`, pre-baked image:
  ```yaml
  steps:
    - uses: actions/checkout@v4
    - name: Install prereqs
      run: sudo apt-get update && sudo apt-get install -y jq gh git
    - name: Run installer
      run: bash install.sh --yes
    - name: Set up a tiny fixture target repo
      run: |
        mkdir -p /tmp/fixture-repo && cd /tmp/fixture-repo
        git init -q && git config user.email a@b.c && git config user.name a
        echo "# fixture" > README.md
        echo "## task A" > fix_plan.md
        git add . && git commit -q -m "init"
    - name: Enable ralph workspace
      run: cd /tmp && mkdir -p repos && (cd /tmp/fixture-repo && bash $GITHUB_WORKSPACE/ralph_enable.sh)
    - name: Plan dry-run
      run: cd /tmp/fixture-repo && bash $GITHUB_WORKSPACE/ralph_plan.sh --dry-run || true
    - name: Assert plan file created
      run: test -f /tmp/fixture-repo/.ralph/fix_plan.md
  ```
  Adjust command flags to match the actual ralph CLI; the above is a sketch.
- `tests/integration/smoke-ralph.bash` — local runner with the same steps.
- `docs/onboarding-wsl.md`:
  ```markdown
  # Running ai-ralph on WSL2

  ai-ralph is supported on WSL2 Ubuntu (bash 5.x). Prereqs:

      sudo apt install -y jq gh git

  Clone target repos under `$HOME`, not `/mnt/c/`. DrvFs paths are 10x slower and break fsync.

  ## Quick start

  ```
  git clone https://github.com/amit-t/ai-ralph ~/ralph
  bash ~/ralph/install.sh
  cd /path/to/your/repo
  ralph_enable.sh
  ralph_loop.sh
  ```

  ## Common issues

  - "command not found: gtimeout" on WSL — false positive; the code uses `uname` to branch and picks `timeout` on Linux. If you see this, file an issue.
  - "CRLF detected" — repo `.gitattributes` enforces LF. If you cloned before this was added, run `git add --renormalize . && git commit -m 'chore: renormalize line endings'`.
  ```

**Verification:**
- CI smoke green.
- Manual: `docker run --rm -it ubuntu:22.04 bash -c 'apt update && apt install -y jq gh git curl ca-certificates && git clone https://github.com/amit-t/ai-ralph /tmp/ralph && bash /tmp/ralph/install.sh'` exits 0.

**Done when:** PR merged. Wave 2 complete.

---

## Per-PR doneness gate

- [ ] `bash -n` on all `*.sh` + `*.bash` exits 0
- [ ] `shellcheck -x` exits 0 at current severity level (error for 2a-2b; warning post-2c)
- [ ] New bats / integration tests green on both ubuntu-latest and macos-latest
- [ ] macos-latest CI stays green — hard rule
- [ ] Conventional Commit message; HEREDOC body; Co-Authored-By Claude line
- [ ] PR description references master plan and lists which Wave/PR

## Wave-done criterion

All four PRs merged. CI green on both matrix slots. Manual docker smoke confirms fresh `ubuntu:22.04 → ralph install → ralph_enable.sh` flow works end-to-end. At that point Wave 3 (ai-workbench) is unblocked.

---

## Session kickoff prompt template

When you open Claude Code in this repo (`cd ~/Projects/Tools-Utilities/ai-ralph && claude`), the first prompt should be:

> Read `notes/wsl-port-plan.md` and the master plan it references. Ultrathink, enter plan mode, then execute Wave 2 PR 2a end-to-end. Boil the ocean: complete + tested + docs + verification. When done, summarise the diff and exit. I will review the PR before kicking off PR 2b.

Subsequent prompts: same pattern, named per PR.
