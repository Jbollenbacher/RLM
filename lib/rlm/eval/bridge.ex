defmodule RLM.Eval.Bridge do
  @moduledoc false

  alias RLM.Eval.Codec

  @default_sample_rate 0.25

  @spec start(keyword(), keyword()) :: map() | nil
  def start(bindings, opts) when is_list(bindings) and is_list(opts) do
    case Keyword.get(bindings, :lm_query) do
      lm_query_fn when is_function(lm_query_fn, 2) ->
        parent_agent_id =
          Keyword.get(opts, :parent_agent_id) || RLM.Helpers.unique_id("eval_agent")

        timeout_ms = Keyword.fetch!(opts, :lm_query_timeout)

        sample_rate =
          opts
          |> Keyword.get(:subagent_assessment_sample_rate, @default_sample_rate)
          |> normalize_sample_rate()

        base_dir = Path.join(System.tmp_dir!(), RLM.Helpers.unique_id("rlm_python_bridge"))
        requests_dir = Path.join(base_dir, "requests")
        responses_dir = Path.join(base_dir, "responses")
        File.mkdir_p!(requests_dir)
        File.mkdir_p!(responses_dir)

        pid =
          spawn_link(fn ->
            bridge_loop(
              requests_dir,
              responses_dir,
              lm_query_fn,
              timeout_ms,
              sample_rate,
              parent_agent_id
            )
          end)

        %{pid: pid, dir: base_dir, timeout_ms: timeout_ms}

      _ ->
        nil
    end
  end

  @spec stop(map() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(%{pid: pid, dir: dir}) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, {:stop, self()})

      receive do
        {:bridge_stopped, ^pid} ->
          :ok

        {:DOWN, ^ref, :process, ^pid, _reason} ->
          :ok
      after
        500 ->
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          after
            200 -> :ok
          end
      end

      Process.demonitor(ref, [:flush])
    end

    _ = File.rm_rf(dir)
    :ok
  end

  defp bridge_loop(
         requests_dir,
         responses_dir,
         lm_query_fn,
         default_timeout_ms,
         sample_rate,
         parent_agent_id
       ) do
    receive do
      {:stop, caller} ->
        send(caller, {:bridge_stopped, self()})
        :ok

      :stop ->
        :ok
    after
      15 ->
        process_requests(
          requests_dir,
          responses_dir,
          lm_query_fn,
          default_timeout_ms,
          sample_rate,
          parent_agent_id
        )

        bridge_loop(
          requests_dir,
          responses_dir,
          lm_query_fn,
          default_timeout_ms,
          sample_rate,
          parent_agent_id
        )
    end
  end

  defp process_requests(
         requests_dir,
         responses_dir,
         lm_query_fn,
         default_timeout_ms,
         sample_rate,
         parent_agent_id
       ) do
    case File.ls(requests_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(fn file ->
          request_path = Path.join(requests_dir, file)
          response_path = Path.join(responses_dir, file)

          with {:ok, raw} <- File.read(request_path),
               {:ok, payload} <- Jason.decode(raw) do
            result =
              handle_request(
                payload,
                lm_query_fn,
                default_timeout_ms,
                sample_rate,
                parent_agent_id
              )

            _ = write_json_atomic(response_path, result)
            _ = File.rm(request_path)
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_request(payload, lm_query_fn, default_timeout_ms, sample_rate, parent_agent_id)
       when is_map(payload) do
    op = payload |> Map.get("op", "dispatch") |> to_string()

    case op do
      "dispatch" ->
        handle_dispatch(payload, lm_query_fn, default_timeout_ms, sample_rate, parent_agent_id)

      "poll" ->
        handle_poll(payload, parent_agent_id)

      "cancel" ->
        handle_cancel(payload, parent_agent_id)

      "assess" ->
        handle_assess(payload, parent_agent_id)

      "answer_survey" ->
        handle_answer_survey(payload, parent_agent_id)

      _ ->
        error_payload("Malformed lm_query request: unsupported op `#{op}`")
    end
  rescue
    e ->
      error_payload(Exception.message(e))
  end

  defp handle_request(_payload, _lm_query_fn, _default_timeout_ms, _sample_rate, _parent_agent_id) do
    error_payload("Malformed lm_query request")
  end

  defp handle_dispatch(
         %{"text" => text, "model_size" => model_size} = payload,
         lm_query_fn,
         default_timeout_ms,
         sample_rate,
         parent_agent_id
       )
       when is_binary(text) and is_binary(parent_agent_id) do
    timeout_ms = parse_timeout_ms(Map.get(payload, "timeout_ms"), default_timeout_ms)
    child_agent_id = Map.get(payload, "child_agent_id", RLM.Helpers.unique_id("agent"))
    assessment_sampled = sample_assessment?(sample_rate)

    lm_opts = [
      model_size: parse_model_size(model_size),
      child_agent_id: child_agent_id,
      assessment_sampled: assessment_sampled
    ]

    case RLM.Subagent.Broker.dispatch(parent_agent_id, text, lm_opts, lm_query_fn,
           timeout_ms: timeout_ms,
           assessment_sampled: assessment_sampled
         ) do
      {:ok, returned_child_agent_id} ->
        ok_payload(returned_child_agent_id)

      {:error, reason} ->
        error_payload(reason)
    end
  end

  defp handle_dispatch(
         _payload,
         _lm_query_fn,
         _default_timeout_ms,
         _sample_rate,
         _parent_agent_id
       ) do
    error_payload("Malformed lm_query dispatch request")
  end

  defp handle_poll(%{"child_agent_id" => child_agent_id}, parent_agent_id)
       when is_binary(child_agent_id) and is_binary(parent_agent_id) do
    case RLM.Subagent.Broker.poll(parent_agent_id, child_agent_id) do
      {:ok, state} -> ok_payload(state)
      {:error, reason} -> error_payload(reason)
    end
  end

  defp handle_poll(_payload, _parent_agent_id),
    do: error_payload("Malformed poll_lm_query request")

  defp handle_cancel(%{"child_agent_id" => child_agent_id}, parent_agent_id)
       when is_binary(child_agent_id) and is_binary(parent_agent_id) do
    case RLM.Subagent.Broker.cancel(parent_agent_id, child_agent_id) do
      {:ok, state} -> ok_payload(state)
      {:error, reason} -> error_payload(reason)
    end
  end

  defp handle_cancel(_payload, _parent_agent_id),
    do: error_payload("Malformed cancel_lm_query request")

  defp handle_assess(
         %{"child_agent_id" => child_agent_id, "verdict" => verdict} = payload,
         parent_agent_id
       )
       when is_binary(child_agent_id) and is_binary(parent_agent_id) do
    reason = Map.get(payload, "reason", "") |> to_string()

    with {:ok, parsed_verdict} <- parse_assessment_verdict(verdict) do
      answer_child_survey(
        parent_agent_id,
        child_agent_id,
        RLM.Survey.subagent_usefulness_id(),
        parsed_verdict,
        reason
      )
    else
      {:error, reason} -> error_payload(reason)
    end
  end

  defp handle_assess(_payload, _parent_agent_id),
    do: error_payload("Malformed assess_lm_query request")

  defp handle_answer_survey(
         %{
           "child_agent_id" => child_agent_id,
           "survey_id" => survey_id,
           "response" => response
         } = payload,
         parent_agent_id
       )
       when is_binary(child_agent_id) and is_binary(parent_agent_id) and is_binary(survey_id) do
    reason = Map.get(payload, "reason", "") |> to_string()

    answer_child_survey(parent_agent_id, child_agent_id, survey_id, response, reason)
  end

  defp handle_answer_survey(_payload, _parent_agent_id),
    do: error_payload("Malformed answer_survey request")

  defp answer_child_survey(parent_agent_id, child_agent_id, survey_id, response, reason) do
    case RLM.Subagent.Broker.answer_survey(
           parent_agent_id,
           child_agent_id,
           survey_id,
           response,
           reason
         ) do
      {:ok, state} ->
        {resolved_response, resolved_reason} = resolved_answer(state, survey_id, response, reason)

        maybe_emit_survey_answer(
          parent_agent_id,
          child_agent_id,
          survey_id,
          resolved_response,
          resolved_reason
        )

        ok_payload(state)

      {:error, reason} ->
        error_payload(reason)
    end
  end

  defp resolved_answer(state, survey_id, response, reason) do
    survey_response =
      state
      |> Map.get(:answered_surveys, [])
      |> Enum.find(fn item -> Map.get(item, :id) == survey_id end)

    resolved_response =
      if survey_response, do: Map.get(survey_response, :response), else: response

    resolved_reason = if survey_response, do: Map.get(survey_response, :reason), else: reason
    {resolved_response, resolved_reason}
  end

  defp maybe_emit_survey_answer(
         parent_agent_id,
         child_agent_id,
         survey_id,
         resolved_response,
         resolved_reason
       ) do
    emit_generic_child_survey_answer(
      parent_agent_id,
      child_agent_id,
      survey_id,
      resolved_response,
      resolved_reason
    )
  end

  defp emit_generic_child_survey_answer(
         parent_agent_id,
         child_agent_id,
         survey_id,
         response,
         reason
       ) do
    RLM.Observability.survey_answered(parent_agent_id, survey_id, response, %{
      child_agent_id: child_agent_id,
      reason: reason,
      scope: :child
    })
  end

  defp ok_payload(value), do: %{"status" => "ok", "payload" => Codec.json_term(value)}
  defp error_payload(reason), do: %{"status" => "error", "payload" => Codec.json_term(reason)}

  defp write_json_atomic(path, payload) do
    tmp = path <> ".tmp"

    with encoded <- Jason.encode!(payload),
         :ok <- File.write(tmp, encoded),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(tmp)
        error
    end
  end

  defp parse_model_size(size) when is_atom(size) and size in [:small, :large], do: size

  defp parse_model_size(size) when is_binary(size) do
    case size |> String.trim() |> String.trim_leading(":") |> String.downcase() do
      "large" -> :large
      _ -> :small
    end
  end

  defp parse_model_size(_), do: :small

  defp parse_timeout_ms(timeout, _default_timeout_ms) when is_integer(timeout) and timeout > 0,
    do: timeout

  defp parse_timeout_ms(timeout, default_timeout_ms) when is_binary(timeout) do
    case Integer.parse(timeout) do
      {value, _} when value > 0 -> value
      _ -> normalize_timeout(default_timeout_ms)
    end
  end

  defp parse_timeout_ms(_timeout, default_timeout_ms), do: normalize_timeout(default_timeout_ms)

  defp normalize_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout(_timeout), do: 180_000

  defp parse_assessment_verdict(verdict) do
    case RLM.Survey.parse_verdict(verdict) do
      {:ok, parsed} ->
        {:ok, parsed}

      :error when is_binary(verdict) ->
        other = verdict |> String.trim() |> String.downcase()
        {:error, "Invalid verdict `#{other}`. Use `satisfied` or `dissatisfied`."}

      :error ->
        {:error, "Invalid verdict. Use `satisfied` or `dissatisfied`."}
    end
  end

  defp sample_assessment?(rate) do
    normalized = normalize_sample_rate(rate)
    normalized > 0 and :rand.uniform() <= normalized
  end

  defp normalize_sample_rate(rate) when is_float(rate), do: clamp_sample_rate(rate)
  defp normalize_sample_rate(rate) when is_integer(rate), do: clamp_sample_rate(rate * 1.0)

  defp normalize_sample_rate(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {parsed, _} -> clamp_sample_rate(parsed)
      _ -> @default_sample_rate
    end
  end

  defp normalize_sample_rate(_), do: @default_sample_rate

  defp clamp_sample_rate(rate) when rate < 0.0, do: 0.0
  defp clamp_sample_rate(rate) when rate > 1.0, do: 1.0
  defp clamp_sample_rate(rate), do: rate
end
