defmodule RLM.Loop do
  require Logger

  @spec run(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(opts) do
    config = Keyword.get_lazy(opts, :config, fn -> RLM.Config.load() end)
    context = Keyword.fetch!(opts, :context)
    query = Keyword.fetch!(opts, :query)
    model = Keyword.get(opts, :model, config.model_large)
    depth = Keyword.get(opts, :depth, 0)

    Logger.info("[RLM] depth=#{depth} context_size=#{byte_size(context)} query=#{String.slice(query, 0, 100)}")

    lm_query_fn = build_lm_query(config, depth)

    initial_bindings = [
      context: context,
      lm_query: lm_query_fn,
      final_answer: nil,
      last_stdout: "",
      last_stderr: "",
      last_result: nil
    ]

    system_msg = %{role: :system, content: RLM.Prompt.system_prompt()}
    user_msg = %{role: :user, content: RLM.Prompt.initial_user_message(context, query)}
    initial_history = [system_msg, user_msg]

    iterate(initial_history, initial_bindings, model, config, depth, 0)
  end

  defp iterate(history, bindings, model, config, depth, iteration) do
    if iteration >= config.max_iterations do
      {:error, "Max iterations (#{config.max_iterations}) reached without final_answer"}
    else
      Logger.info("[RLM] depth=#{depth} iteration=#{iteration}")

      {history, bindings} = maybe_compact(history, bindings, model, config)

      case RLM.LLM.chat(history, model, config) do
        {:ok, response} ->
          handle_response(response, history, bindings, model, config, depth, iteration)

        {:error, reason} ->
          {:error, "LLM call failed at depth=#{depth} iteration=#{iteration}: #{reason}"}
      end
    end
  end

  @doc false
  def maybe_compact(history, bindings, model, config) do
    estimated_tokens = estimate_tokens(history)
    threshold = trunc(context_window_tokens_for_model(config, model) * 0.8)

    if estimated_tokens > threshold and length(history) > 1 do
      [system_msg | rest] = history
      serialized = serialize_history(rest)

      existing = Keyword.get(bindings, :compacted_history, "")

      combined =
        if existing == "" do
          serialized
        else
          existing <> "\n\n---\n\n" <> serialized
        end

      new_bindings = Keyword.put(bindings, :compacted_history, combined)

      preview =
        RLM.Truncate.truncate(combined,
          head: config.truncation_head,
          tail: config.truncation_tail
        )

      addendum = compaction_addendum(preview)
      new_history = [system_msg, %{role: :user, content: addendum}]

      Logger.info(
        "[RLM] Compacted history: #{estimated_tokens} tokens -> #{estimate_tokens(new_history)} tokens"
      )

      {new_history, new_bindings}
    else
      {history, bindings}
    end
  end

  defp estimate_tokens(history) do
    total_chars =
      Enum.reduce(history, 0, fn msg, acc ->
        content = Map.get(msg, :content, "")
        acc + String.length(to_string(content))
      end)

    div(total_chars, 4)
  end

  defp context_window_tokens_for_model(config, model) do
    cond do
      model == config.model_small -> config.context_window_tokens_small
      model == config.model_large -> config.context_window_tokens_large
      true -> config.context_window_tokens_large
    end
  end

  defp serialize_history(messages) do
    Enum.map_join(messages, "\n\n---\n\n", fn msg ->
      role = Map.get(msg, :role, "unknown")
      content = Map.get(msg, :content, "")
      "Role: #{role}\n#{to_string(content)}"
    end)
  end

  defp compaction_addendum(preview) do
    """
    [Context Window Compacted]

    Your previous conversation history has been compacted to free context space.
    The full history is available in the variable `compacted_history`.
    You can use `preview(compacted_history)` or `grep(pattern, compacted_history)` to search it.
    All other bindings (context, variables you defined, etc.) are preserved unchanged.

    Preview of compacted history:
    #{preview}

    Continue working on your task. Use list_bindings() to see your current state.
    """
  end

  defp handle_response(response, history, bindings, model, config, depth, iteration) do
    case RLM.LLM.extract_code(response) do
      {:ok, code} ->
        Logger.debug("[RLM] depth=#{depth} iteration=#{iteration} code=#{String.slice(code, 0, 200)}")

        # Add assistant message to history
        history = history ++ [%{role: :assistant, content: response}]

        # Eval
        {status, full_stdout, result, new_bindings} =
          case RLM.Eval.eval(code, bindings, timeout: config.eval_timeout) do
            {:ok, stdout, result, new_b} -> {:ok, stdout, result, new_b}
            {:error, stdout, old_b} -> {:error, stdout, nil, old_b}
          end

        full_stderr = ""

        # Truncate stdout for history
        truncated_stdout =
          RLM.Truncate.truncate(full_stdout,
            head: config.truncation_head,
            tail: config.truncation_tail
          )

        # Build feedback message
        feedback = RLM.Prompt.format_eval_output(truncated_stdout, full_stderr, status, result)
        history = history ++ [%{role: :user, content: feedback}]

        # Update history bindings
        new_bindings =
          new_bindings
          |> Keyword.put(:last_stdout, full_stdout)
          |> Keyword.put(:last_stderr, full_stderr)
          |> Keyword.put(:last_result, result)

        # Check for final_answer
        case Keyword.get(new_bindings, :final_answer) do
          {:ok, answer} ->
            Logger.info("[RLM] depth=#{depth} completed with answer at iteration=#{iteration}")
            {:ok, to_string(answer)}

          {:error, reason} ->
            {:error, to_string(reason)}

          nil ->
            iterate(history, new_bindings, model, config, depth, iteration + 1)

          other when other != nil ->
            Logger.info("[RLM] depth=#{depth} completed with raw answer at iteration=#{iteration}")
            {:ok, to_string(other)}
        end

      {:error, :no_code_block} ->
        # LLM didn't produce code — nudge it
        Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} no code block found")

        history =
          history ++
            [
              %{role: :assistant, content: response},
              %{role: :user, content: "[No code block found. Please respond with an ```elixir code block.]"}
            ]

        iterate(history, bindings, model, config, depth, iteration + 1)
    end
  end

  defp build_lm_query(config, depth) do
    fn text, opts ->
      model_size = Keyword.fetch!(opts, :model_size)
      model = if model_size == :large, do: config.model_large, else: config.model_small

      if depth >= config.max_depth do
        {:error, "Maximum recursion depth (#{config.max_depth}) exceeded"}
      else
        RLM.Loop.run(
          context: text,
          query: text,
          model: model,
          config: config,
          depth: depth + 1
        )
      end
    end
  end
end
