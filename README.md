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
# Install dependencies
mix deps.get

# Set your OpenRouter API key
cp .env.example .env  # then edit .env

# Run tests
mix test

# Run CLI
mix rlm
```

## Architecture

- `RLM.Loop` — Main orchestration loop (REPL driver)
- `RLM.Eval` — Sandboxed code evaluation with IO capture
- `RLM.Sandbox` — Helper functions available to eval'd code (`chunks`, `grep`, `preview`, `lm_query`)
- `RLM.LLM` — OpenAI-compatible API client (via Req)
- `RLM.Truncate` — Head+tail truncation to bound context size
