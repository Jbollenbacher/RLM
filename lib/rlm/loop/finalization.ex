defmodule RLM.Loop.Finalization do
  @moduledoc false

  require Logger

  @type pending_answer :: {:ok, term()} | {:error, term()}

  @spec resolve_pending(keyword(), non_neg_integer(), non_neg_integer(), String.t() | nil) ::
          {:halt, pending_answer(), keyword()} | {:continue, keyword()}
  def resolve_pending(bindings, depth, iteration, agent_id) do
    case resolve_pending_dispatch_finalization(bindings, depth, iteration, agent_id) do
      {:halt, pending, bindings} ->
        {:halt, pending, bindings}

      {:continue, bindings} ->
        case resolve_pending_subagent_finalization(bindings, depth, iteration, agent_id) do
          {:halt, pending, bindings} ->
            {:halt, pending, bindings}

          {:continue, bindings} ->
            resolve_pending_required_survey_finalization(bindings, depth, iteration, agent_id)
        end
    end
  end

  @spec pending_checkin_turn?(keyword(), non_neg_integer()) :: boolean()
  def pending_checkin_turn?(bindings, iteration) do
    pending_dispatch_checkin_turn?(bindings, iteration) or
      pending_subagent_checkin_turn?(bindings, iteration) or
      pending_required_survey_checkin_turn?(bindings, iteration)
  end

  @spec pending_dispatch_finalization?(keyword()) :: boolean()
  def pending_dispatch_finalization?(bindings) do
    match?({:ok, _}, Keyword.get(bindings, :pending_final_answer)) or
      match?({:error, _}, Keyword.get(bindings, :pending_final_answer))
  end

  @spec pending_subagent_finalization?(keyword()) :: boolean()
  def pending_subagent_finalization?(bindings) do
    match?({:ok, _}, Keyword.get(bindings, :pending_subagent_final_answer)) or
      match?({:error, _}, Keyword.get(bindings, :pending_subagent_final_answer))
  end

  @spec pending_required_survey_finalization?(keyword()) :: boolean()
  def pending_required_survey_finalization?(bindings) do
    match?({:ok, _}, Keyword.get(bindings, :pending_required_survey_final_answer)) or
      match?({:error, _}, Keyword.get(bindings, :pending_required_survey_final_answer))
  end

  @spec continue_pending_dispatch([map()], keyword(), non_neg_integer(), non_neg_integer()) ::
          {[map()], keyword()}
  def continue_pending_dispatch(history, bindings, depth, iteration) do
    dispatch_assessment = dispatch_assessment(bindings)
    final_answer = Keyword.get(bindings, :final_answer)

    {history, bindings} =
      if dispatch_assessment != nil and not valid_dispatch_assessment?(dispatch_assessment) do
        Logger.warning(
          "[RLM] depth=#{depth} iteration=#{iteration} invalid dispatch assessment during check-in"
        )

        {
          history ++ [%{role: :user, content: RLM.Prompt.invalid_dispatch_assessment_nudge()}],
          clear_dispatch_assessment(bindings)
        }
      else
        {history, bindings}
      end

    if final_answer != nil do
      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} pending final answer exists; ignoring replacement final_answer"
      )
    end

    {history, Keyword.put(bindings, :final_answer, nil)}
  end

  @spec continue_pending_subagent(keyword(), non_neg_integer(), non_neg_integer()) :: keyword()
  def continue_pending_subagent(bindings, depth, iteration) do
    if Keyword.get(bindings, :final_answer) != nil do
      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} pending subagent-assessment final answer exists; ignoring replacement final_answer"
      )
    end

    Keyword.put(bindings, :final_answer, nil)
  end

  @spec continue_pending_required_surveys(keyword(), non_neg_integer(), non_neg_integer()) ::
          keyword()
  def continue_pending_required_surveys(bindings, depth, iteration) do
    if Keyword.get(bindings, :final_answer) != nil do
      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} pending required-survey final answer exists; ignoring replacement final_answer"
      )
    end

    Keyword.put(bindings, :final_answer, nil)
  end

  @spec maybe_stage_subagent_assessments(
          keyword(),
          pending_answer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) :: {:stage, keyword(), [String.t()]} | :no_stage
  def maybe_stage_subagent_assessments(bindings, final_answer, depth, iteration, agent_id) do
    pending = pending_subagent_surveys(agent_id)

    if pending == [] do
      :no_stage
    else
      child_ids =
        pending
        |> Enum.map(&Map.get(&1, :child_agent_id))
        |> Enum.reject(&is_nil/1)

      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} final answer staged; subagent assessments pending for #{Enum.join(child_ids, ", ")}"
      )

      {:stage, stage_pending_subagent_finalization(bindings, final_answer, child_ids, iteration),
       child_ids}
    end
  end

  @spec stage_pending_dispatch(keyword(), pending_answer(), non_neg_integer()) :: keyword()
  def stage_pending_dispatch(bindings, pending_final_answer, iteration) do
    bindings
    |> Keyword.put(:pending_final_answer, pending_final_answer)
    |> Keyword.put(:dispatch_assessment_checkin_deadline_iteration, iteration + 1)
    |> Keyword.put(:final_answer, nil)
    |> Keyword.put(:dispatch_assessment, nil)
  end

  @spec maybe_stage_required_surveys(
          keyword(),
          pending_answer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:stage, keyword(), [String.t()]} | :no_stage
  def maybe_stage_required_surveys(bindings, final_answer, depth, iteration) do
    survey_ids = pending_required_local_survey_ids(bindings)

    if survey_ids == [] do
      :no_stage
    else
      Logger.warning(
        "[RLM] depth=#{depth} iteration=#{iteration} final answer staged; required surveys pending for #{Enum.join(survey_ids, ", ")}"
      )

      {:stage, stage_pending_required_surveys(bindings, final_answer, survey_ids, iteration),
       survey_ids}
    end
  end

  @spec finalize_dispatch_assessment(
          keyword(),
          String.t() | nil,
          String.t() | nil,
          :ok | :error,
          map() | nil,
          boolean()
        ) :: keyword()
  def finalize_dispatch_assessment(
        bindings,
        parent_agent_id,
        agent_id,
        final_status,
        dispatch_assessment,
        dispatch_assessment_required
      ) do
    bindings =
      if dispatch_assessment_required do
        case dispatch_assessment do
          %{verdict: verdict, reason: reason} when verdict in [:satisfied, :dissatisfied] ->
            update_dispatch_survey(bindings, verdict, to_string(reason))

          _ ->
            mark_dispatch_survey_missing(bindings)
        end
      else
        bindings
      end

    if dispatch_assessment_required and is_binary(parent_agent_id) and parent_agent_id != "" do
      case dispatch_assessment do
        %{verdict: verdict, reason: reason} when verdict in [:satisfied, :dissatisfied] ->
          RLM.Observability.dispatch_quality_answer(
            parent_agent_id,
            agent_id,
            verdict,
            to_string(reason)
          )

        _ ->
          RLM.Observability.dispatch_quality_missing(parent_agent_id, agent_id, final_status)
      end
    end

    Keyword.put(bindings, :dispatch_assessment, nil)
  end

  @spec valid_dispatch_assessment?(term()) :: boolean()
  def valid_dispatch_assessment?(%{verdict: verdict}) when verdict in [:satisfied, :dissatisfied],
    do: true

  def valid_dispatch_assessment?(_), do: false

  @spec dispatch_assessment_required?(keyword()) :: boolean()
  def dispatch_assessment_required?(bindings) do
    Keyword.get(bindings, :dispatch_assessment_required, false) == true
  end

  defp resolve_pending_dispatch_finalization(bindings, depth, iteration, agent_id) do
    parent_agent_id = Keyword.get(bindings, :parent_agent_id)
    dispatch_assessment = dispatch_assessment(bindings)
    dispatch_assessment_required = dispatch_assessment_required?(bindings)
    deadline = Keyword.get(bindings, :dispatch_assessment_checkin_deadline_iteration, iteration)

    pending = Keyword.get(bindings, :pending_final_answer)

    if pending_answer?(pending) do
      resolve_dispatch_pending(
        bindings,
        pending,
        depth,
        iteration,
        deadline,
        parent_agent_id,
        agent_id,
        dispatch_assessment,
        dispatch_assessment_required
      )
    else
      {:continue, bindings}
    end
  end

  defp resolve_pending_subagent_finalization(bindings, depth, iteration, agent_id) do
    deadline = Keyword.get(bindings, :subagent_assessment_checkin_deadline_iteration, iteration)
    tracked_child_ids = Keyword.get(bindings, :pending_subagent_assessment_child_ids, [])
    pending = Keyword.get(bindings, :pending_subagent_final_answer)

    if pending_answer?(pending) do
      resolve_subagent_pending(
        bindings,
        pending,
        depth,
        iteration,
        deadline,
        agent_id,
        tracked_child_ids
      )
    else
      {:continue, bindings}
    end
  end

  defp resolve_pending_required_survey_finalization(bindings, depth, iteration, agent_id) do
    deadline =
      Keyword.get(bindings, :required_survey_checkin_deadline_iteration, iteration)

    tracked_survey_ids = Keyword.get(bindings, :pending_required_survey_ids, [])
    pending = Keyword.get(bindings, :pending_required_survey_final_answer)

    if pending_answer?(pending) do
      resolve_required_surveys_pending(
        bindings,
        pending,
        depth,
        iteration,
        deadline,
        agent_id,
        tracked_survey_ids
      )
    else
      {:continue, bindings}
    end
  end

  defp resolve_dispatch_pending(
         bindings,
         pending,
         depth,
         iteration,
         deadline,
         parent_agent_id,
         agent_id,
         dispatch_assessment,
         dispatch_assessment_required
       ) do
    final_status = pending_status_atom(pending)
    status_label = pending_status_label(pending)

    cond do
      valid_dispatch_assessment?(dispatch_assessment) ->
        Logger.info(
          "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged #{status_label} after dispatch assessment"
        )

        bindings =
          bindings
          |> finalize_dispatch_assessment(
            parent_agent_id,
            agent_id,
            final_status,
            dispatch_assessment,
            dispatch_assessment_required
          )
          |> clear_pending_dispatch_finalization()

        {:halt, pending, bindings}

      iteration > deadline ->
        Logger.warning(
          "[RLM] depth=#{depth} iteration=#{iteration} dispatch assessment still missing after check-in window"
        )

        bindings =
          bindings
          |> finalize_dispatch_assessment(
            parent_agent_id,
            agent_id,
            final_status,
            nil,
            dispatch_assessment_required
          )
          |> clear_pending_dispatch_finalization()

        {:halt, pending, bindings}

      true ->
        {:continue, bindings}
    end
  end

  defp resolve_subagent_pending(
         bindings,
         pending,
         depth,
         iteration,
         deadline,
         agent_id,
         tracked_child_ids
       ) do
    remaining = pending_subagent_surveys(agent_id, tracked_child_ids)
    status_label = pending_status_label(pending)

    cond do
      remaining == [] ->
        Logger.info(
          "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged #{status_label} after subagent assessments"
        )

        {:halt, pending, clear_pending_subagent_finalization(bindings)}

      iteration > deadline ->
        Logger.warning(
          "[RLM] depth=#{depth} iteration=#{iteration} subagent assessments still missing after check-in window"
        )

        emit_subagent_survey_missing(agent_id, tracked_child_ids)
        {:halt, pending, clear_pending_subagent_finalization(bindings)}

      true ->
        {:continue, bindings}
    end
  end

  defp resolve_required_surveys_pending(
         bindings,
         pending,
         depth,
         iteration,
         deadline,
         agent_id,
         tracked_survey_ids
       ) do
    remaining_ids = pending_required_local_survey_ids(bindings, tracked_survey_ids)
    status_label = pending_status_label(pending)
    final_status = pending_status_atom(pending)

    cond do
      remaining_ids == [] ->
        Logger.info(
          "[RLM] depth=#{depth} iteration=#{iteration} finalizing staged #{status_label} after required surveys"
        )

        {:halt, pending, clear_pending_required_surveys(bindings)}

      iteration > deadline ->
        Logger.warning(
          "[RLM] depth=#{depth} iteration=#{iteration} required surveys still missing after check-in window"
        )

        bindings =
          bindings
          |> mark_required_surveys_missing(remaining_ids)
          |> clear_pending_required_surveys()

        emit_required_survey_missing(agent_id, final_status, remaining_ids)
        {:halt, pending, bindings}

      true ->
        {:continue, bindings}
    end
  end

  defp pending_status_label({:ok, _}), do: "answer"
  defp pending_status_label({:error, _}), do: "failure"
  defp pending_status_atom({:ok, _}), do: :ok
  defp pending_status_atom({:error, _}), do: :error

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

  defp stage_pending_required_surveys(bindings, pending_final_answer, survey_ids, iteration) do
    bindings
    |> Keyword.put(:pending_required_survey_final_answer, pending_final_answer)
    |> Keyword.put(:pending_required_survey_ids, survey_ids)
    |> Keyword.put(:required_survey_checkin_deadline_iteration, iteration + 1)
    |> Keyword.put(:final_answer, nil)
  end

  defp clear_pending_required_surveys(bindings) do
    bindings
    |> Keyword.put(:pending_required_survey_final_answer, nil)
    |> Keyword.put(:pending_required_survey_ids, [])
    |> Keyword.put(:required_survey_checkin_deadline_iteration, nil)
    |> Keyword.put(:final_answer, nil)
  end

  defp pending_subagent_surveys(agent_id, tracked_child_ids \\ [])
  defp pending_subagent_surveys(nil, _tracked_child_ids), do: []

  defp pending_subagent_surveys(agent_id, tracked_child_ids) do
    pending = RLM.Subagent.Broker.pending_assessments(agent_id)

    case tracked_child_ids do
      [] ->
        pending

      child_ids ->
        tracked = MapSet.new(child_ids)
        Enum.filter(pending, &MapSet.member?(tracked, Map.get(&1, :child_agent_id)))
    end
  end

  defp emit_subagent_survey_missing(agent_id, tracked_child_ids) when is_binary(agent_id) do
    pending = RLM.Subagent.Broker.drain_pending_assessments(agent_id)

    pending =
      case tracked_child_ids do
        [] ->
          pending

        child_ids ->
          tracked = MapSet.new(child_ids)
          Enum.filter(pending, &MapSet.member?(tracked, Map.get(&1, :child_agent_id)))
      end

    Enum.each(pending, fn item ->
      RLM.Observability.subagent_usefulness_missing(
        agent_id,
        item.child_agent_id,
        item.status
      )
    end)
  end

  defp emit_subagent_survey_missing(_agent_id, _tracked_child_ids), do: :ok

  defp pending_dispatch_checkin_turn?(bindings, iteration) do
    pending_checkin_turn_for(
      bindings,
      iteration,
      :pending_final_answer,
      :dispatch_assessment_checkin_deadline_iteration
    )
  end

  defp pending_subagent_checkin_turn?(bindings, iteration) do
    pending_checkin_turn_for(
      bindings,
      iteration,
      :pending_subagent_final_answer,
      :subagent_assessment_checkin_deadline_iteration
    )
  end

  defp pending_required_survey_checkin_turn?(bindings, iteration) do
    pending_checkin_turn_for(
      bindings,
      iteration,
      :pending_required_survey_final_answer,
      :required_survey_checkin_deadline_iteration
    )
  end

  defp pending_checkin_turn_for(bindings, iteration, pending_key, deadline_key) do
    pending = Keyword.get(bindings, pending_key)

    if pending_answer?(pending) do
      iteration <= Keyword.get(bindings, deadline_key, -1)
    else
      false
    end
  end

  defp pending_answer?({:ok, _}), do: true
  defp pending_answer?({:error, _}), do: true
  defp pending_answer?(_), do: false

  @spec dispatch_assessment(keyword()) :: map() | nil
  def dispatch_assessment(bindings) do
    Keyword.get(bindings, :dispatch_assessment) ||
      bindings
      |> Keyword.get(:survey_state, RLM.Survey.init_state())
      |> RLM.Survey.dispatch_assessment()
  end

  @spec clear_dispatch_assessment(keyword()) :: keyword()
  def clear_dispatch_assessment(bindings) do
    survey_state =
      bindings
      |> Keyword.get(:survey_state, RLM.Survey.init_state())
      |> RLM.Survey.clear_response(RLM.Survey.dispatch_quality_id())

    bindings
    |> Keyword.put(:dispatch_assessment, nil)
    |> Keyword.put(:survey_state, survey_state)
  end

  defp update_dispatch_survey(bindings, verdict, reason) do
    survey_state =
      bindings
      |> Keyword.get(:survey_state, RLM.Survey.init_state())
      |> RLM.Survey.ensure_dispatch_quality(true)

    case RLM.Survey.answer(survey_state, RLM.Survey.dispatch_quality_id(), verdict, reason) do
      {:ok, updated, _survey} -> Keyword.put(bindings, :survey_state, updated)
      {:error, _reason} -> bindings
    end
  end

  defp mark_dispatch_survey_missing(bindings) do
    survey_state =
      bindings
      |> Keyword.get(:survey_state, RLM.Survey.init_state())
      |> RLM.Survey.ensure_dispatch_quality(true)
      |> RLM.Survey.mark_missing(RLM.Survey.dispatch_quality_id())

    Keyword.put(bindings, :survey_state, survey_state)
  end

  defp mark_required_surveys_missing(bindings, survey_ids) when is_list(survey_ids) do
    survey_state =
      Enum.reduce(
        survey_ids,
        Keyword.get(bindings, :survey_state, RLM.Survey.init_state()),
        fn survey_id, acc ->
          RLM.Survey.mark_missing(acc, survey_id)
        end
      )

    Keyword.put(bindings, :survey_state, survey_state)
  end

  defp emit_required_survey_missing(agent_id, final_status, survey_ids)
       when is_binary(agent_id) and is_list(survey_ids) do
    Enum.each(survey_ids, fn survey_id ->
      RLM.Observability.survey_missing(agent_id, survey_id, %{scope: :agent, status: final_status})
    end)
  end

  defp emit_required_survey_missing(_agent_id, _final_status, _survey_ids), do: :ok

  defp pending_required_local_survey_ids(bindings, tracked_ids \\ []) do
    pending =
      bindings
      |> Keyword.get(:survey_state, RLM.Survey.init_state())
      |> RLM.Survey.pending_required()
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == RLM.Survey.dispatch_quality_id()))

    case tracked_ids do
      [] ->
        Enum.sort(pending)

      _ ->
        tracked = MapSet.new(tracked_ids)
        pending |> Enum.filter(&MapSet.member?(tracked, &1)) |> Enum.sort()
    end
  end
end
