# RLM Repository Map and Architecture

This document maps the repository structure and explains how runtime architecture works today.
It starts from the high-level contract in `README.md` and then drills into code-level responsibilities.

## 1. What This Repo Builds

RLM (Recursive Language Model) is an Elixir-hosted recursive agent loop:

- The model answers by writing Python code blocks.
- Python executes in a persistent REPL (`Pythonx`), with state preserved across turns.
- The model can dispatch recursive subagents with `lm_query(...)`.
- Context growth is controlled through truncation and history compaction.
- Optional web observability provides agent trees, events, context snapshots, and chat control.

## 2. Top-Level Repo Map

- `README.md`
  - Setup, CLI usage, web UI usage, and top-level architecture summary.
- `mix.exs`, `mix.lock`
  - App/deps and OTP application start.
- `config/`
  - Compile/runtime configuration and env overrides.
- `lib/`
  - Core runtime: loop, eval, LLM transport, recursion, observability, CLI task.
- `priv/`
  - System prompt, Python prelude helpers, observability UI HTML shell, and split observability JS app parts under `priv/observability_ui/`.
- `test/`
  - Unit + contract tests, with integration tests behind `RLM_RUN_INTEGRATION`.
- `docs/`
  - Architecture/reference docs (includes this architecture map plus supporting assessment notes).
- `bench/`
  - Assessment-driven benchmark manifests/profiles/templates and tracked prompt variants.
- `bench_data/` (gitignored)
  - Pulled corpora, generated task contexts/pools, run logs/exports, AB reports, and optimizer sessions.
- `workspace/`
  - Example/project-local workspace content used by workspace helper flows.
- `_build/`, `deps/`
  - Build artifacts and dependencies.

## 3. Runtime Entry Points

### 3.1 OTP Application

- `lib/rlm/application.ex`
  - Starts:
    - `RLM.AgentLimiter`
    - `RLM.Subagent.Broker`
    - `Finch` (`RLM.Finch`) HTTP client pool

### 3.2 Public API

- `lib/rlm.ex`
  - `RLM.run/3` is the main programmatic entrypoint.
  - Creates a session, runs one `ask`, catches exceptions, cancels remaining child jobs, emits final agent-end observability event.

### 3.3 CLI

- `lib/mix/tasks/rlm.ex`
  - Supports:
    - one-shot query
    - interactive loop
    - workspace mode (`--workspace`, optional `--read-only`)
    - web mode (`--web`, `--web-port`)
    - export logs mode (`--export-logs`, `--export-logs-path`)
    - export-log view control (`--export-logs-debug` for debug/full event export)
    - logger controls (`--verbose`, `--debug`)
  - Reads stdin context and query positional args.
  - Export path behavior is defensive: if full-log export fails, CLI warns on stderr and preserves the task result path instead of crashing.
- `lib/mix/tasks/rlm.bench.*.ex`
  - Assessment optimization pipeline:
    - corpus pull-down (`rlm.bench.pull`)
    - task generation (`rlm.bench.build`)
    - quiet benchmark run + log capture (`rlm.bench.run`)
    - run comparison (`rlm.bench.ab`)
    - autonomous prompt-only optimization loop (`rlm.bench.optimize`)
    - saved log inspection (`rlm.bench.logs`)
  - Benchmark task subprocesses are executed with `MIX_NO_COMPILE=1` to reduce per-task compile churn.

### 3.4 Web UI/HTTP

- `lib/rlm/observability/router.ex`
  - Serves UI (`/`) and JSON endpoints:
    - agent list/detail/context (`/api/agents`, `/api/agents/:id`, `/api/agents/:id/context`)
    - event feed (`/api/events`) with normal/debug filtering support
    - full-log export (`/api/export/full_logs`)
    - single-session chat (`/api/chat`, `/api/chat/stop`)

### 3.5 Execution Flows (At a Glance)

Single-turn CLI flow:

1. `mix rlm "query"` (`Mix.Tasks.Rlm.run/1`)
2. `RLM.run/3` (`lib/rlm.ex`)
3. `RLM.Session.start/2` + `RLM.Session.ask/2`
4. `RLM.Loop.run_turn/6` iterative cycle
5. `RLM.LLM.chat/4` -> `RLM.Eval.eval/3` -> feedback loop
6. finalize via `final_answer` contract (or error)
7. print result and optionally export logs (`--export-logs` or `--export-logs-path`)

Web chat flow:

1. `mix rlm --web` starts observability supervisor (+ chat process + Bandit)
2. browser calls `/api/chat` -> `RLM.Observability.Chat.ask/2`
3. chat process delegates to `RLM.Session.ask/2`
4. loop/eval/llm path is the same as CLI
5. UI polls `/api/chat`, `/api/agents`, `/api/events`, `/api/agents/:id/context`

## 4. Core Agent Architecture

### 4.1 Session Layer

- `lib/rlm/session.ex`
  - Owns per-agent state:
    - chat history
    - persistent eval bindings
    - config/model/depth
  - Initializes system prompt message.
  - Appends principal/agent turns to persisted `context` transcript.
  - Builds first-turn vs follow-up principal prompt framing.
  - Wraps each `ask` in `AgentLimiter.with_slot(...)`.

### 4.2 Main Loop

- `lib/rlm/loop.ex`
  - Iterative turn engine (`run_turn` -> `iterate`) and high-level control flow.
  - Delegates focused responsibilities to:
    - `lib/rlm/loop/compaction.ex` (`RLM.Loop.Compaction`)
    - `lib/rlm/loop/subagent_return.ex` (`RLM.Loop.SubagentReturn`)
    - `lib/rlm/loop/eval_feedback.ex` (`RLM.Loop.EvalFeedback`)
    - `lib/rlm/loop/finalization.ex` (`RLM.Loop.Finalization`)
  - Per iteration:
    1. Resolve staged/finalization gates (`RLM.Loop.Finalization`).
    2. Optional compaction if estimated context size exceeds threshold.
    3. Inject `[SUBAGENT_RETURN]` updates from broker.
    4. Snapshot context for observability.
    5. Call LLM chat completion.
    6. Extract last executable code block.
    7. Execute via `RLM.Eval`.
    8. Feed truncated stdout/stderr/result back as `[REPL][AGENT]` message (unless intentionally suppressed when final answer already captured and no output changed).
    9. Continue or finalize based on `final_answer` and assessment rules.
  - Handles repeated no-code behavior by one nudge + hard failure on repeat, and check-in turns explicitly require executable Python.

### 4.3 Finalization and Check-In Gates

- `lib/rlm/loop/finalization.ex`
  - Implements staged completion behavior for sampled quality flows:
    - Dispatch assessment check-in (`assess_dispatch`) for sampled subagents.
    - Subagent assessment check-in (`assess_lm_query`) for sampled child jobs.
  - Important behavior:
    - Final answer can be staged.
    - Runtime allows one short check-in window.
    - If still missing, runtime finalizes with "missing assessment" events.

### 4.4 LLM Transport

- `lib/rlm/llm.ex`
  - Uses `Req` + `Finch` to call OpenAI-compatible `POST /chat/completions`.
  - Retries transient failures.
  - Extracts executable code from fenced Python blocks first, then `<python>...</python>` tags, then clearly code-like unfenced fallbacks when needed.
  - Emits observability span metadata (model, tail context preview, sizes).

## 5. Python Eval Boundary

### 5.1 Eval Engine

- `lib/rlm/eval.ex`
  - Runs Python code in separate spawned process.
  - Prepends `priv/python_prelude.py`.
  - Captures stdout/stderr with `StringIO`.
  - Persists updated globals back into bindings (`:python_globals`).
  - Normalizes `final_answer` and dispatch assessment from Python globals.
  - Enforces eval timeout and returns bindings unchanged on failure.

### 5.2 Bridge and Async Subagents

- `lib/rlm/eval/bridge.ex`
  - File-based IPC bridge in temp dir:
    - Python writes request JSON.
    - Elixir bridge loop handles dispatch/poll/cancel/assess.
    - Bridge writes response JSON atomically.
  - Chooses sampled assessments probabilistically via configured sample rate.

### 5.3 Term/Output Normalization

- `lib/rlm/eval/codec.ex`
  - Decodes Python terms.
  - Normalizes accepted `final_answer` formats.
  - Normalizes dispatch assessment payloads.
  - Reassembles captured output chunk buffers.

### 5.4 Python Prelude Contract

- `priv/python_prelude.py`
  - Injected helpers include:
    - `grep`, `list_bindings`, `latest_principal_message`
    - async subagent helpers: `lm_query`, `poll_lm_query`, `await_lm_query`, `cancel_lm_query`, `assess_lm_query`
    - dispatch-quality helper: `assess_dispatch`
    - workspace helpers: `ls`, `read_file`, `edit_file`, `create_file`
    - final-answer helpers: `ok`, `fail`
  - Many helpers also expose explicit status variants (for branch-safe checks): `*_status` returning `("ok", payload)` or `("error", reason)`.
  - Workspace helpers enforce workspace-root confinement and read-only/write constraints.
  - Rebinds `print`/stdout/stderr for controlled capture.

## 6. Recursion, Concurrency, and Subagent Lifecycle

### 6.1 Dispatch Construction

- `RLM.Loop.build_lm_query/5` (in `lib/rlm/loop.ex`)
  - Creates per-session callable `lm_query` function.
  - Enforces recursion depth (`max_depth`).
  - Emits child-dispatch event with preview metadata.
  - Spawns child by calling `RLM.run/3` with incremented depth.

### 6.2 Global Concurrency Limiting

- `lib/rlm/agent_limiter.ex`
  - Process-aware permit counting.
  - `with_slot(max, fn -> ... end)` wraps top-level ask work.
  - Returns actionable error string if max reached.
  - Cleans permits if owner process dies.

### 6.3 Async Job Broker

- `lib/rlm/subagent/broker.ex`
  - Tracks job state keyed by `{parent_id, child_id}`.
  - Maintains parent-to-child index (`by_parent`) for efficient parent-scoped scans and drains.
  - Supports dispatch/poll/cancel/assess and batched update drains.
  - Enforces configurable per-parent job limits (`subagent_broker_max_jobs_per_parent`, default `2000`).
  - Assessment semantics:
    - required only if sampled + polled + terminal
  - Push update semantics:
    - one completion update
    - one assessment reminder update after terminal poll
  - Parent cleanup:
    - `cancel_all(parent_id)` on agent end.

## 7. Prompting, Truncation, and Compaction

- `lib/rlm/prompt.ex`
  - System/user message builders.
  - Nudge templates for no-code, invalid final answer, and assessment check-ins (including explicit executable-code requirements during check-ins).
  - Eval feedback formatter with recovery hints.
- `priv/system_prompt.md`
  - Behavioral contract for the recursive coding agent, including the strict executable-Python-per-turn expectation.
- `lib/rlm/truncate.ex`
  - Generic head/tail truncator used across REPL output, previews, and snapshots.
- Compaction behavior (`RLM.Loop.Compaction.maybe_compact/5`, surfaced through `RLM.Loop.maybe_compact/5`)
  - Serializes old history to `compacted_history` binding.
  - Replaces active history with system + compacted-history addendum prompt.

## 8. Observability Architecture

### 8.1 Enable/Emit API

- `lib/rlm/observability.ex`
  - Starts observability supervisor and telemetry handlers.
  - Gates all event emission behind a persistent enabled flag.

### 8.2 Process Topology

- `lib/rlm/observability/supervisor.ex`
  - Starts:
    - `RLM.Observability.Store`
    - `RLM.Observability.AgentWatcher`
    - optional `RLM.Observability.Chat`
    - optional `Bandit` HTTP endpoint

### 8.3 Telemetry -> Tracker -> Store Pipeline

- `lib/rlm/observability/telemetry.ex`
  - Handles telemetry event families (`agent`, `iteration`, `llm`, `eval`, compaction, lm_query, assessments).
- `lib/rlm/observability/tracker.ex`
  - Converts events to persistent model updates and snapshots.
- `lib/rlm/observability/log_view.ex`
  - Defines normal vs debug event visibility policy for API/UI/export consumers.
- `lib/rlm/observability/store.ex`
  - ETS-backed in-memory store for:
    - agents
    - event stream (cursor by `{ts, id}`)
    - context snapshots
  - Enforces max retention limits per agent and global agent count.
  - Note: timing events are recorded from stop events; start events exist for spans but are not all persisted as separate timeline entries.

### 8.4 Chat + Web UI

- `lib/rlm/observability/chat.ex`
  - Single-session chat state machine for web console.
  - Supports interrupt/stop and status emissions.
- `lib/rlm/observability/ui.ex`
  - Builds embedded UI HTML by injecting a bundled JS payload from sorted `priv/observability_ui/*.js`.
- `priv/observability_ui.html`
  - Embedded UI shell with:
    - chat panel
    - agent tree
    - events feed + detail pane
    - context window view
    - full log preview/export
    - resizable panel splitters
- `priv/observability_ui/`
  - Split client JS sources (`00_layout.js`, `10_agents_events.js`, `20_chat.js`, `30_export.js`, `40_init.js`) concatenated by `RLM.Observability.UI`.

### 8.5 Export Model

- `lib/rlm/observability/export.ex`
  - Builds nested `rlm_agent_log_v1` document.
  - Applies normal/debug log filtering policy via `RLM.Observability.LogView`.
  - Embeds child agents beneath parent `lm_query` timeline events.
  - Stores context windows as delta-encoded transcript progression.

## 9. Configuration Map

### 9.1 Base Config

- `config/config.exs`
  - Defaults for API, models, recursion limits, truncation sizes, timeouts, sampling, HTTP pools, observability snapshot limits.
  - Python runtime pin for `pythonx` uv init (`==3.13.*`).

### 9.2 Runtime Env Overrides

- `config/runtime.exs`
  - Loads `.env` if present.
  - Supports env overrides for key runtime knobs:
    - endpoint/key/models
    - iteration/depth limits
    - truncation
    - eval/lm_query timeout
    - subagent assessment sample rate

### 9.3 Environment-Specific Files

- `config/dev.exs`, `config/test.exs`, `config/prod.exs`
  - Currently minimal (`import Config` only).

### 9.4 Benchmark Variant Prompt Override

- `RLM_SYSTEM_PROMPT_PATH`
  - Optional runtime override for loading a full system prompt variant from an explicit file path.
  - Used by benchmark/optimizer runs to compare prompt variants without editing `priv/system_prompt.md`.

## 10. Test Coverage Map

Integration tests run only when:

- `RLM_RUN_INTEGRATION=1 mix test`

(`test/test_helper.exs` excludes `:integration` by default.)

Key test groups:

- Loop/session recursion behavior:
  - `test/rlm/loop_test.exs`
  - `test/rlm/recursion_test.exs`
  - `test/rlm/session_test.exs`
- Eval/prompt/final-answer contracts:
  - `test/rlm/eval_test.exs`
  - `test/rlm/prompt_test.exs`
  - `test/rlm/final_answer_contract_test.exs`
- Concurrency and broker semantics:
  - `test/rlm/agent_limiter_test.exs`
  - `test/rlm/max_concurrent_agents_test.exs`
  - `test/rlm/subagent_broker_test.exs`
  - `test/rlm/dispatch_assessment_contract_test.exs`
- Observability stack:
  - `test/rlm/observability_store_test.exs`
  - `test/rlm/observability_router_test.exs`
  - `test/rlm/observability_export_test.exs`
  - `test/rlm/observability_agent_watcher_test.exs`
- Smaller utility coverage:
  - `test/rlm/truncate_test.exs`
  - `test/rlm/llm_test.exs`
  - `test/rlm/helpers_test.exs`

## 11. Non-Runtime/Reference Assets

- `docs/cli-worker-agent-assessment-2026-02-13.md`
  - Research memo on external CLI worker options; not part of runtime.
- `workspace/`
  - Example files used for workspace-access experiments and testing.

## 12. Architecture Summary

The current architecture cleanly separates:

- orchestration (`Session` + `Loop` + `Finalization`)
- execution boundary (`Eval` + Python prelude + bridge)
- recursive coordination (`AgentLimiter` + `Subagent.Broker`)
- transport (`LLM`)
- observability (`Telemetry`/`Tracker`/`Store` + Web UI)

This gives a testable recursive agent runtime where:

- model reasoning is code-mediated,
- recursion is explicit and bounded,
- completion is gated by enforceable final-answer/assessment contracts,
- and runtime behavior is inspectable through built-in observability and export.

## 13. Fact-Check Watchlist (For Future Updates)

These are the highest-value re-checks when code changes:

- CLI flags and mode-switch semantics in `lib/mix/tasks/rlm.ex`
  - verify docs still match supported flags (`--web`, `--workspace`, `--read-only`, `--export-logs`, etc.)
- Loop finalization contracts in `lib/rlm/loop.ex` and `lib/rlm/loop/finalization.ex`
  - confirm no-code retry behavior, staged final answers, and one-turn check-in behavior
- Prelude helper surface in `priv/python_prelude.py`
  - confirm helper names, read/write workspace behavior, and status-helper contracts
- Subagent lifecycle semantics in `lib/rlm/subagent/broker.ex`
  - confirm when assessments are required and how update drains behave
- Observability event persistence rules in `lib/rlm/observability/telemetry.ex`, `lib/rlm/observability/log_view.ex`, `lib/rlm/observability/store.ex`
  - confirm which events are recorded, filtered, and exported
- Integration-test gate in `test/test_helper.exs`
  - confirm whether `:integration` is still opt-in via `RLM_RUN_INTEGRATION`
