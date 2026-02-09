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

config :rlm,
  api_base_url: System.get_env("RLM_API_BASE_URL", "https://openrouter.ai/api/v1"),
  api_key: System.get_env("OPENROUTER_API_KEY"),
  model_large: System.get_env("RLM_MODEL_LARGE", "qwen/qwen3-coder-next"),
  model_small: System.get_env("RLM_MODEL_SMALL", "qwen/qwen3-coder-next"),
  max_iterations: String.to_integer(System.get_env("RLM_MAX_ITERATIONS", "25")),
  max_depth: String.to_integer(System.get_env("RLM_MAX_DEPTH", "5")),
  truncation_head: 4000,
  truncation_tail: 4000,
  eval_timeout: 30_000
