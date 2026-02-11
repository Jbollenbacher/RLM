defmodule RLM.Config do
  defstruct [
    :api_base_url,
    :api_key,
    :model_large,
    :model_small,
    :max_iterations,
    :max_depth,
    :context_window_tokens_large,
    :context_window_tokens_small,
    :truncation_head,
    :truncation_tail,
    :eval_timeout,
    :http_pool_size,
    :http_pool_count,
    :http_pool_timeout,
    :http_receive_timeout,
    :obs_max_context_window_chars,
    :max_concurrent_agents
  ]

  def load(overrides \\ []) do
    %__MODULE__{
      api_base_url: get(overrides, :api_base_url),
      api_key: get(overrides, :api_key),
      model_large: get(overrides, :model_large),
      model_small: get(overrides, :model_small),
      max_iterations: get(overrides, :max_iterations),
      max_depth: get(overrides, :max_depth),
      context_window_tokens_large: get(overrides, :context_window_tokens_large),
      context_window_tokens_small: get(overrides, :context_window_tokens_small),
      truncation_head: get(overrides, :truncation_head),
      truncation_tail: get(overrides, :truncation_tail),
      eval_timeout: get(overrides, :eval_timeout),
      http_pool_size: get(overrides, :http_pool_size),
      http_pool_count: get(overrides, :http_pool_count),
      http_pool_timeout: get(overrides, :http_pool_timeout),
      http_receive_timeout: get(overrides, :http_receive_timeout),
      obs_max_context_window_chars: get(overrides, :obs_max_context_window_chars),
      max_concurrent_agents: get(overrides, :max_concurrent_agents)
    }
  end

  defp get(overrides, key) do
    Keyword.get(overrides, key, Application.get_env(:rlm, key))
  end
end
