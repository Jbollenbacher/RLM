defmodule RLM.Loop do
  require Logger

  @doc false
  def run_turn(history, bindings, model, config, depth, agent_id) do
    iterate(history, bindings, model, config, depth, 0, agent_id)
  end

  defp iterate(history, bindings, model, config, depth, iteration, agent_id) do
    case resolve_pending_dispatch_finalization(
           history,
           bindings,
           config,
           depth,
           iteration,
           agent_id
         ) do
      {:halt, result} ->
        result

      {:continue, history, bindings} ->
        case resolve_pending_subagent_finalization(
               history,
               bindings,
               config,
               depth,
               iteration,
               agent_id
             ) do
          {:halt, result} ->
            result

          {:continue, history, bindings} ->
            if iteration >= config.max_iterations and
                 not pending_checkin_turn?(bindings, iteration) and
                 not pending_subagent_checkin_turn?(bindings, iteration) do
              {{:error, "Max iterations (#{config.max_iterations}) reached without final_answer"},
               history, bindings}
            else
              Logger.info("[RLM] depth=#{depth} iteration=#{iteration}")

              {history, bindings} = maybe_compact(history, bindings, model, config, agent_id)
              history = maybe_inject_subagent_return_messages(history, config, agent_id)

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
                  RLM.Observability.iteration_stop(
                    agent_id,
                    iteration,
                    :error,
                    iteration_started_at
                  )

                  {{:error,
                    "LLM call failed at depth=#{depth} iteration=#{iteration}: #{reason}"},
                   history, bindings}
              end
            end
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

      addendum = RLM.Prompt.compaction_addendum(preview)
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

  defp last_user_nudge?(history) do
    case List.last(history) do
      %{role: :user, content: content} -> content == RLM.Prompt.no_code_nudge()
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

  defp normalize_answer(term), do: RLM.Helpers.format_value(term)

  defp maybe_inject_subagent_return_messages(history, _config, nil), do: history

  defp maybe_inject_subagent_return_messages(history, config, agent_id) do
    case RLM.Subagent.Broker.drain_updates(agent_id) do
      [] ->
        history

      updates ->
        message = subagent_return_message(updates, config)
        history ++ [%{role: :user, content: message}]
    end
  end

  defp subagent_return_message(updates, config) do
    body =
      updates
      |> Enum.map_join("\n\n---\n\n", fn update ->
        id = Map.get(update, :child_agent_id)
        status = Map.get(update, :state)
        preview = preview_subagent_payload(Map.get(update, :payload), config)

        completion_note =
          if Map.get(update, :completion_update), do: "completion update", else: nil

        assessment_note =
          cond do
            Map.get(update, :assessment_required) and not Map.get(update, :assessment_recorded) ->
              "assessment required: call assess_lm_query(\"#{id}\", \"satisfied\"|\"dissatisfied\", reason=\"...\")"

            Map.get(update, :assessment_update) ->
              "assessment reminder: update now requires assessment after polling"

            true ->
              nil
          end

        [
          "child_agent_id: #{id}",
          "status: #{status}",
          "preview:",
          preview,
          completion_note,
          assessment_note
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    "[SUBAGENT_RETURN]\n" <> body
  end

  defp preview_subagent_payload(payload, config) do
    text =
      if is_binary(payload) do
        payload
      else
        inspect(payload, pretty: true, limit: 20, printable_limit: 4000)
      end

    RLM.Truncate.truncate(text,
      head: min(400, config.truncation_head),
      tail: min(400, config.truncation_tail)
    )
  end

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

  defp finish_staged_result(history, bindings, config, agent_id, iteration, {:ok, answer}) do
    snapshot_iteration(agent_id, iteration, history, config, bindings)
    {{:ok, normalize_answer(answer)}, history, bindings}
  end

  defp finish_staged_result(history, bindings, config, agent_id, iteration, {:error, reason}) do
    snapshot_iteration(agent_id, iteration, history, config, bindings)
    {{:error, normalize_answer(reason)}, history, bindings}
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

        history = append_agent_history(history, response)

        {status, full_stdout, full_stderr, result, new_bindings} =
          evaluate_code(code, bindings, config, agent_id, iteration)

        {history, new_bindings} =
          apply_eval_feedback(
            history,
            new_bindings,
            status,
            result,
            full_stdout,
            full_stderr,
            config
          )

        continue_after_eval(
          history,
          new_bindings,
          model,
          config,
          depth,
          iteration,
          agent_id,
          iteration_started_at
        )

      {:error, :no_code_block} ->
        handle_no_code_response(
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
    end
  end

  defp append_agent_history(history, response) do
    clean_response = strip_leading_agent_tags(response)
    history ++ [%{role: :assistant, content: clean_response}]
  end

  defp evaluate_code(code, bindings, config, agent_id, iteration) do
    case RLM.Eval.eval(code, bindings,
           timeout: config.eval_timeout,
           lm_query_timeout: config.lm_query_timeout,
           subagent_assessment_sample_rate: config.subagent_assessment_sample_rate,
           agent_id: agent_id,
           iteration: iteration
         ) do
      {:ok, stdout, stderr, result, new_bindings} ->
        {:ok, stdout, stderr, result, new_bindings}

      {:error, stdout, stderr, original_bindings} ->
        {:error, stdout, stderr, nil, original_bindings}
    end
  end

  defp apply_eval_feedback(history, bindings, status, result, full_stdout, full_stderr, config) do
    truncated_stdout =
      RLM.Truncate.truncate(full_stdout,
        head: config.truncation_head,
        tail: config.truncation_tail
      )

    truncated_stderr =
      RLM.Truncate.truncate(full_stderr,
        head: config.truncation_head,
        tail: config.truncation_tail
      )

    final_answer_value = Keyword.get(bindings, :final_answer)

    suppress_result? =
      status == :ok and final_answer_value != nil and result == final_answer_value

    result_for_output = if suppress_result?, do: nil, else: result

    feedback =
      RLM.Prompt.format_eval_output(truncated_stdout, truncated_stderr, status, result_for_output)

    history =
      if suppress_result? and truncated_stdout == "" and truncated_stderr == "" do
        history
      else
        history ++ [%{role: :user, content: feedback}]
      end

    bindings =
      bindings
      |> Keyword.put(:last_stdout, full_stdout)
      |> Keyword.put(:last_stderr, full_stderr)
      |> Keyword.put(:last_result, result)

    {history, bindings}
  end

  defp continue_after_eval(
         history,
         bindings,
         model,
         config,
         depth,
         iteration,
         agent_id,
         iteration_started_at
       ) do
    parent_agent_id = Keyword.get(bindings, :parent_agent_id)
    pending_final_answer = Keyword.get(bindings, :pending_final_answer)
    pending_subagent_final_answer = Keyword.get(bindings, :pending_subagent_final_answer)
    dispatch_assessment = Keyword.get(bindings, :dispatch_assessment)
    dispatch_assessment_required = dispatch_assessment_required?(bindings)

    if pending_final_answer do
      continue_with_pending_dispatch_finalization(
        history,
        bindings,
        model,
        config,
        depth,
        iteration,
        agent_id,
        iteration_started_at
      )
    else
      if pending_subagent_final_answer do
        continue_with_pending_subagent_finalization(
          history,
          bindings,
          model,
          config,
          depth,
          iteration,
          agent_id,
          iteration_started_at
        )
      else
        case Keyword.get(bindings, :final_answer) do
          {:ok, answer} ->
            if dispatch_assessment_required and
                 not valid_dispatch_assessment?(dispatch_assessment) do
              Logger.warning(
                "[RLM] depth=#{depth} iteration=#{iteration} final_answer staged; dispatch assessment missing"
              )

              history =
                history ++
                  [%{role: :user, content: RLM.Prompt.dispatch_assessment_checkin_nudge()}]

              bindings = stage_pending_dispatch_finalization(bindings, {:ok, answer}, iteration)
              RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
              iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
            else
              bindings =
                finalize_dispatch_assessment(
                  bindings,
                  parent_agent_id,
                  agent_id,
                  :ok,
                  dispatch_assessment,
                  dispatch_assessment_required
                )

              case maybe_stage_subagent_assessment_finalization(
                     history,
                     bindings,
                     {:ok, answer},
                     depth,
                     iteration,
                     agent_id
                   ) do
                {:stage, history, bindings} ->
                  RLM.Observability.iteration_stop(
                    agent_id,
                    iteration,
                    :error,
                    iteration_started_at
                  )

                  iterate(history, bindings, model, config, depth, iteration + 1, agent_id)

                :no_stage ->
                  Logger.info(
                    "[RLM] depth=#{depth} completed with answer at iteration=#{iteration}"
                  )

                  finish_iteration(
                    history,
                    bindings,
                    config,
                    agent_id,
                    iteration,
                    iteration_started_at,
                    :ok,
                    {:ok, normalize_answer(answer)}
                  )
              end
            end

          {:error, reason} ->
            if dispatch_assessment_required and
                 not valid_dispatch_assessment?(dispatch_assessment) do
              Logger.warning(
                "[RLM] depth=#{depth} iteration=#{iteration} failure staged; dispatch assessment missing"
              )

              history =
                history ++
                  [%{role: :user, content: RLM.Prompt.dispatch_assessment_checkin_nudge()}]

              bindings =
                stage_pending_dispatch_finalization(bindings, {:error, reason}, iteration)

              RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
              iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
            else
              bindings =
                finalize_dispatch_assessment(
                  bindings,
                  parent_agent_id,
                  agent_id,
                  :error,
                  dispatch_assessment,
                  dispatch_assessment_required
                )

              case maybe_stage_subagent_assessment_finalization(
                     history,
                     bindings,
                     {:error, reason},
                     depth,
                     iteration,
                     agent_id
                   ) do
                {:stage, history, bindings} ->
                  RLM.Observability.iteration_stop(
                    agent_id,
                    iteration,
                    :error,
                    iteration_started_at
                  )

                  iterate(history, bindings, model, config, depth, iteration + 1, agent_id)

                :no_stage ->
                  finish_iteration(
                    history,
                    bindings,
                    config,
                    agent_id,
                    iteration,
                    iteration_started_at,
                    :error,
                    {:error, normalize_answer(reason)}
                  )
              end
            end

          {:invalid, _other} ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} invalid final_answer format; expected a success value or fail(reason)"
            )

            history =
              history ++ [%{role: :user, content: RLM.Prompt.invalid_final_answer_nudge()}]

            bindings =
              bindings
              |> Keyword.put(:final_answer, nil)
              |> Keyword.put(:dispatch_assessment, nil)

            RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
            iterate(history, bindings, model, config, depth, iteration + 1, agent_id)

          nil ->
            if dispatch_assessment_required and valid_dispatch_assessment?(dispatch_assessment) do
              Logger.warning(
                "[RLM] depth=#{depth} iteration=#{iteration} assess_dispatch used without final_answer"
              )

              history =
                history ++
                  [%{role: :user, content: RLM.Prompt.invalid_dispatch_assessment_nudge()}]

              bindings = Keyword.put(bindings, :dispatch_assessment, nil)
              RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
              iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
            else
              RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
              iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
            end
        end
      end
    end
  end

  defp maybe_stage_subagent_assessment_finalization(
         history,
         bindings,
         final_answer,
         depth,
         iteration,
         agent_id
       ) do
    pending = pending_subagent_assessments(agent_id)

    if pending == [] do
      :no_stage
    else
      child_ids = pending |> Enum.map(&Map.get(&1, :child_agent_id)) |> Enum.reject(&is_nil/1)

      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} final answer staged; subagent assessments pending for #{Enum.join(child_ids, ", ")}"
      )

      history =
        history ++
          [%{role: :user, content: RLM.Prompt.subagent_assessment_checkin_nudge(child_ids)}]

      bindings = stage_pending_subagent_finalization(bindings, final_answer, child_ids, iteration)
      {:stage, history, bindings}
    end
  end

  defp continue_with_pending_dispatch_finalization(
         history,
         bindings,
         model,
         config,
         depth,
         iteration,
         agent_id,
         iteration_started_at
       ) do
    dispatch_assessment = Keyword.get(bindings, :dispatch_assessment)
    final_answer = Keyword.get(bindings, :final_answer)

    {history, bindings} =
      if dispatch_assessment != nil and not valid_dispatch_assessment?(dispatch_assessment) do
        Logger.warning(
          "[RLM] depth=#{depth} iteration=#{iteration} invalid dispatch assessment during check-in"
        )

        {
          history ++ [%{role: :user, content: RLM.Prompt.invalid_dispatch_assessment_nudge()}],
          Keyword.put(bindings, :dispatch_assessment, nil)
        }
      else
        {history, bindings}
      end

    if final_answer != nil do
      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} pending final answer exists; ignoring replacement final_answer"
      )
    end

    bindings = Keyword.put(bindings, :final_answer, nil)

    RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
    iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
  end

  defp continue_with_pending_subagent_finalization(
         history,
         bindings,
         model,
         config,
         depth,
         iteration,
         agent_id,
         iteration_started_at
       ) do
    if Keyword.get(bindings, :final_answer) != nil do
      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} pending subagent-assessment final answer exists; ignoring replacement final_answer"
      )
    end

    bindings = Keyword.put(bindings, :final_answer, nil)
    RLM.Observability.iteration_stop(agent_id, iteration, :ok, iteration_started_at)
    iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
  end

  defp resolve_pending_dispatch_finalization(
         history,
         bindings,
         config,
         depth,
         iteration,
         agent_id
       ) do
    parent_agent_id = Keyword.get(bindings, :parent_agent_id)
    dispatch_assessment = Keyword.get(bindings, :dispatch_assessment)
    dispatch_assessment_required = dispatch_assessment_required?(bindings)
    deadline = Keyword.get(bindings, :dispatch_assessment_checkin_deadline_iteration, iteration)

    case Keyword.get(bindings, :pending_final_answer) do
      {:ok, _answer} = pending ->
        cond do
          valid_dispatch_assessment?(dispatch_assessment) ->
            Logger.info(
              "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged answer after dispatch assessment"
            )

            bindings =
              bindings
              |> finalize_dispatch_assessment(
                parent_agent_id,
                agent_id,
                :ok,
                dispatch_assessment,
                dispatch_assessment_required
              )
              |> clear_pending_dispatch_finalization()

            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          iteration > deadline ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} dispatch assessment still missing after check-in window"
            )

            bindings =
              bindings
              |> finalize_dispatch_assessment(
                parent_agent_id,
                agent_id,
                :ok,
                nil,
                dispatch_assessment_required
              )
              |> clear_pending_dispatch_finalization()

            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          true ->
            {:continue, history, bindings}
        end

      {:error, _reason} = pending ->
        cond do
          valid_dispatch_assessment?(dispatch_assessment) ->
            Logger.info(
              "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged failure after dispatch assessment"
            )

            bindings =
              bindings
              |> finalize_dispatch_assessment(
                parent_agent_id,
                agent_id,
                :error,
                dispatch_assessment,
                dispatch_assessment_required
              )
              |> clear_pending_dispatch_finalization()

            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          iteration > deadline ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} dispatch assessment still missing after check-in window"
            )

            bindings =
              bindings
              |> finalize_dispatch_assessment(
                parent_agent_id,
                agent_id,
                :error,
                nil,
                dispatch_assessment_required
              )
              |> clear_pending_dispatch_finalization()

            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          true ->
            {:continue, history, bindings}
        end

      _ ->
        {:continue, history, bindings}
    end
  end

  defp resolve_pending_subagent_finalization(
         history,
         bindings,
         config,
         depth,
         iteration,
         agent_id
       ) do
    deadline = Keyword.get(bindings, :subagent_assessment_checkin_deadline_iteration, iteration)
    tracked_child_ids = Keyword.get(bindings, :pending_subagent_assessment_child_ids, [])

    case Keyword.get(bindings, :pending_subagent_final_answer) do
      {:ok, _answer} = pending ->
        remaining = pending_subagent_assessments(agent_id, tracked_child_ids)

        cond do
          remaining == [] ->
            Logger.info(
              "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged answer after subagent assessments"
            )

            bindings = clear_pending_subagent_finalization(bindings)
            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          iteration > deadline ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} subagent assessments still missing after check-in window"
            )

            emit_subagent_assessment_missing(agent_id, tracked_child_ids)
            bindings = clear_pending_subagent_finalization(bindings)
            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          true ->
            {:continue, history, bindings}
        end

      {:error, _reason} = pending ->
        remaining = pending_subagent_assessments(agent_id, tracked_child_ids)

        cond do
          remaining == [] ->
            Logger.info(
              "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged failure after subagent assessments"
            )

            bindings = clear_pending_subagent_finalization(bindings)
            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          iteration > deadline ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} subagent assessments still missing after check-in window"
            )

            emit_subagent_assessment_missing(agent_id, tracked_child_ids)
            bindings = clear_pending_subagent_finalization(bindings)
            {:halt, finish_staged_result(history, bindings, config, agent_id, iteration, pending)}

          true ->
            {:continue, history, bindings}
        end

      _ ->
        {:continue, history, bindings}
    end
  end

  defp stage_pending_dispatch_finalization(bindings, pending_final_answer, iteration) do
    bindings
    |> Keyword.put(:pending_final_answer, pending_final_answer)
    |> Keyword.put(:dispatch_assessment_checkin_deadline_iteration, iteration + 1)
    |> Keyword.put(:final_answer, nil)
    |> Keyword.put(:dispatch_assessment, nil)
  end

  defp clear_pending_dispatch_finalization(bindings) do
    bindings
    |> Keyword.put(:pending_final_answer, nil)
    |> Keyword.put(:dispatch_assessment_checkin_deadline_iteration, nil)
    |> Keyword.put(:final_answer, nil)
  end

  defp stage_pending_subagent_finalization(bindings, pending_final_answer, child_ids, iteration) do
    bindings
    |> Keyword.put(:pending_subagent_final_answer, pending_final_answer)
    |> Keyword.put(:pending_subagent_assessment_child_ids, child_ids)
    |> Keyword.put(:subagent_assessment_checkin_deadline_iteration, iteration + 1)
    |> Keyword.put(:final_answer, nil)
  end

  defp clear_pending_subagent_finalization(bindings) do
    bindings
    |> Keyword.put(:pending_subagent_final_answer, nil)
    |> Keyword.put(:pending_subagent_assessment_child_ids, [])
    |> Keyword.put(:subagent_assessment_checkin_deadline_iteration, nil)
    |> Keyword.put(:final_answer, nil)
  end

  defp pending_subagent_assessments(agent_id, tracked_child_ids \\ [])

  defp pending_subagent_assessments(nil, _tracked_child_ids), do: []

  defp pending_subagent_assessments(agent_id, tracked_child_ids) do
    pending = RLM.Subagent.Broker.pending_assessments(agent_id)

    case tracked_child_ids do
      [] ->
        pending

      child_ids ->
        tracked = MapSet.new(child_ids)

        Enum.filter(pending, fn item ->
          MapSet.member?(tracked, Map.get(item, :child_agent_id))
        end)
    end
  end

  defp emit_subagent_assessment_missing(agent_id, tracked_child_ids) when is_binary(agent_id) do
    pending = RLM.Subagent.Broker.drain_pending_assessments(agent_id)

    pending =
      case tracked_child_ids do
        [] ->
          pending

        child_ids ->
          tracked = MapSet.new(child_ids)

          Enum.filter(pending, fn item ->
            MapSet.member?(tracked, Map.get(item, :child_agent_id))
          end)
      end

    Enum.each(pending, fn item ->
      RLM.Observability.subagent_assessment_missing(
        agent_id,
        item.child_agent_id,
        item.status
      )
    end)
  end

  defp emit_subagent_assessment_missing(_agent_id, _tracked_child_ids), do: :ok

  defp pending_checkin_turn?(bindings, iteration) do
    case Keyword.get(bindings, :pending_final_answer) do
      {:ok, _} ->
        iteration <= Keyword.get(bindings, :dispatch_assessment_checkin_deadline_iteration, -1)

      {:error, _} ->
        iteration <= Keyword.get(bindings, :dispatch_assessment_checkin_deadline_iteration, -1)

      _ ->
        false
    end
  end

  defp pending_subagent_checkin_turn?(bindings, iteration) do
    case Keyword.get(bindings, :pending_subagent_final_answer) do
      {:ok, _} ->
        iteration <= Keyword.get(bindings, :subagent_assessment_checkin_deadline_iteration, -1)

      {:error, _} ->
        iteration <= Keyword.get(bindings, :subagent_assessment_checkin_deadline_iteration, -1)

      _ ->
        false
    end
  end

  defp finalize_dispatch_assessment(
         bindings,
         parent_agent_id,
         agent_id,
         final_status,
         dispatch_assessment,
         dispatch_assessment_required
       ) do
    if dispatch_assessment_required and is_binary(parent_agent_id) and parent_agent_id != "" do
      case dispatch_assessment do
        %{verdict: verdict, reason: reason} when verdict in [:satisfied, :dissatisfied] ->
          RLM.Observability.dispatch_assessment(
            parent_agent_id,
            agent_id,
            verdict,
            to_string(reason)
          )

        _ ->
          RLM.Observability.dispatch_assessment_missing(parent_agent_id, agent_id, final_status)
      end
    end

    Keyword.put(bindings, :dispatch_assessment, nil)
  end

  defp valid_dispatch_assessment?(%{verdict: verdict})
       when verdict in [:satisfied, :dissatisfied],
       do: true

  defp valid_dispatch_assessment?(_), do: false

  defp dispatch_assessment_required?(bindings) do
    Keyword.get(bindings, :dispatch_assessment_required, false) == true
  end

  defp handle_no_code_response(
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
    Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} no code block found")
    repeated_no_code? = last_user_nudge?(history)
    history = append_agent_history(history, response)

    if repeated_no_code? do
      Logger.warning("[RLM] depth=#{depth} repeated no-code response; failing turn")

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
      history = history ++ [%{role: :user, content: RLM.Prompt.no_code_nudge()}]
      RLM.Observability.iteration_stop(agent_id, iteration, :error, iteration_started_at)
      iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
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
        assessment_sampled = Keyword.get(opts, :assessment_sampled, false)

        RLM.Observability.child_query(
          parent_agent_id,
          child_agent_id,
          model_size,
          byte_size(text),
          assessment_sampled: assessment_sampled,
          text_chars: String.length(text),
          query_preview: RLM.Truncate.truncate(text, head: 220, tail: 220)
        )

        RLM.run(
          "",
          text,
          model: model,
          config: config,
          depth: depth + 1,
          agent_id: child_agent_id,
          parent_agent_id: parent_agent_id,
          dispatch_assessment_required: assessment_sampled,
          workspace_root: workspace_root,
          workspace_read_only: workspace_read_only
        )
      end
    end
  end
end
