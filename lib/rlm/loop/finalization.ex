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
        resolve_pending_subagent_finalization(bindings, depth, iteration, agent_id)
    end
  end

  @spec pending_checkin_turn?(keyword(), non_neg_integer()) :: boolean()
  def pending_checkin_turn?(bindings, iteration) do
    pending_dispatch_checkin_turn?(bindings, iteration) or
      pending_subagent_checkin_turn?(bindings, iteration)
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

  @spec continue_pending_dispatch([map()], keyword(), non_neg_integer(), non_neg_integer()) ::
          {[map()], keyword()}
  def continue_pending_dispatch(history, bindings, depth, iteration) do
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

  @spec maybe_stage_subagent_assessments(
          keyword(),
          pending_answer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t() | nil
        ) :: {:stage, keyword(), [String.t()]} | :no_stage
  def maybe_stage_subagent_assessments(bindings, final_answer, depth, iteration, agent_id) do
    pending = pending_subagent_assessments(agent_id)

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
                :ok,
                nil,
                dispatch_assessment_required
              )
              |> clear_pending_dispatch_finalization()

            {:halt, pending, bindings}

          true ->
            {:continue, bindings}
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
                :error,
                nil,
                dispatch_assessment_required
              )
              |> clear_pending_dispatch_finalization()

            {:halt, pending, bindings}

          true ->
            {:continue, bindings}
        end

      _ ->
        {:continue, bindings}
    end
  end

  defp resolve_pending_subagent_finalization(bindings, depth, iteration, agent_id) do
    deadline = Keyword.get(bindings, :subagent_assessment_checkin_deadline_iteration, iteration)
    tracked_child_ids = Keyword.get(bindings, :pending_subagent_assessment_child_ids, [])

    case Keyword.get(bindings, :pending_subagent_final_answer) do
      {:ok, _answer} = pending ->
        resolve_subagent_pending(
          bindings,
          pending,
          depth,
          iteration,
          deadline,
          agent_id,
          tracked_child_ids
        )

      {:error, _reason} = pending ->
        resolve_subagent_pending(
          bindings,
          pending,
          depth,
          iteration,
          deadline,
          agent_id,
          tracked_child_ids
        )

      _ ->
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
    remaining = pending_subagent_assessments(agent_id, tracked_child_ids)
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

        emit_subagent_assessment_missing(agent_id, tracked_child_ids)
        {:halt, pending, clear_pending_subagent_finalization(bindings)}

      true ->
        {:continue, bindings}
    end
  end

  defp pending_status_label({:ok, _}), do: "answer"
  defp pending_status_label({:error, _}), do: "failure"

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
        Enum.filter(pending, &MapSet.member?(tracked, Map.get(&1, :child_agent_id)))
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
          Enum.filter(pending, &MapSet.member?(tracked, Map.get(&1, :child_agent_id)))
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

  defp pending_dispatch_checkin_turn?(bindings, iteration) do
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
end
