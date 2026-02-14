# RLM — Recursive Language Model

An Elixir-hosted implementation of the Recursive Language Model pattern. The RLM addresses LLM context window limitations by keeping input data out of the context entirely — instead, the LLM writes Python code in a persistent REPL to inspect, chunk, and recursively process data through sub-LLM calls.

## Core Idea

1. Input is stored in a variable inside a Python evaluation environment.
2. The LLM writes Python code to operate on that input (slice, search, chunk).
3. The LLM can invoke **recursive sub-LLMs** on pieces of the input.
4. The LLM's context window only ever contains its own code and truncated execution output.

This means reasoning scales through recursion and decomposition, not through larger context windows.

## Setup

```bash
# Clone the repo
git clone https://github.com/Jbollenbacher/RLM.git
cd RLM

# Install dependencies
mix deps.get

# Set your OpenRouter API key
cp .env.example .env  # then edit .env

# Run tests
mix test

# Run live-model integration tests
RLM_RUN_INTEGRATION=1 mix test
```

## CLI

The Mix task exposes a simple CLI for single-turn and multi-turn sessions.
Principal messages are appended to `context`, and the model responds to the latest principal message inside that context.
The input preview includes both the head and tail of `context` so the latest turn is visible.

```bash
# Chat with RLM
mix rlm

# Single turn query
mix rlm "What is 2 + 2?"

# Single turn with piped input
cat document.txt | mix rlm "Summarize this document"

# Single turn + save full agent logs export JSON (headless, no web UI)
mix rlm --single-turn --export-logs "Analyze this file"
# Optional custom export path (file or directory)
mix rlm --single-turn --export-logs-path ./logs "Analyze this file"

# Workspace access (model can list/read/edit/create files under the workspace root)
mix rlm --workspace /path/to/project

# Read-only workspace access
mix rlm --workspace /path/to/project --read-only

# Show logs
mix rlm --verbose "What is 2 + 2?"

# Web chat UI
mix rlm --web
# Custom port
mix rlm --web --web-port 4005
```

## Web UI

`mix rlm --web` starts a single-session web chat experience with observability built in:

- Chat panel and observability panels shown side-by-side
- Context window, agent tree, and event feed visible during execution
- Toggle system-prompt visibility in context snapshots
- Toggle normal/debug event views in the event feed
- Copy current context and preview/export full nested agent logs
- Resizable panel boundaries for layout control
- `Enter` sends chat, `Shift+Enter` inserts a newline
- `Stop` interrupts the current generation and records a principal interruption note


## Architecture

For a full repo walkthrough, see the architecture map:

- [`docs/repo-architecture-map.md`](docs/repo-architecture-map.md)

Quick module overview:

- `RLM.Loop` — Main orchestration loop (REPL driver)
- `RLM.Loop.Compaction` — Context-window threshold compaction and compacted-history binding updates
- `RLM.Loop.SubagentReturn` — `[SUBAGENT_RETURN]` message construction/injection from broker updates
- `RLM.Loop.EvalFeedback` — Eval invocation + `[REPL][AGENT]` feedback shaping
- `RLM.Loop.Finalization` — Dispatch/subagent assessment staging and check-in finalization gates
- `RLM.Eval` — Pythonx-backed code evaluation with IO capture
- `RLM.Eval` prelude — Helper functions available to eval'd code (`grep`, async `lm_query` with `poll_lm_query`/`await_lm_query`/`cancel_lm_query`, `assess_lm_query`, and optional workspace access helpers)
- `RLM.LLM` — OpenAI-compatible API client (via Req)
- `RLM.Truncate` — Head+tail truncation to bound context size
- `RLM.Session` — Multi-turn session wrapper that preserves history and bindings
- `RLM.Observability.Router`/`RLM.Observability.UI` — Embedded web observability API + HTML shell with JS parts loaded from `priv/observability_ui/*.js`
- `Mix.Tasks.Rlm` — CLI entrypoint (single-turn and interactive sessions)

## Benchmark Optimization Harness

The repo now includes an assessment-driven benchmark harness under `bench/` and `mix rlm.bench.*` tasks.
It optimizes prompt variants using internal delegation assessments, not external answer keys.

```bash
# 1) Pull benchmark source corpus into gitignored bench_data/raw/
mix rlm.bench.pull

# 2) Build delegation-heavy benchmark task pool
mix rlm.bench.build --profile bench/profiles/optimize_v1.json

# 3) Run a quiet benchmark batch (logs saved per task)
mix rlm.bench.run \
  --tasks bench_data/tasks/pool_v1.jsonl \
  --variant bench/variants/champion_v1.md \
  --limit 12 \
  --quiet

# 4) Compare two runs (assessment objective + coverage thresholds)
mix rlm.bench.ab --run-a <run_id_a> --run-b <run_id_b>

# 5) Run autonomous prompt-only optimization cycles
mix rlm.bench.optimize \
  --tasks bench_data/tasks/pool_v1.jsonl \
  --base-variant bench/variants/champion_v1.md \
  --cycles 10
```

Quiet mode suppresses per-task subprocess output and writes logs to:
- `bench_data/runs/<run_id>/task_logs/<task_id>.log`
- `bench_data/runs/<run_id>/task_logs/<task_id>.meta.json`

Benchmark runs export debug/full event logs by default, and optimizer cycles can automatically inspect weak runs to surface failure patterns before the next prompt tweak.

Inspect a saved logfile tail without rerunning:

```bash
mix rlm.bench.logs --run-id <run_id> --task <task_id> --tail 120
```
