# RLM — Recursive Language Model

An Elixir implementation of the Recursive Language Model pattern. The RLM addresses LLM context window limitations by keeping input data out of the context entirely — instead, the LLM writes code in a persistent REPL to inspect, chunk, and recursively process data through sub-LLM calls.

## Core Idea

1. Input is stored in a variable inside an Elixir evaluation environment.
2. The LLM writes Elixir code to operate on that input (slice, search, chunk).
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

# Workspace access (model can list/read/edit/create files under the workspace root)
mix rlm --workspace /path/to/project

# Read-only workspace access
mix rlm --workspace /path/to/project --read-only

# Show logs
mix rlm --verbose "What is 2 + 2?"

# Observability UI (embedded)
mix rlm --observe
# Custom port
mix rlm --observe --observe-port 4005
```

When observability is enabled, the UI is served at `http://127.0.0.1:<port>` and the CLI prints the URL on startup.

## Architecture

- `RLM.Loop` — Main orchestration loop (REPL driver)
- `RLM.Eval` — Sandboxed code evaluation with IO capture
- `RLM.Sandbox` — Helper functions available to eval'd code (`chunks`, `grep`, `preview`, `lm_query`, and optional workspace access helpers)
- `RLM.LLM` — OpenAI-compatible API client (via Req)
- `RLM.Truncate` — Head+tail truncation to bound context size
- `RLM.Session` — Multi-turn session wrapper that preserves history and bindings
- `Mix.Tasks.Rlm` — CLI entrypoint (single-turn and interactive sessions)
