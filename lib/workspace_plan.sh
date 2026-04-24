#!/bin/bash
# lib/workspace_plan.sh — Multi-repo planning mode for ralph-plan --workspace
#
# Provides per-repo planning: drives the selected engine once per repo, captures
# structured output (tasks + ambiguities + cross-repo flags), and merges results
# into the workspace .ralph/fix_plan.md while preserving in-progress [~] and
# completed [x] task state on matching lines.
#
# Engine output contract (AI writes to $output_file for each repo):
#   ## tasks
#   - First task
#   - Second task
#
#   ## ambiguities
#   - Unclear point (optional)
#
#   ## cross-repo
#   - Cross-cutting task (optional)
#
# Test hook: if RALPH_PLAN_WS_MOCK_DIR is set, the engine runner copies
# "$RALPH_PLAN_WS_MOCK_DIR/<repo_name>.out.md" to $output_file instead of
# invoking the real engine. Lets bats exercise the merge pipeline end-to-end.

# shellcheck disable=SC2155

# Require workspace_manager.sh to be sourced first (discover_workspace_repos, is_workspace_mode).

# workspace_plan_preflight — Verify cwd is a valid workspace root
# Args:
#   $1 - workspace_dir (default: .)
# Returns: 0 if valid, 1 otherwise. Prints error to stderr on failure.
workspace_plan_preflight() {
    local ws="${1:-.}"

    if [[ ! -d "$ws" ]]; then
        echo "ERROR: Workspace directory not found: $ws" >&2
        return 1
    fi

    if [[ -d "$ws/.git" ]]; then
        echo "ERROR: Current directory is a git repository, not a workspace root. Run from the parent directory containing multiple repos." >&2
        return 1
    fi

    if [[ ! -f "$ws/.ralph/fix_plan.md" ]]; then
        echo "ERROR: Workspace fix_plan.md not found at $ws/.ralph/fix_plan.md. Run 'ralph-enable --workspace' first." >&2
        return 1
    fi

    local repo_count=0
    local entry
    for entry in "$ws"/*/; do
        [[ -d "$entry" ]] || continue
        local base
        base=$(basename "$entry")
        [[ "$base" == .* ]] && continue
        if [[ -d "$entry/.git" ]]; then
            repo_count=$((repo_count + 1))
        fi
    done

    if [[ $repo_count -eq 0 ]]; then
        echo "ERROR: No child git repositories found in workspace: $ws" >&2
        return 1
    fi

    return 0
}

# workspace_plan_collect_repo_context — Concatenate planning context files for a repo
# Reads from <repo_path>/ai/ (workbench convention) and <repo_path>/.ralph/specs/
# (ralph-native). If both exist, concatenates both. Recurses up to 3 levels deep
# for *.md, *.txt, *.json files.
#
# Args:
#   $1 - repo_path
# Outputs: concatenated context on stdout (may be empty)
# Returns: 0 if any content found, 1 otherwise
workspace_plan_collect_repo_context() {
    local repo_path="$1"
    local found=0
    local dir
    local file

    for dir in "$repo_path/ai" "$repo_path/.ralph/specs"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r file; do
            [[ -z "$file" ]] && continue
            echo "----- ${file#"$repo_path"/} -----"
            cat "$file" 2>/dev/null || true
            echo ""
            found=1
        done < <(find "$dir" -maxdepth 3 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.json" \) 2>/dev/null | sort)
    done

    [[ $found -eq 1 ]] && return 0
    return 1
}

# workspace_plan_build_prompt — Build planning prompt for a single repo
# Args:
#   $1 - prompt_file (output)
#   $2 - repo_name
#   $3 - repo_path
#   $4 - output_file (absolute path the AI must write to)
#   $5 - thinking_level (normal|hard|ultra)
#   $6 - context (large string, may be empty)
workspace_plan_build_prompt() {
    local prompt_file="$1"
    local repo_name="$2"
    local repo_path="$3"
    local output_file="$4"
    local thinking_level="${5:-normal}"
    local context="$6"

    {
        case "$thinking_level" in
            hard)
                echo "Think hard about every decision below before acting. Prefer correctness and specificity over speed."
                echo ""
                ;;
            ultra)
                echo "ultrathink"
                echo ""
                echo "Ultra-plan every decision below. Be exhaustive and precise."
                echo ""
                ;;
        esac

        cat << HEADEOF
# Workspace Planning — Repository: ${repo_name}

You are planning work for a SINGLE repository inside a multi-repo workspace.
Your assigned repository is \`${repo_name}\` at \`${repo_path}\`.

## Your Job

1. Read the context files provided below.
2. Explore \`${repo_path}\` as needed for repo-specific understanding.
3. Emit a prioritized task list for ${repo_name}.
4. Flag any ambiguities or unresolved questions.
5. Flag any tasks that cross repository boundaries.

## Output Format — REQUIRED

Write EXACTLY this structure to the file \`${output_file}\` and nothing else:

\`\`\`
## tasks
- First concrete engineering task for ${repo_name}
- Second task
- ...

## ambiguities
- Unclear requirement or missing detail (omit the section if none)

## cross-repo
- Task that touches another repo, prefix with the other repo name when known (omit the section if none)
\`\`\`

Rules:
- One task per line, starting with \`- \`.
- Plain text only. No checkboxes, no IDs, no status markers. The orchestrator adds \`- [ ]\` wrappers.
- Be specific: each task should be something an engineer can start on.
- Do NOT modify any other files. Only write \`${output_file}\`.
- Do NOT modify \`.ralph/fix_plan.md\` — the orchestrator merges your output.

## Repository Context
HEADEOF

        if [[ -n "$context" ]]; then
            echo ""
            echo "$context"
        else
            echo ""
            echo "(no ai/ or .ralph/specs/ content found — explore the repo directly)"
        fi
    } > "$prompt_file"
}

# workspace_plan_run_engine — Drive the AI engine for one repo
# Invokes the selected engine interactively. Engine must write its structured
# output to $output_file per the prompt contract.
#
# If RALPH_PLAN_WS_MOCK_DIR is set (test hook), skips the engine and copies
# "$RALPH_PLAN_WS_MOCK_DIR/<repo_name>.out.md" to $output_file.
#
# Args:
#   $1 - engine (claude|codex|devin)
#   $2 - model (may be empty)
#   $3 - thinking_level (normal|hard|ultra)
#   $4 - repo_name
#   $5 - repo_path
#   $6 - output_file (absolute)
#   $7 - prompt_file (absolute)
#   $8 - yolo_mode (true|false)
# Returns: engine exit code (0 on success)
workspace_plan_run_engine() {
    local engine="$1"
    local model="$2"
    local thinking="$3"
    local repo_name="$4"
    local repo_path="$5"
    local output_file="$6"
    local prompt_file="$7"
    local yolo="${8:-false}"

    # Test hook
    if [[ -n "${RALPH_PLAN_WS_MOCK_DIR:-}" ]]; then
        local mock_src="${RALPH_PLAN_WS_MOCK_DIR}/${repo_name}.out.md"
        if [[ -f "$mock_src" ]]; then
            mkdir -p "$(dirname "$output_file")"
            cp "$mock_src" "$output_file"
            return 0
        fi
        echo "ERROR: mock output missing for ${repo_name}: $mock_src" >&2
        return 1
    fi

    local cli_cmd=""
    case "$engine" in
        claude) cli_cmd="${CLAUDE_CMD:-claude}" ;;
        codex)  cli_cmd="${CODEX_CMD:-codex}" ;;
        devin)  cli_cmd="${DEVIN_CMD:-devin}" ;;
        *)
            echo "ERROR: Unknown engine: $engine" >&2
            return 1
            ;;
    esac

    if ! command -v "$cli_cmd" &>/dev/null; then
        echo "ERROR: $engine CLI ('$cli_cmd') not found" >&2
        return 1
    fi

    local prompt_content
    prompt_content=$(cat "$prompt_file")

    local _saved_pwd="$PWD"
    cd "$repo_path" || return 1

    local exit_code=0
    case "$engine" in
        claude)
            local -a claude_flags=()
            if [[ "$yolo" == "true" ]]; then
                claude_flags+=("--dangerously-skip-permissions")
            else
                claude_flags+=("--permission-mode" "bypassPermissions")
                claude_flags+=("--allowedTools" "Read" "Write" "Glob" "Grep")
            fi
            [[ -n "$model" ]] && claude_flags+=("--model" "$model")
            case "$thinking" in
                hard)  claude_flags+=("--effort" "high") ;;
                ultra) claude_flags+=("--effort" "max") ;;
            esac
            "$cli_cmd" "${claude_flags[@]}" "$prompt_content" || exit_code=$?
            ;;
        codex)
            "$cli_cmd" --dangerously-bypass-approvals-and-sandbox -- "$prompt_content" || exit_code=$?
            ;;
        devin)
            local -a devin_flags=("--permission-mode" "dangerous")
            [[ -n "$model" ]] && devin_flags+=("--model" "$model")
            devin_flags+=("--prompt-file" "$prompt_file")
            "$cli_cmd" "${devin_flags[@]}" || exit_code=$?
            ;;
    esac

    cd "$_saved_pwd" || true

    if [[ $exit_code -ne 0 ]]; then
        return $exit_code
    fi

    if [[ ! -f "$output_file" ]]; then
        echo "ERROR: engine finished but output file was not written: $output_file" >&2
        return 1
    fi

    return 0
}

# workspace_plan_parse_output — Parse an engine output file into labeled lines
# Emits one label per line, prefix TASK|, AMBIG|, CROSS|.
#
# Args:
#   $1 - output_file
# Outputs on stdout:
#   TASK|<text>
#   AMBIG|<text>
#   CROSS|<text>
workspace_plan_parse_output() {
    local output_file="$1"
    [[ -f "$output_file" ]] || return 1

    local section=""
    local line

    while IFS= read -r line; do
        # Section header: ## tasks / ## ambiguities / ## cross-repo (case-insensitive)
        if [[ "$line" =~ ^##[[:space:]]+([A-Za-z_-]+) ]]; then
            local hdr="${BASH_REMATCH[1]}"
            case "$(echo "$hdr" | tr '[:upper:]' '[:lower:]')" in
                tasks)         section="TASK" ;;
                ambiguities)   section="AMBIG" ;;
                cross-repo)    section="CROSS" ;;
                *)             section="" ;;
            esac
            continue
        fi

        [[ -z "$section" ]] && continue

        # Match bullet lines: "- text" or "* text"
        if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.+)$ ]]; then
            local body="${BASH_REMATCH[1]}"
            # Strip any pre-existing checkbox markers the AI may have added.
            body=$(echo "$body" | sed -E 's/^\[[ x~]\][[:space:]]*//')
            # Trim
            body=$(echo "$body" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
            [[ -z "$body" ]] && continue
            echo "${section}|${body}"
        fi
    done < "$output_file"

    return 0
}

# _ws_plan_norm — Normalize a task description for trim-compare
_ws_plan_norm() {
    # Lowercase, collapse whitespace, strip trailing punctuation
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//; s/[[:punct:]]+$//'
}

# workspace_plan_extract_section_range — Find (start_line, end_line) of a section
# Section starts at "## <name>" line, ends before next "## " header or EOF.
# Header line is NOT included in body range.
#
# Args:
#   $1 - fix_plan file
#   $2 - section name (literal, no ## prefix)
# Outputs: "start_body_line end_body_line" (1-based, inclusive) or empty if not found
workspace_plan_extract_section_range() {
    local fix_plan="$1"
    local name="$2"

    awk -v target="$name" '
        BEGIN { in_section=0; start=0; end=0; line=0; printed=0 }
        {
            line++
            if ($0 ~ /^## /) {
                hdr = $0
                sub(/^## */, "", hdr)
                sub(/[[:space:]]+$/, "", hdr)
                if (in_section == 1) {
                    end = line - 1
                    print start " " end
                    printed = 1
                    in_section = 0
                    exit 0
                }
                if (hdr == target) {
                    in_section = 1
                    start = line + 1
                    end = line
                }
            }
        }
        END {
            if (in_section == 1 && printed == 0) {
                end = line
                print start " " end
            }
        }
    ' "$fix_plan"
}

# workspace_plan_merge_repo_section — Merge new tasks into a repo section
# Preserves - [~] and - [x] lines; dedupes new tasks against preserved by trim-compare.
# Writes atomically via .tmp + mv.
#
# Args:
#   $1 - fix_plan file
#   $2 - repo_name (section header, without ##)
#   $3 - new_tasks_file: one task per line, no checkbox prefix
# Output (on stdout): "<new_count> <preserved_count> <in_progress_count> <completed_count>"
workspace_plan_merge_repo_section() {
    local fix_plan="$1"
    local repo_name="$2"
    local new_tasks_file="$3"

    [[ -f "$fix_plan" ]] || { echo "ERROR: fix_plan not found: $fix_plan" >&2; return 1; }
    [[ -f "$new_tasks_file" ]] || { echo "ERROR: new_tasks_file not found: $new_tasks_file" >&2; return 1; }

    local range
    range=$(workspace_plan_extract_section_range "$fix_plan" "$repo_name")

    local header_line_num=""
    local body_start=""
    local body_end=""

    if [[ -n "$range" ]]; then
        body_start=$(echo "$range" | awk '{print $1}')
        body_end=$(echo "$range" | awk '{print $2}')
        header_line_num=$((body_start - 1))
    fi

    # Collect preserved (in-progress / completed) lines from existing body
    local preserved_file
    preserved_file="${fix_plan}.preserved.$$"
    : > "$preserved_file"
    local in_progress_count=0
    local completed_count=0

    if [[ -n "$body_start" && -n "$body_end" && "$body_end" -ge "$body_start" ]]; then
        local ln=0
        while IFS= read -r line; do
            ln=$((ln + 1))
            if [[ $ln -ge $body_start && $ln -le $body_end ]]; then
                if [[ "$line" =~ ^-\ \[~\]\  ]]; then
                    echo "$line" >> "$preserved_file"
                    in_progress_count=$((in_progress_count + 1))
                elif [[ "$line" =~ ^-\ \[x\]\  ]]; then
                    echo "$line" >> "$preserved_file"
                    completed_count=$((completed_count + 1))
                fi
            fi
        done < "$fix_plan"
    fi

    # Build normalized preserved-descriptions list (for dedupe against new)
    local preserved_norm_file
    preserved_norm_file="${fix_plan}.preserved_norm.$$"
    : > "$preserved_norm_file"
    if [[ -s "$preserved_file" ]]; then
        while IFS= read -r line; do
            local desc
            desc=$(echo "$line" | sed -E 's/^-[[:space:]]+\[[ x~]\][[:space:]]+//')
            _ws_plan_norm "$desc" >> "$preserved_norm_file"
        done < "$preserved_file"
    fi

    # Build new-tasks output, filtering duplicates
    local new_tasks_out
    new_tasks_out="${fix_plan}.new.$$"
    : > "$new_tasks_out"
    local new_count=0
    while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        local norm
        norm=$(_ws_plan_norm "$task")
        if [[ -s "$preserved_norm_file" ]] && grep -qxF "$norm" "$preserved_norm_file"; then
            continue
        fi
        echo "- [ ] $task" >> "$new_tasks_out"
        new_count=$((new_count + 1))
    done < "$new_tasks_file"

    # Assemble new section body: preserved first, then new tasks
    local section_body
    section_body="${fix_plan}.body.$$"
    : > "$section_body"
    if [[ -s "$preserved_file" ]]; then
        cat "$preserved_file" >> "$section_body"
    fi
    if [[ -s "$new_tasks_out" ]]; then
        cat "$new_tasks_out" >> "$section_body"
    fi

    # Splice into fix_plan
    local tmp="${fix_plan}.tmp.$$"
    if [[ -n "$header_line_num" ]]; then
        # Replace body range [body_start, body_end] with new section_body
        awk -v hdr="$header_line_num" -v bs="$body_start" -v be="$body_end" -v body="$section_body" '
            BEGIN { emitted=0; ln=0 }
            {
                ln++
                if (ln < bs || ln > be) {
                    print
                    if (ln == hdr) {
                        # Emit replacement body right after header line
                        while ((getline bl < body) > 0) print bl
                        close(body)
                        emitted=1
                    }
                } else {
                    # Skip old body lines (already replaced after header)
                    if (!emitted && ln == be) {
                        while ((getline bl < body) > 0) print bl
                        close(body)
                        emitted=1
                    }
                }
            }
            END {
                if (!emitted) {
                    while ((getline bl < body) > 0) print bl
                    close(body)
                }
            }
        ' "$fix_plan" > "$tmp"
    else
        # Section missing — append at end
        cp "$fix_plan" "$tmp"
        {
            echo ""
            echo "## $repo_name"
            cat "$section_body"
        } >> "$tmp"
    fi

    mv "$tmp" "$fix_plan"

    local preserved_count=$((in_progress_count + completed_count))
    echo "$new_count $preserved_count $in_progress_count $completed_count"

    rm -f "$preserved_file" "$preserved_norm_file" "$new_tasks_out" "$section_body"
    return 0
}

# workspace_plan_append_cross_repo — Append new cross-repo tasks, deduped
# Tasks matching existing (any checkbox state) cross-repo lines are skipped.
#
# Args:
#   $1 - fix_plan file
#   $2 - cross_tasks_file: one task per line
# Outputs: count of tasks appended on stdout
workspace_plan_append_cross_repo() {
    local fix_plan="$1"
    local cross_tasks_file="$2"

    [[ -f "$fix_plan" ]] || { echo "0"; return 1; }
    [[ -f "$cross_tasks_file" ]] || { echo "0"; return 0; }
    [[ -s "$cross_tasks_file" ]] || { echo "0"; return 0; }

    # Gather existing cross-repo line descriptions (normalized)
    local existing_norm
    existing_norm="${fix_plan}.cross_existing.$$"
    : > "$existing_norm"

    local range
    range=$(workspace_plan_extract_section_range "$fix_plan" "cross-repo")

    if [[ -n "$range" ]]; then
        local bs be ln
        bs=$(echo "$range" | awk '{print $1}')
        be=$(echo "$range" | awk '{print $2}')
        ln=0
        while IFS= read -r line; do
            ln=$((ln + 1))
            if [[ $ln -ge $bs && $ln -le $be ]]; then
                if [[ "$line" =~ ^-[[:space:]]+\[[xX\ ~]\][[:space:]]+(.+)$ ]]; then
                    _ws_plan_norm "${BASH_REMATCH[1]}" >> "$existing_norm"
                fi
            fi
        done < "$fix_plan"
    fi

    # Filter new tasks against existing
    local to_append
    to_append="${fix_plan}.cross_append.$$"
    : > "$to_append"
    local appended=0
    while IFS= read -r task; do
        [[ -z "$task" ]] && continue
        local norm
        norm=$(_ws_plan_norm "$task")
        if [[ -s "$existing_norm" ]] && grep -qxF "$norm" "$existing_norm"; then
            continue
        fi
        echo "- [ ] $task" >> "$to_append"
        # Also add to existing_norm so in-batch dupes don't repeat
        echo "$norm" >> "$existing_norm"
        appended=$((appended + 1))
    done < "$cross_tasks_file"

    if [[ $appended -eq 0 ]]; then
        rm -f "$existing_norm" "$to_append"
        echo "0"
        return 0
    fi

    local tmp="${fix_plan}.tmp.$$"
    if [[ -n "$range" ]]; then
        # Insert appended tasks at end of existing cross-repo body
        local bs be
        bs=$(echo "$range" | awk '{print $1}')
        be=$(echo "$range" | awk '{print $2}')
        awk -v be="$be" -v body="$to_append" '
            BEGIN { ln=0; inserted=0 }
            {
                ln++
                print
                if (ln == be && !inserted) {
                    while ((getline bl < body) > 0) print bl
                    close(body)
                    inserted=1
                }
            }
            END {
                if (!inserted) {
                    while ((getline bl < body) > 0) print bl
                    close(body)
                }
            }
        ' "$fix_plan" > "$tmp"
    else
        # Append whole section at end
        cp "$fix_plan" "$tmp"
        {
            echo ""
            echo "## cross-repo"
            cat "$to_append"
        } >> "$tmp"
    fi

    mv "$tmp" "$fix_plan"
    rm -f "$existing_norm" "$to_append"
    echo "$appended"
    return 0
}

# workspace_plan_filter_repos — Filter repo list by comma-separated allowlist
# Args:
#   $1 - all_repos (newline-separated)
#   $2 - filter (comma-separated, may be empty)
# Outputs: filtered repo list on stdout
workspace_plan_filter_repos() {
    local all="$1"
    local filter="$2"

    if [[ -z "$filter" ]]; then
        echo "$all"
        return 0
    fi

    # Build filter set
    local IFS_saved="$IFS"
    IFS=',' read -r -a wanted <<< "$filter"
    IFS="$IFS_saved"

    local repo
    local w
    while IFS= read -r repo; do
        [[ -z "$repo" ]] && continue
        for w in "${wanted[@]}"; do
            # Trim
            w_trim=$(echo "$w" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
            if [[ "$repo" == "$w_trim" ]]; then
                echo "$repo"
                break
            fi
        done
    done <<< "$all"
}

# Export for subshells / test invocation
export -f workspace_plan_preflight
export -f workspace_plan_collect_repo_context
export -f workspace_plan_build_prompt
export -f workspace_plan_run_engine
export -f workspace_plan_parse_output
export -f _ws_plan_norm
export -f workspace_plan_extract_section_range
export -f workspace_plan_merge_repo_section
export -f workspace_plan_append_cross_repo
export -f workspace_plan_filter_repos
