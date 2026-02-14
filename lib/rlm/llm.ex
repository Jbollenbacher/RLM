defmodule RLM.LLM do
  require Logger

  @spec chat([map()], String.t(), RLM.Config.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def chat(messages, model, config, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)
    iteration = Keyword.get(opts, :iteration)

    metadata = %{
      agent_id: agent_id,
      iteration: iteration,
      model: model,
      message_count: length(messages),
      context_chars: total_context_chars(messages),
      request_tail: request_tail(messages)
    }

    RLM.Observability.span(:llm, metadata, fn ->
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
        "messages" => Enum.map(messages, &to_api_map/1)
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
    with nil <- extract_fenced_code(response),
         nil <- extract_tagged_code(response),
         nil <- extract_unfenced_code(response) do
      {:error, :no_code_block}
    else
      code -> {:ok, code}
    end
  end

  def extract_code(_), do: {:error, :no_code_block}

  defp extract_fenced_code(response) do
    python = Regex.scan(~r/```(?:[Pp]ython|[Pp]y)\s*\n(.*?)```/s, response)
    plain = Regex.scan(~r/```\s*\n(.*?)```/s, response)

    cond do
      python != [] ->
        python |> List.last() |> Enum.at(1) |> String.trim()

      plain != [] ->
        plain |> List.last() |> Enum.at(1) |> String.trim()

      true ->
        nil
    end
  end

  defp extract_tagged_code(response) do
    case Regex.scan(~r/<python>\s*(.*?)\s*<\/python>/is, response) do
      [] -> nil
      matches -> matches |> List.last() |> Enum.at(1) |> String.trim()
    end
  end

  defp extract_unfenced_code(response) do
    trimmed = String.trim(response)

    cond do
      trimmed == "" ->
        nil

      String.contains?(trimmed, "```") ->
        nil

      likely_unfenced_python?(trimmed) ->
        trimmed

      true ->
        nil
    end
  end

  defp likely_unfenced_python?(text) do
    lines = String.split(text, "\n", trim: true)

    code_like_count =
      Enum.count(lines, fn line ->
        Regex.match?(
          ~r/^\s*(final_answer\s*=|assess_dispatch\(|assess_lm_query\(|(?:await_|poll_|cancel_)?lm_query\(|[A-Za-z_]\w*\s*=|for\s+\w+\s+in\s+.*:|if\s+.*:|while\s+.*:|def\s+\w+\(|import\s+\w+)/,
          line
        )
      end)

    has_agent_primitive? =
      String.contains?(text, "final_answer =") or
        String.contains?(text, "assess_dispatch(") or
        String.contains?(text, "assess_lm_query(") or
        String.contains?(text, "lm_query(")

    (has_agent_primitive? and code_like_count >= 1) or code_like_count >= 2
  end

  defp to_api_map(%{role: role, content: content}) do
    %{"role" => to_string(role), "content" => content}
  end

  defp total_context_chars(messages) do
    Enum.reduce(messages, 0, fn message, acc ->
      content = message |> Map.get(:content, "") |> to_string()
      acc + String.length(content)
    end)
  end

  defp request_tail(messages) do
    messages
    |> Enum.take(-3)
    |> Enum.map(fn message ->
      role = message |> Map.get(:role, "unknown") |> to_string()
      content = message |> Map.get(:content, "") |> to_string()

      %{
        role: role,
        chars: String.length(content),
        preview: RLM.Truncate.truncate(content, head: 200, tail: 200)
      }
    end)
  end
end
