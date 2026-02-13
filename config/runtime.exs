import Config

# Load .env file if it exists
if File.exists?(".env") do
  ".env"
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = String.trim(value)

        unless String.starts_with?(key, "#") do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end)
end

parse_string = fn value -> {:ok, value} end

parse_int = fn value ->
  if Regex.match?(~r/^\d+$/, value), do: {:ok, String.to_integer(value)}, else: :error
end

parse_float = fn value ->
  case Float.parse(value) do
    {parsed, _} -> {:ok, parsed}
    _ -> :error
  end
end

overrides = [
  {"RLM_API_BASE_URL", :api_base_url, parse_string},
  {"OPENROUTER_API_KEY", :api_key, parse_string},
  {"RLM_MODEL_LARGE", :model_large, parse_string},
  {"RLM_MODEL_SMALL", :model_small, parse_string},
  {"RLM_MAX_ITERATIONS", :max_iterations, parse_int},
  {"RLM_MAX_DEPTH", :max_depth, parse_int},
  {"RLM_TRUNCATION_HEAD", :truncation_head, parse_int},
  {"RLM_TRUNCATION_TAIL", :truncation_tail, parse_int},
  {"RLM_EVAL_TIMEOUT", :eval_timeout, parse_int},
  {"RLM_LM_QUERY_TIMEOUT", :lm_query_timeout, parse_int},
  {"RLM_SUBAGENT_ASSESSMENT_SAMPLE_RATE", :subagent_assessment_sample_rate, parse_float}
]

Enum.each(overrides, fn {env_name, key, parser} ->
  case System.get_env(env_name) do
    nil ->
      :ok

    value ->
      case parser.(value) do
        {:ok, parsed} -> config :rlm, [{key, parsed}]
        :error -> :ok
      end
  end
end)
