defmodule RLM.LLM do
  require Logger

  @spec chat([map()], String.t(), RLM.Config.t()) :: {:ok, String.t()} | {:error, String.t()}
  def chat(messages, model, config) do
    req =
      Req.new(
        base_url: config.api_base_url,
        headers: %{authorization: "Bearer #{config.api_key}"},
        receive_timeout: 120_000
      )

    body = %{
      "model" => model,
      "messages" => Enum.map(messages, &to_api_map/1),
      "temperature" => 0.2
    }

    case Req.post(req, url: "/chat/completions", json: body) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}} ->
        {:ok, content}

      {:ok, %{status: status, body: body}} ->
        {:error, "API returned #{status}: #{inspect(body)}"}

      {:error, exception} ->
        {:error, "HTTP error: #{Exception.message(exception)}"}
    end
  end

  @spec extract_code(String.t()) :: {:ok, String.t()} | {:error, :no_code_block}
  def extract_code(response) do
    case Regex.scan(~r/```elixir\n(.*?)```/s, response) do
      [] -> {:error, :no_code_block}
      matches -> {:ok, matches |> List.last() |> Enum.at(1) |> String.trim()}
    end
  end

  defp to_api_map(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end
end
