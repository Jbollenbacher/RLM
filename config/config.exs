import Config

config :rlm,
  api_base_url: "https://openrouter.ai/api/v1",
  api_key: nil,
  model_large: "qwen/qwen3-coder-next",
  model_small: "qwen/qwen3-coder-next",
  max_iterations: 500,
  max_depth: 15,
  context_window_tokens_large: 100_000,
  context_window_tokens_small: 100_000,
  truncation_head: 4000,
  truncation_tail: 4000,
  eval_timeout: 30_000,
  http_pool_size: 100,
  http_pool_count: 1,
  http_pool_timeout: 30_000,
  http_receive_timeout: 120_000,
  obs_max_context_window_chars: 200_000,
  max_concurrent_agents: nil

import_config "#{config_env()}.exs"
