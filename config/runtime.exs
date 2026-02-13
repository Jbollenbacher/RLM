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

if api_base_url = System.get_env("RLM_API_BASE_URL") do
  config :rlm, api_base_url: api_base_url
end

if api_key = System.get_env("OPENROUTER_API_KEY") do
  config :rlm, api_key: api_key
end

if model_large = System.get_env("RLM_MODEL_LARGE") do
  config :rlm, model_large: model_large
end

if model_small = System.get_env("RLM_MODEL_SMALL") do
  config :rlm, model_small: model_small
end

if max_iterations = System.get_env("RLM_MAX_ITERATIONS") do
  config :rlm, max_iterations: String.to_integer(max_iterations)
end

if max_depth = System.get_env("RLM_MAX_DEPTH") do
  config :rlm, max_depth: String.to_integer(max_depth)
end

if truncation_head = System.get_env("RLM_TRUNCATION_HEAD") do
  config :rlm, truncation_head: String.to_integer(truncation_head)
end

if truncation_tail = System.get_env("RLM_TRUNCATION_TAIL") do
  config :rlm, truncation_tail: String.to_integer(truncation_tail)
end

if eval_timeout = System.get_env("RLM_EVAL_TIMEOUT") do
  config :rlm, eval_timeout: String.to_integer(eval_timeout)
end

if lm_query_timeout = System.get_env("RLM_LM_QUERY_TIMEOUT") do
  config :rlm, lm_query_timeout: String.to_integer(lm_query_timeout)
end
