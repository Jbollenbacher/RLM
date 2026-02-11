defmodule RLM.Loop do
  require Logger

  @spec run(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(opts) do
    config = Keyword.get_lazy(opts, :config, fn -> RLM.Config.load() end)
    context = Keyword.fetch!(opts, :context)
    model = Keyword.get(opts, :model, config.model_large)
    depth = Keyword.get(opts, :depth, 0)
    workspace_root = Keyword.get(opts, :workspace_root)
    workspace_read_only = Keyword.get(opts, :workspace_read_only, false)
    agent_id = Keyword.get(opts, :agent_id, RLM.Helpers.unique_id("agent"))

    Logger.info("[RLM] depth=#{depth} context_size=#{byte_size(context)}")

    RLM.AgentLimiter.with_slot(config.max_concurrent_agents, fn ->
      lm_query_fn = build_lm_query(config, depth, workspace_root, workspace_read_only, agent_id)

      initial_bindings = [
        context: context,
        lm_query: lm_query_fn,
        workspace_root: workspace_root,
        workspace_read_only: workspace_read_only,
        final_answer: nil,
        last_stdout: "",
        last_stderr: "",
        last_result: nil
      ]

      system_msg = %{
        role: :system,
        content:
          RLM.Prompt.system_prompt(
            workspace_available: workspace_root != nil,
            workspace_read_only: workspace_read_only
          )
      }

      user_msg = %{
        role: :user,
        content:
          RLM.Prompt.initial_user_message(context,
            workspace_available: workspace_root != nil,
            workspace_read_only: workspace_read_only
          )
      }

      initial_history = [system_msg, user_msg]

      {result, _history, _bindings} =
        iterate(initial_history, initial_bindings, model, config, depth, 0, [], agent_id)

      case result do
        {:ok, answer} -> {:ok, answer}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc false
  def run_turn(history, bindings, model, config, depth, agent_id) do
    iterate(history, bindings, model, config, depth, 0, [], agent_id)
  end

  defp iterate(history, bindings, model, config, depth, iteration, prev_codes, agent_id) do
    if iteration >= config.max_iterations do
      {{:error, "Max iterations (#{config.max_iterations}) reached without final_answer"}, history,
       bindings}
    else
      Logger.info("[RLM] depth=#{depth} iteration=#{iteration}")

      {history, bindings} = maybe_compact(history, bindings, model, config, agent_id)

      compacted? = Keyword.get(bindings, :compacted_history, "") != ""
      RLM.Observability.snapshot_context(agent_id, iteration, history, config, compacted?: compacted?)

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
            prev_codes,
            agent_id,
            iteration_started_at
          )

        {:error, reason} ->
          RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)

          {{:error, "LLM call failed at depth=#{depth} iteration=#{iteration}: #{reason}"}, history,
           bindings}
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

  @doc false
  def track_code_repetition(prev_codes, code) do
    repeated_code? = repeated_code?(prev_codes, code)
    updated_prev_codes = update_prev_codes(prev_codes, code)
    {updated_prev_codes, repeated_code?}
  end

  defp repeated_code?(prev_codes, code) do
    case prev_codes do
      [last, second | _] -> last == code and second == code
      _ -> false
    end
  end

  defp update_prev_codes(prev_codes, code) do
    [code | prev_codes] |> Enum.take(3)
  end

  defp repetition_nudge do
    """
    [REPL][AGENT]
    [Repeated Code Detected]

    Your last three code blocks were identical. You appear to be stuck.
    Try a different approach. Consider:
    - Using IO.inspect() to examine values
    - Breaking the problem into smaller steps
    - Using list_bindings() to check your current state
    """
  end

  defp no_code_nudge do
    """
    [REPL][AGENT]
    [No code block found. Respond with exactly one ```elixir code block. Do not use IO.puts/IO.inspect to answer; set final_answer instead.]
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
    You can use `preview(compacted_history)` or `grep(pattern, compacted_history)` to search it.
    All other bindings (context, variables you defined, etc.) are preserved unchanged.

    Preview of compacted history:
    #{preview}

    Continue working on your task. Use list_bindings() to see your current state.
    """
  end

  defp normalize_answer(term) when is_binary(term), do: term

  defp normalize_answer(term),
    do: inspect(term, pretty: true, limit: :infinity, printable_limit: :infinity)

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
         prev_codes,
         agent_id,
         iteration_started_at
       ) do
    case RLM.LLM.extract_code(response) do
      {:ok, code} ->
        Logger.debug("[RLM] depth=#{depth} iteration=#{iteration} code=#{String.slice(code, 0, 200)}")

        {prev_codes, repeated_code?} = track_code_repetition(prev_codes, code)

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

        history =
          if repeated_code? do
            Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} repeated code detected")
            history ++ [%{role: :user, content: repetition_nudge()}]
          else
            history
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
            RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
            normalized = normalize_answer(answer)
            compacted? = Keyword.get(new_bindings, :compacted_history, "") != ""
            RLM.Observability.snapshot_context(agent_id, iteration, history, config, compacted?: compacted?)
            {{:ok, normalized}, history, new_bindings}

          {:error, reason} ->
            RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
            normalized = normalize_answer(reason)
            compacted? = Keyword.get(new_bindings, :compacted_history, "") != ""
            RLM.Observability.snapshot_context(agent_id, iteration, history, config, compacted?: compacted?)
            {{:error, normalized}, history, new_bindings}

          nil ->
            RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
            iterate(history, new_bindings, model, config, depth, iteration + 1, prev_codes, agent_id)

          other when other != nil ->
            Logger.info("[RLM] depth=#{depth} completed with raw answer at iteration=#{iteration}")
            RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
            normalized = normalize_answer(other)
            compacted? = Keyword.get(new_bindings, :compacted_history, "") != ""
            RLM.Observability.snapshot_context(agent_id, iteration, history, config, compacted?: compacted?)
            {{:ok, normalized}, history, new_bindings}
        end

      {:error, :no_code_block} ->
        # LLM didn't produce code — nudge it once, then accept plain text to avoid stalling
        Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} no code block found")

        if last_user_nudge?(history) do
          Logger.warning("[RLM] depth=#{depth} accepting plain-text response after repeated no-code")
          clean_response = strip_leading_agent_tags(response)
          history = history ++ [%{role: :assistant, content: clean_response}]
          RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
          compacted? = Keyword.get(bindings, :compacted_history, "") != ""
          RLM.Observability.snapshot_context(agent_id, iteration, history, config, compacted?: compacted?)
          {{:ok, normalize_answer(response)}, history, bindings}
        else
          clean_response = strip_leading_agent_tags(response)
          history =
            history ++
              [
                %{role: :assistant, content: clean_response},
                %{role: :user, content: no_code_nudge()}
              ]

          RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
          iterate(history, bindings, model, config, depth, iteration + 1, [], agent_id)
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
        child_agent_id = RLM.Helpers.unique_id("agent")

        RLM.Observability.child_query(parent_agent_id, child_agent_id, model_size, byte_size(text))

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
