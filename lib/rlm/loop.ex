defmodule RLM.Loop do
  require Logger
  alias RLM.Loop.{Compaction, EvalFeedback, Finalization, SubagentReturn}

  @doc false
  def run_turn(history, bindings, model, config, depth, agent_id) do
    iterate(history, bindings, model, config, depth, 0, agent_id)
  end

  defp iterate(history, bindings, model, config, depth, iteration, agent_id) do
    case Finalization.resolve_pending(bindings, depth, iteration, agent_id) do
      {:halt, pending, bindings} ->
        finish_staged_result(history, bindings, config, agent_id, iteration, pending)

      {:continue, bindings} ->
        if iteration >= config.max_iterations and
             not Finalization.pending_checkin_turn?(bindings, iteration) do
          {{:error, "Max iterations (#{config.max_iterations}) reached without final_answer"},
           history, bindings}
        else
          Logger.info("[RLM] depth=#{depth} iteration=#{iteration}")

          {history, bindings} = maybe_compact(history, bindings, model, config, agent_id)
          history = SubagentReturn.maybe_inject(history, config, agent_id)

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
  end

  @doc false
  def maybe_compact(history, bindings, model, config, agent_id \\ nil) do
    Compaction.maybe_compact(history, bindings, model, config, agent_id)
  end

  defp last_user_nudge?(history) do
    case List.last(history) do
      %{role: :user, content: content} -> content == RLM.Prompt.no_code_nudge()
      _ -> false
    end
  end

  defp normalize_answer(term), do: RLM.Helpers.format_value(term)

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
          EvalFeedback.evaluate_code(code, bindings, config, agent_id, iteration)

        {history, new_bindings} =
          EvalFeedback.apply(
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
    dispatch_assessment = Finalization.dispatch_assessment(bindings)
    dispatch_assessment_required = Finalization.dispatch_assessment_required?(bindings)

    cond do
      Finalization.pending_dispatch_finalization?(bindings) ->
        {history, bindings} =
          Finalization.continue_pending_dispatch(history, bindings, depth, iteration)

        continue_iteration(
          history,
          bindings,
          model,
          config,
          depth,
          iteration,
          agent_id,
          iteration_started_at
        )

      Finalization.pending_subagent_finalization?(bindings) ->
        bindings = Finalization.continue_pending_subagent(bindings, depth, iteration)

        continue_iteration(
          history,
          bindings,
          model,
          config,
          depth,
          iteration,
          agent_id,
          iteration_started_at
        )

      Finalization.pending_required_survey_finalization?(bindings) ->
        bindings = Finalization.continue_pending_required_surveys(bindings, depth, iteration)

        continue_iteration(
          history,
          bindings,
          model,
          config,
          depth,
          iteration,
          agent_id,
          iteration_started_at
        )

      true ->
        case Keyword.get(bindings, :final_answer) do
          {:ok, answer} ->
            handle_final_commit(
              :ok,
              answer,
              history,
              bindings,
              model,
              config,
              depth,
              iteration,
              agent_id,
              iteration_started_at,
              parent_agent_id,
              dispatch_assessment,
              dispatch_assessment_required
            )

          {:error, reason} ->
            handle_final_commit(
              :error,
              reason,
              history,
              bindings,
              model,
              config,
              depth,
              iteration,
              agent_id,
              iteration_started_at,
              parent_agent_id,
              dispatch_assessment,
              dispatch_assessment_required
            )

          {:invalid, _other} ->
            Logger.warning(
              "[RLM] depth=#{depth} iteration=#{iteration} invalid final_answer format; expected a success value or fail(reason)"
            )

            history =
              history ++ [%{role: :user, content: RLM.Prompt.invalid_final_answer_nudge()}]

            bindings =
              bindings
              |> Keyword.put(:final_answer, nil)
              |> Finalization.clear_dispatch_assessment()

            continue_iteration(
              history,
              bindings,
              model,
              config,
              depth,
              iteration,
              agent_id,
              iteration_started_at,
              :error
            )

          nil ->
            if dispatch_assessment_required and
                 Finalization.valid_dispatch_assessment?(dispatch_assessment) do
              Logger.warning(
                "[RLM] depth=#{depth} iteration=#{iteration} assess_dispatch used without final_answer"
              )

              history =
                history ++
                  [%{role: :user, content: RLM.Prompt.invalid_dispatch_assessment_nudge()}]

              bindings = Finalization.clear_dispatch_assessment(bindings)

              continue_iteration(
                history,
                bindings,
                model,
                config,
                depth,
                iteration,
                agent_id,
                iteration_started_at,
                :error
              )
            else
              continue_iteration(
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
    end
  end

  defp handle_final_commit(
         final_status,
         payload,
         history,
         bindings,
         model,
         config,
         depth,
         iteration,
         agent_id,
         iteration_started_at,
         parent_agent_id,
         dispatch_assessment,
         dispatch_assessment_required
       ) do
    pending = {final_status, payload}

    if dispatch_assessment_required and
         not Finalization.valid_dispatch_assessment?(dispatch_assessment) do
      stage_note =
        if final_status == :ok,
          do: "final_answer staged; dispatch assessment missing",
          else: "failure staged; dispatch assessment missing"

      Logger.warning("[RLM] depth=#{depth} iteration=#{iteration} #{stage_note}")

      history =
        history ++ [%{role: :user, content: RLM.Prompt.dispatch_assessment_checkin_nudge()}]

      bindings = Finalization.stage_pending_dispatch(bindings, pending, iteration)

      continue_iteration(
        history,
        bindings,
        model,
        config,
        depth,
        iteration,
        agent_id,
        iteration_started_at,
        :error
      )
    else
      bindings =
        Finalization.finalize_dispatch_assessment(
          bindings,
          parent_agent_id,
          agent_id,
          final_status,
          dispatch_assessment,
          dispatch_assessment_required
        )

      case Finalization.maybe_stage_subagent_assessments(
             bindings,
             pending,
             depth,
             iteration,
             agent_id
           ) do
        {:stage, bindings, child_ids} ->
          history =
            history ++
              [%{role: :user, content: RLM.Prompt.subagent_assessment_checkin_nudge(child_ids)}]

          continue_iteration(
            history,
            bindings,
            model,
            config,
            depth,
            iteration,
            agent_id,
            iteration_started_at,
            :error
          )

        :no_stage ->
          case Finalization.maybe_stage_required_surveys(bindings, pending, depth, iteration) do
            {:stage, bindings, survey_ids} ->
              history =
                history ++ [%{role: :user, content: RLM.Prompt.survey_checkin_nudge(survey_ids)}]

              continue_iteration(
                history,
                bindings,
                model,
                config,
                depth,
                iteration,
                agent_id,
                iteration_started_at,
                :error
              )

            :no_stage ->
              if final_status == :ok do
                Logger.info(
                  "[RLM] depth=#{depth} completed with answer at iteration=#{iteration}"
                )
              end

              finish_iteration(
                history,
                bindings,
                config,
                agent_id,
                iteration,
                iteration_started_at,
                final_status,
                normalize_final_result(final_status, payload)
              )
          end
      end
    end
  end

  defp normalize_final_result(:ok, payload), do: {:ok, normalize_answer(payload)}
  defp normalize_final_result(:error, payload), do: {:error, normalize_answer(payload)}

  defp continue_iteration(
         history,
         bindings,
         model,
         config,
         depth,
         iteration,
         agent_id,
         iteration_started_at,
         status \\ :ok
       ) do
    RLM.Observability.iteration_stop(agent_id, iteration, status, iteration_started_at)
    iterate(history, bindings, model, config, depth, iteration + 1, agent_id)
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
