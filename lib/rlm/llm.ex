defmodule RLM.LLM do
  require Logger

  @spec chat([map()], String.t(), RLM.Config.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def chat(messages, model, config, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    iteration = Keyword.get(opts, :iteration)

    RLM.Observability.span(:llm, %{agent_id: agent_id, iteration: iteration, model: model}, fn ->
      req =
        Req.new(
          base_url: config.api_base_url,
          headers: %{authorization: "Bearer #{config.api_key}"},
          receive_timeout: config.http_receive_timeout,
          pool_timeout: config.http_pool_timeout,
          finch: RLM.Finch,
          retry: :transient,
          max_retries: 3
        )

      body = %{
        "model" => model,
        "messages" => Enum.map(messages, &to_api_map/1),
        "temperature" => 0.2
      }

      case Req.post(req, url: "/chat/completions", json: body) do
        {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => content}} | _]}}}
        when is_binary(content) and content != "" ->
          {:ok, content}

        {:ok, %{status: 200, body: body}} ->
          {:error, "API returned empty or malformed response: #{inspect(body)}"}

        {:ok, %{status: status, body: body}} ->
          {:error, "API returned #{status}: #{inspect(body)}"}

        {:error, exception} ->
          {:error, "HTTP error: #{Exception.message(exception)}"}
      end
    end)
  end

  @spec extract_code(term()) :: {:ok, String.t()} | {:error, :no_code_block}
  def extract_code(response) when is_binary(response) do
    python = Regex.scan(~r/```(?:[Pp]ython|[Pp]y)\s*\n(.*?)```/s, response)
    plain = Regex.scan(~r/```\s*\n(.*?)```/s, response)

    cond do
      python != [] ->
        {:ok, python |> List.last() |> Enum.at(1) |> String.trim()}

      plain != [] ->
        {:ok, plain |> List.last() |> Enum.at(1) |> String.trim()}

      true ->
        {:error, :no_code_block}
    end
  end

  def extract_code(_), do: {:error, :no_code_block}

  defp to_api_map(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end
end
