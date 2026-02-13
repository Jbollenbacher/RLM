import Config

config :rlm,
  api_base_url: "https://openrouter.ai/api/v1",
  api_key: nil,
  model_large: "stepfun/step-3.5-flash:free",
  model_small: "stepfun/step-3.5-flash:free",
  max_iterations: 512,
  max_depth: 16,
  max_concurrent_agents: 8,
  context_window_tokens_large: 100_000,
  context_window_tokens_small: 100_000,
  truncation_head: 6000,
  truncation_tail: 6000,
  eval_timeout: 180_000,
  lm_query_timeout: 180_000,
  http_pool_size: 100,
  http_pool_count: 1,
  http_pool_timeout: 30_000,
  http_receive_timeout: 120_000,
  obs_max_context_window_chars: 200_000

config :pythonx, :uv_init,
  pyproject_toml: """
  [project]
  name = "rlm"
  version = "0.0.0"
  requires-python = "==3.13.*"
  dependencies = []
  """

import_config "#{config_env()}.exs"
