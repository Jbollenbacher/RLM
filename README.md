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

```bash
# Interactive session (default when no args)
mix rlm

# Single-turn query
mix rlm "What is 2 + 2?"

# Pipe input
cat document.txt | mix rlm "Summarize this document"

# File input
mix rlm --file document.txt "Summarize this document"

# Interactive with initial query
mix rlm -i "Start a session"

# Show logs
mix rlm --verbose "What is 2 + 2?"
```

## Architecture

- `RLM.Loop` — Main orchestration loop (REPL driver)
- `RLM.Eval` — Sandboxed code evaluation with IO capture
- `RLM.Sandbox` — Helper functions available to eval'd code (`chunks`, `grep`, `preview`, `lm_query`)
- `RLM.LLM` — OpenAI-compatible API client (via Req)
- `RLM.Truncate` — Head+tail truncation to bound context size
- `RLM.Session` — Multi-turn session wrapper that preserves history and bindings
- `Mix.Tasks.Rlm` — CLI entrypoint (single-turn and interactive sessions)
