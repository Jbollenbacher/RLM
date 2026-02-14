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
    :lm_query_timeout,
    :subagent_assessment_sample_rate,
    :http_pool_size,
    :http_pool_count,
    :http_pool_timeout,
    :http_receive_timeout,
    :obs_max_context_window_chars,
    :max_concurrent_agents,
    :system_prompt_path
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
      lm_query_timeout: get(overrides, :lm_query_timeout),
      subagent_assessment_sample_rate: get(overrides, :subagent_assessment_sample_rate),
      http_pool_size: get(overrides, :http_pool_size),
      http_pool_count: get(overrides, :http_pool_count),
      http_pool_timeout: get(overrides, :http_pool_timeout),
      http_receive_timeout: get(overrides, :http_receive_timeout),
      obs_max_context_window_chars: get(overrides, :obs_max_context_window_chars),
      max_concurrent_agents: get(overrides, :max_concurrent_agents),
      system_prompt_path: get(overrides, :system_prompt_path)
    }
  end

  defp get(overrides, key) do
    Keyword.get(overrides, key, Application.get_env(:rlm, key))
  end
end
