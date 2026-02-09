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
    :eval_timeout
  ]

  def load(overrides \\ []) do
    %__MODULE__{
      api_base_url: get(overrides, :api_base_url, "https://openrouter.ai/api/v1"),
      api_key: get(overrides, :api_key, nil),
      model_large: get(overrides, :model_large, "qwen/qwen3-coder-next"),
      model_small: get(overrides, :model_small, "qwen/qwen3-coder-next"),
      max_iterations: get(overrides, :max_iterations, 25),
      max_depth: get(overrides, :max_depth, 5),
      context_window_tokens_large:
        get(overrides, :context_window_tokens_large, 100_000),
      context_window_tokens_small:
        get(overrides, :context_window_tokens_small, 100_000),
      truncation_head: get(overrides, :truncation_head, 4000),
      truncation_tail: get(overrides, :truncation_tail, 4000),
      eval_timeout: get(overrides, :eval_timeout, 300_000)
    }
  end

  defp get(overrides, key, default) do
    Keyword.get(overrides, key, Application.get_env(:rlm, key, default))
  end
end
