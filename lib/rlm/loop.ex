defmodule RLM.Loop do
  require Logger

  @doc false
  def run_turn(history, bindings, model, config, depth, agent_id) do
    iterate(history, bindings, model, config, depth, 0, agent_id)
  end

  defp iterate(history, bindings, model, config, depth, iteration, agent_id) do
    if iteration >= config.max_iterations do
      {{:error, "Max iterations (#{config.max_iterations}) reached without final_answer"},
       history, bindings}
    else
      Logger.info("[RLM] depth=#{depth} iteration=#{iteration}")

      {history, bindings} = maybe_compact(history, bindings, model, config, agent_id)

      snapshot_iteration(agent_id, iteration, history, config, bindings)

      iteration_started_at = RLM.Observability.iteration_start(agent_id, iteration)

      case RLM.LLM.chat(history, model, config, agent_id: agent_id, iteration: iteration) do
        {:ok, response} ->
          handle_response(
            response,
            history,
            bindings,
            model,
            config,
            depth,
            iteration,
            agent_id,
            iteration_started_at
          )

        {:error, reason} ->
          RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)

          {{:error, "LLM call failed at depth=#{depth} iteration=#{iteration}: #{reason}"},
           history, bindings}
      end
    end
  end

  @doc false
  def maybe_compact(history, bindings, model, config, agent_id \\ nil) do
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

      RLM.Observability.compaction(
        agent_id,
        estimated_tokens,
        estimate_tokens(new_history),
        String.length(preview)
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
    if config.model_large == config.model_small do
      max(config.context_window_tokens_large, config.context_window_tokens_small)
    else
      cond do
        model == config.model_large -> config.context_window_tokens_large
        model == config.model_small -> config.context_window_tokens_small
        true -> config.context_window_tokens_large
      end
    end
  end

  defp no_code_nudge do
    """
    [REPL][AGENT]
    [No code block found. Respond with exactly one ```python``` code block. Do not use print() to answer; set final_answer instead.]
    """
  end

  defp invalid_final_answer_nudge do
    """
    [REPL][AGENT]
    [Invalid final_answer format. Set `final_answer` to a 2-tuple like ("ok", answer) or ("error", reason).]
    """
  end

  defp last_user_nudge?(history) do
    case List.last(history) do
      %{role: :user, content: content} -> content == no_code_nudge()
      _ -> false
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
    [REPL][AGENT]
    [Context Window Compacted]

    Your previous conversation history has been compacted to free context space.
    The full history is available in the variable `compacted_history`.
    Use Python string operations (slicing, split, regex) and `grep(pattern, compacted_history)` to search it.
    All other bindings (context, variables you defined, etc.) are preserved unchanged.

    Preview of compacted history:
    #{preview}

    Continue working on your task. Use list_bindings() to see your current state.
    """
  end

  defp normalize_answer(term) when is_binary(term), do: term

  defp normalize_answer(term),
    do: inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity)

  defp snapshot_iteration(agent_id, iteration, history, config, bindings) do
    compacted? = Keyword.get(bindings, :compacted_history, "") != ""

    RLM.Observability.snapshot_context(agent_id, iteration, history, config,
      compacted?: compacted?
    )
  end

  defp finish_iteration(
         history,
         bindings,
         config,
         agent_id,
         iteration,
         iteration_started_at,
         status,
         result
       ) do
    RLM.Observability.iteration_stop(agent_id, iteration, status, iteration_started_at)
    snapshot_iteration(agent_id, iteration, history, config, bindings)
    {result, history, bindings}
  end

  defp strip_leading_agent_tags(text) when is_binary(text) do
    Regex.replace(~r/^(?:\s*\[AGENT\]\s*)+/, text, "")
  end

  defp handle_response(
         response,
         history,
         bindings,
         model,
         config,
         depth,
         iteration,
         agent_id,
         iteration_started_at
       ) do
    case RLM.LLM.extract_code(response) do
      {:ok, code} ->
        Logger.debug(
          "[RLM] depth=#{depth} iteration=#{iteration} code=#{String.slice(code, 0, 200)}"
        )

        # Add agent message to history
        clean_response = strip_leading_agent_tags(response)
        history = history ++ [%{role: :assistant, content: clean_response}]

        # Eval
        {status, full_stdout, result, new_bindings} =
          case RLM.Eval.eval(code, bindings,
                 timeout: config.eval_timeout,
                 agent_id: agent_id,
                 iteration: iteration
               ) do
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
        final_answer_value = Keyword.get(new_bindings, :final_answer)

        suppress_result? =
          status == :ok and final_answer_value != nil and result == final_answer_value

        result_for_output = if suppress_result?, do: nil, else: result

        feedback =
          RLM.Prompt.format_eval_output(truncated_stdout, full_stderr, status, result_for_output)

        history =
          if suppress_result? and truncated_stdout == "" and full_stderr == "" do
            history
          else
            history ++ [%{role: :user, content: feedback}]
          end

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
            finish_iteration(
              history,
              new_bindings,
              config,
              agent_id,
              iteration,
              iteration_started_at,
              :ok,
              {:ok, normalize_answer(answer)}
            )

          {:error, reason} ->
            finish_iteration(
              history,
              new_bindings,
              config,
              agent_id,
              iteration,
              iteration_started_at,
              :error,
              {:error, normalize_answer(reason)}
            )

          {:invalid, _other} ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} invalid final_answer format; expected ('ok'|'error', payload)"
            )

            history = history ++ [%{role: :user, content: invalid_final_answer_nudge()}]
            new_bindings = Keyword.put(new_bindings, :final_answer, nil)
            RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)

            iterate(
              history,
              new_bindings,
              model,
              config,
              depth,
              iteration + 1,
              agent_id
            )

          nil ->
            RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)

            iterate(
              history,
              new_bindings,
              model,
              config,
              depth,
              iteration + 1,
              agent_id
            )
        end

      {:error, :no_code_block} ->
        # LLM didn't produce code — nudge once, then fail if it happens again.
        Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} no code block found")

        if last_user_nudge?(history) do
          Logger.warning("[RLM] depth=#{depth} repeated no-code response; failing turn")

          clean_response = strip_leading_agent_tags(response)
          history = history ++ [%{role: :assistant, content: clean_response}]

          finish_iteration(
            history,
            bindings,
            config,
            agent_id,
            iteration,
            iteration_started_at,
            :error,
            {:error, "No code block found after retry; set `final_answer` in Python code."}
          )
        else
          clean_response = strip_leading_agent_tags(response)

          history =
            history ++
              [
                %{role: :assistant, content: clean_response},
                %{role: :user, content: no_code_nudge()}
              ]

          RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
          iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
        end
    end
  end

  @doc false
  def build_lm_query(config, depth, workspace_root, workspace_read_only \\ false, parent_agent_id) do
    fn text, opts ->
      model_size = Keyword.fetch!(opts, :model_size)
      model = if model_size == :large, do: config.model_large, else: config.model_small

      if depth >= config.max_depth do
        {:error, "Maximum recursion depth (#{config.max_depth}) exceeded"}
      else
        child_agent_id = Keyword.get(opts, :child_agent_id, RLM.Helpers.unique_id("agent"))

        RLM.Observability.child_query(
          parent_agent_id,
          child_agent_id,
          model_size,
          byte_size(text)
        )

        RLM.run(
          "",
          text,
          model: model,
          config: config,
          depth: depth + 1,
          agent_id: child_agent_id,
          parent_agent_id: parent_agent_id,
          workspace_root: workspace_root,
          workspace_read_only: workspace_read_only
        )
      end
    end
  end
end
