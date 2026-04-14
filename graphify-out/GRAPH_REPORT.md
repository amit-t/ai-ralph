# Graph Report - .  (2026-04-14)

## Corpus Check
- 38 files · ~59,356 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 153 nodes · 194 edges · 18 communities detected
- Extraction: 84% EXTRACTED · 16% INFERRED · 0% AMBIGUOUS · INFERRED: 32 edges (avg confidence: 0.83)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Core Infrastructure & Multi-Engine|Core Infrastructure & Multi-Engine]]
- [[_COMMUNITY_Project History & Codex Integration|Project History & Codex Integration]]
- [[_COMMUNITY_Agent Core Architecture|Agent Core Architecture]]
- [[_COMMUNITY_Examples & Agent Quality Standards|Examples & Agent Quality Standards]]
- [[_COMMUNITY_Session Templates & Conventions|Session Templates & Conventions]]
- [[_COMMUNITY_Testing Infrastructure|Testing Infrastructure]]
- [[_COMMUNITY_Plan File Aliases & Status|Plan File Aliases & Status]]
- [[_COMMUNITY_Automatic PR Creation|Automatic PR Creation]]
- [[_COMMUNITY_CLI Security & Compatibility|CLI Security & Compatibility]]
- [[_COMMUNITY_Response Analysis Architecture|Response Analysis Architecture]]
- [[_COMMUNITY_Planning Mode & Execution Modes|Planning Mode & Execution Modes]]
- [[_COMMUNITY_CLI Parsing Tests Review|CLI Parsing Tests Review]]
- [[_COMMUNITY_Global Installer|Global Installer]]
- [[_COMMUNITY_Project Setup|Project Setup]]
- [[_COMMUNITY_Bash Requirements|Bash Requirements]]
- [[_COMMUNITY_Contribution Workflow|Contribution Workflow]]
- [[_COMMUNITY_PR Process|PR Process]]
- [[_COMMUNITY_Human Developer Actor|Human Developer Actor]]

## God Nodes (most connected - your core abstractions)
1. `fix_plan.md — Task List File` - 13 edges
2. `AI Ralph Project` - 12 edges
3. `Implementation Status v0.9.8` - 11 edges
4. `Understanding Ralph Files Guide` - 10 edges
5. `Ralph Auto-PR Design Spec` - 10 edges
6. `ralph_loop.sh Main Script` - 8 edges
7. `Fix Plan Status Implementation Plan` - 8 edges
8. `Fix Plan Status Design Spec` - 8 edges
9. `AGENTS.md Core Architecture Overview` - 7 edges
10. `PROMPT.md — Project Vision File` - 7 edges

## Surprising Connections (you probably didn't know these)
- `Constitution — Cross-session Project Memory and Architecture Decisions` --semantically_similar_to--> `PROMPT.md — Project Vision File`  [INFERRED] [semantically similar]
  templates/constitution.md → docs/user-guide/02-understanding-ralph-files.md
- `codex/ralph_loop_codex.sh` --semantically_similar_to--> `ralph_loop.sh Main Script`  [INFERRED] [semantically similar]
  codex/IMPLEMENTATION_SUMMARY.md → README.md
- `Intelligent Exit Detection` --semantically_similar_to--> `Question Detection detect_questions()`  [INFERRED] [semantically similar]
  README.md → AGENTS.md
- `BATS Bash Automated Testing System` --conceptually_related_to--> `Historical Status 75 Tests Oct 2025`  [INFERRED]
  TESTING.md → docs/archive/2025-10-milestones/STATUS.md
- `Three Amigos Specification Workshop` --semantically_similar_to--> `Phase 2 Given/When/Then Exit Scenarios`  [INFERRED] [semantically similar]
  SPECIFICATION_WORKSHOP.md → docs/archive/2025-10-milestones/PHASE2_COMPLETION.md

## Hyperedges (group relationships)
- **Autonomous Loop Core Components** — readme_ralph_loop_sh, agents_md_circuit_breaker_lib, agents_md_response_analyzer_lib, readme_exit_detection, readme_rate_limiting [INFERRED 0.90]
- **Multi-Engine Architecture (Claude, Devin, Codex)** — readme_claude_engine, readme_devin_engine, readme_codex_engine, readme_airalph, readme_git_worktree_isolation [EXTRACTED 0.95]
- **Expert Panel Driven Architecture Decisions** — expert_panel_martin_fowler, expert_panel_michael_nygard, phase1_completion_response_analyzer, agents_md_circuit_breaker_lib [EXTRACTED 0.92]
- **Ralph .ralph/ File Hierarchy — PROMPT.md, specs/, fix_plan.md, AGENT.md Collaboration** — ralph_files_prompt_md, ralph_files_specs_dir, ralph_files_fix_plan_md, ralph_files_agent_md [EXTRACTED 0.97]
- **Fix Plan Status Feature — Design, Library, ralph_plan Flag, and Aliases** — fix_plan_status_design, fix_plan_status_lib, ralph_plan_status_mode, alias_rpc_plan_s, alias_rpx_plan_s, alias_rpd_plan_s [EXTRACTED 0.95]
- **Auto-PR Workflow — pr_manager Functions Collectively Implement End-of-Run PR Creation** — pr_preflight_check_fn, pr_build_title_fn, pr_build_description_fn, worktree_commit_and_pr_fn, worktree_fallback_branch_pr_fn [EXTRACTED 0.95]

## Communities

### Community 0 - "Core Infrastructure & Multi-Engine"
Cohesion: 0.08
Nodes (28): lib/circuit_breaker.sh Three-State Pattern, PR Target amit-t/ai-ralph, CLAUDE.md Repository Instructions, codex/lib/codex_adapter.sh, codex/ralph_loop_codex.sh, Ralph for Codex Implementation Summary, codex/lib/worktree_manager.sh, Michael Nygard Circuit Breaker Recommendation (+20 more)

### Community 1 - "Project History & Codex Integration"
Cohesion: 0.09
Nodes (23): October 2025 Milestones Archive, Historical Status 75 Tests Oct 2025, Ralph for Codex Feature Overview, .ralphrc.codex Configuration, Dry-run Mode Feature, Hybrid CLI/SDK Architecture Plan, Log Rotation Feature, .ralphrc Project Configuration File (+15 more)

### Community 2 - "Agent Core Architecture"
Cohesion: 0.12
Nodes (17): AGENTS.md Core Architecture Overview, Question Detection detect_questions(), ralph_enable_ci.sh Non-Interactive, ralph_enable.sh Interactive Wizard, lib/response_analyzer.sh Intelligent Analysis, Session Management .claude_session_id, Phase 2 Given/When/Then Exit Scenarios, Gojko Adzic Specification by Example (+9 more)

### Community 3 - "Examples & Agent Quality Standards"
Cohesion: 0.21
Nodes (17): Feature Development Quality Standards — 85% Coverage, CI/CD, Example: REST API with Specifications, Example: Simple CLI Tool (minimal Ralph config), AGENT.md — Build Instructions File, fix_plan.md — Task List File, .ralph/logs/ — Execution Logs Directory, PROMPT.md — Project Vision File, .ralphrc — Project Configuration File (+9 more)

### Community 4 - "Session Templates & Conventions"
Cohesion: 0.22
Nodes (13): Ad-hoc Task ID Format (AHXX) — Task Reference System, Circuit Breaker — Stuck Loop Detection Mechanism, Compression Rules — Lossless fix_plan.md Compaction, Constitution — Cross-session Project Memory and Architecture Decisions, EXIT_SIGNAL — Loop Termination Signal, Planning Mode Input Sources — PM-OS, DoE-OS, PRDs, Beads, RALPH_STATUS Block — Loop Status Reporting Protocol, constitution.md Template — Project Memory and Architecture (+5 more)

### Community 5 - "Testing Infrastructure"
Cohesion: 0.24
Nodes (10): Test Infrastructure Week 1 Deliverables, bats-assert Assertion Library, BATS Bash Automated Testing System, E2E Tests (Planned), tests/helpers/fixtures.bash, GitHub Actions CI/CD Pipeline, Integration Tests Directory, tests/helpers/mocks.bash (+2 more)

### Community 6 - "Plan File Aliases & Status"
Cohesion: 0.4
Nodes (10): rpc.plan.s Alias — Fix Plan Status (Claude), rpd.plan.s Alias — Fix Plan Status (Devin), rpx.plan.s Alias — Fix Plan Status (Codex), Fix Plan Status Design Spec, find_fix_plan() — Walk-up CWD Search Function, lib/fix_plan_status.sh — Fix Plan Walk-up and AI Status, Fix Plan Status Implementation Plan, show_fix_plan_status() — AI Analysis Invocation Function (+2 more)

### Community 7 - "Automatic PR Creation"
Cohesion: 0.4
Nodes (10): Ralph Auto-PR Design Spec, Ralph Auto-PR Implementation Plan, pr_build_description() — Build PR Markdown Body, pr_build_title() — Build PR Title from Task, lib/pr_manager.sh — Shared PR Library, pr_preflight_check() — Validate PR Prerequisites, Quality Gate Retry Behaviour — Keep Worktree Alive on Failure, Rationale: Replace Direct Merge with PR for Audit Trail and Code Review Gate (+2 more)

### Community 8 - "CLI Security & Compatibility"
Cohesion: 0.29
Nodes (8): Backward Compatibility — JSON-to-Text Fallback, MAJOR-01: Command Injection Vulnerability in build_claude_command(), MAJOR-02: Missing Input Validation for CLAUDE_ALLOWED_TOOLS, MAJOR-03: No Rate Limiting for Session Persistence, MINOR-01: JSON Parsing Uses Intermediate File, MINOR-04: Version Comparison Doesn't Handle Pre-release Versions, 43 New Tests — 100% Pass Rate (Phase 1.1), Code Review: Phase 1.1 Modern CLI Commands

### Community 9 - "Response Analysis Architecture"
Cohesion: 0.5
Nodes (5): Martin Fowler SRP Architecture Critique, ResponseAnalyzer Feedback Loop Requirement, lib/response_analyzer.sh, Confidence Scoring System (0-100+), Phase 1 Response Analysis Pipeline

### Community 10 - "Planning Mode & Execution Modes"
Cohesion: 0.5
Nodes (4): --adhoc Ad-hoc Task Mode, --compress Mode for fix_plan.md, PM-OS / DoE-OS Auto-Detection, ralph_plan.sh Planning Mode

### Community 11 - "CLI Parsing Tests Review"
Cohesion: 1.0
Nodes (2): CLI Parsing Tests — test_cli_parsing.bats, Code Review: CLI Parsing Tests

### Community 12 - "Global Installer"
Cohesion: 1.0
Nodes (1): install.sh Global Installer

### Community 13 - "Project Setup"
Cohesion: 1.0
Nodes (1): setup.sh Project Initialization

### Community 14 - "Bash Requirements"
Cohesion: 1.0
Nodes (1): Bash 4.0+ Prerequisite

### Community 15 - "Contribution Workflow"
Cohesion: 1.0
Nodes (1): Development Workflow Branch Conventions

### Community 16 - "PR Process"
Cohesion: 1.0
Nodes (1): Pull Request Process

### Community 17 - "Human Developer Actor"
Cohesion: 1.0
Nodes (1): Human Developer Actor

## Knowledge Gaps
- **64 isolated node(s):** `Geoffrey Huntley's Ralph Technique`, `Devin CLI Engine`, `Codex CLI Engine`, `Automatic PR Creation`, `Parallel Agent Spawning` (+59 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `CLI Parsing Tests Review`** (2 nodes): `CLI Parsing Tests — test_cli_parsing.bats`, `Code Review: CLI Parsing Tests`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Global Installer`** (1 nodes): `install.sh Global Installer`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Project Setup`** (1 nodes): `setup.sh Project Initialization`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Bash Requirements`** (1 nodes): `Bash 4.0+ Prerequisite`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Contribution Workflow`** (1 nodes): `Development Workflow Branch Conventions`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `PR Process`** (1 nodes): `Pull Request Process`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Human Developer Actor`** (1 nodes): `Human Developer Actor`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `fix_plan.md — Task List File` connect `Examples & Agent Quality Standards` to `Session Templates & Conventions`, `Plan File Aliases & Status`?**
  _High betweenness centrality (0.069) - this node is a cross-community bridge._
- **Why does `Implementation Status v0.9.8` connect `Project History & Codex Integration` to `Response Analysis Architecture`?**
  _High betweenness centrality (0.049) - this node is a cross-community bridge._
- **Why does `ralph_loop.sh Main Script` connect `Core Infrastructure & Multi-Engine` to `Agent Core Architecture`?**
  _High betweenness centrality (0.047) - this node is a cross-community bridge._
- **What connects `Geoffrey Huntley's Ralph Technique`, `Devin CLI Engine`, `Codex CLI Engine` to the rest of the system?**
  _64 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Core Infrastructure & Multi-Engine` be split into smaller, more focused modules?**
  _Cohesion score 0.08 - nodes in this community are weakly interconnected._
- **Should `Project History & Codex Integration` be split into smaller, more focused modules?**
  _Cohesion score 0.09 - nodes in this community are weakly interconnected._
- **Should `Agent Core Architecture` be split into smaller, more focused modules?**
  _Cohesion score 0.12 - nodes in this community are weakly interconnected._