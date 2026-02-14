defmodule RLM.Eval do
  @default_eval_timeout_ms 30_000

  alias RLM.Eval.{Bridge, Codec}

  @spec eval(String.t(), keyword(), keyword()) ::
          {:ok, String.t(), String.t(), any(), keyword()}
          | {:error, String.t(), String.t(), keyword()}
  def eval(code, bindings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, default_eval_timeout_ms())
    lm_query_timeout = Keyword.get(opts, :lm_query_timeout, default_lm_query_timeout_ms())

    subagent_assessment_sample_rate =
      Keyword.get(
        opts,
        :subagent_assessment_sample_rate,
        default_subagent_assessment_sample_rate()
      )

    agent_id = Keyword.get(opts, :agent_id)
    iteration = Keyword.get(opts, :iteration)
    code_text = to_string(code)
    code_preview = RLM.Truncate.truncate(code_text, head: 220, tail: 220)

    RLM.Observability.span(
      :eval,
      %{
        agent_id: agent_id,
        iteration: iteration,
        code_bytes: byte_size(code_text),
        code_preview: code_preview
      },
      fn ->
        do_eval(
          code,
          bindings,
          timeout,
          lm_query_timeout,
          subagent_assessment_sample_rate,
          agent_id
        )
      end,
      &eval_status/1
    )
  end

  defp do_eval(
         code,
         bindings,
         timeout,
         lm_query_timeout,
         subagent_assessment_sample_rate,
         agent_id
       ) do
    {:ok, stdout_device} = StringIO.open("")
    {:ok, stderr_device} = StringIO.open("")
    caller = self()

    pid =
      spawn(fn ->
        bridge =
          Bridge.start(bindings,
            lm_query_timeout: lm_query_timeout,
            subagent_assessment_sample_rate: subagent_assessment_sample_rate,
            parent_agent_id: agent_id
          )

        try do
          with :ok <- ensure_pythonx_runtime() do
            globals = build_globals(bindings, bridge)
            wrapped_code = python_prelude() <> "\n" <> code

            {result, python_globals} =
              Pythonx.eval(wrapped_code, globals,
                stdout_device: stdout_device,
                stderr_device: stderr_device
              )

            decoded_result = Codec.decode_term(result)
            {captured_stdout, captured_stderr} = Codec.decode_captured_output(python_globals)

            final_answer =
              python_globals
              |> Map.get("final_answer")
              |> Codec.decode_term()
              |> Codec.normalize_final_answer()

            survey_answers =
              python_globals
              |> Map.get("_rlm_survey_answers")
              |> Codec.decode_term()
              |> Codec.normalize_survey_answers()

            survey_state =
              bindings
              |> Keyword.get(:survey_state, RLM.Survey.init_state())
              |> RLM.Survey.merge_answers(survey_answers)

            dispatch_assessment =
              RLM.Survey.dispatch_assessment(survey_state)

            RLM.Observability.local_survey_answers(
              agent_id,
              Keyword.get(bindings, :parent_agent_id),
              Keyword.get(bindings, :dispatch_assessment_required, false) == true,
              survey_answers
            )

            new_bindings =
              bindings
              |> Keyword.put(:python_globals, prune_internal_globals(python_globals))
              |> Keyword.put(:final_answer, final_answer)
              |> Keyword.put(:survey_state, survey_state)
              |> Keyword.put(:dispatch_assessment, dispatch_assessment)

            send(
              caller,
              {:eval_result, :ok, decoded_result, new_bindings, captured_stdout, captured_stderr}
            )
          else
            {:error, reason} ->
              send(caller, {:eval_result, :error, reason, bindings})
          end
        rescue
          e in Pythonx.Error ->
            formatted = Codec.format_python_exception(e)
            send(caller, {:eval_result, :error, formatted, bindings})

          e ->
            formatted = Exception.format(:error, e, __STACKTRACE__)
            send(caller, {:eval_result, :error, formatted, bindings})
        catch
          kind, value ->
            formatted = Exception.format(kind, value, __STACKTRACE__)
            send(caller, {:eval_result, :error, formatted, bindings})
        after
          Bridge.stop(bridge)
        end
      end)

    ref = Process.monitor(pid)

    receive do
      {:eval_result, :ok, result, new_bindings, captured_stdout, captured_stderr} ->
        Process.demonitor(ref, [:flush])
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:ok, captured_stdout <> stdout, captured_stderr <> stderr, result, new_bindings}

      {:eval_result, :error, formatted, original_bindings} ->
        Process.demonitor(ref, [:flush])
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:error, stdout, stderr <> formatted, original_bindings}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:error, stdout, "Process crashed: #{inspect(reason)}\n#{stderr}", bindings}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:error, stdout, "Evaluation timed out after #{timeout}ms\n#{stderr}", bindings}
    end
  end

  defp eval_status({:ok, _stdout, _stderr, _result, _bindings}), do: :ok
  defp eval_status(_), do: :error

  defp build_globals(bindings, bridge) do
    persisted = Keyword.get(bindings, :python_globals, %{})

    current =
      bindings
      |> Enum.reject(fn {key, _value} ->
        key in [
          :lm_query,
          :python_globals,
          :pending_final_answer,
          :dispatch_assessment_checkin_deadline_iteration,
          :pending_subagent_final_answer,
          :pending_subagent_assessment_child_ids,
          :subagent_assessment_checkin_deadline_iteration,
          :pending_required_survey_final_answer,
          :pending_required_survey_ids,
          :required_survey_checkin_deadline_iteration
        ]
      end)
      |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), value} end)

    bridge_globals = %{
      "_rlm_bridge_dir" => if(bridge, do: bridge.dir, else: nil),
      "_rlm_bridge_timeout_ms" => if(bridge, do: bridge.timeout_ms, else: nil)
    }

    persisted
    |> Map.merge(current)
    |> Map.merge(bridge_globals)
  end

  defp ensure_pythonx_runtime do
    case Application.ensure_all_started(:pythonx) do
      {:ok, _apps} ->
        :ok

      {:error, {app, reason}} ->
        {:error, "Failed to start #{app}: #{inspect(reason)}"}
    end
  end

  defp collect_output(stdout_device, stderr_device) do
    {_, stdout} = StringIO.contents(stdout_device)
    {_, stderr} = StringIO.contents(stderr_device)
    StringIO.close(stdout_device)
    StringIO.close(stderr_device)
    {stdout, stderr}
  end

  defp prune_internal_globals(python_globals) when is_map(python_globals) do
    Map.drop(python_globals, [
      "_rlm_stdout_buffer",
      "_rlm_stderr_buffer",
      "_rlm_bridge_dir",
      "_rlm_bridge_timeout_ms",
      "_rlm_survey_answers"
    ])
  end

  defp default_eval_timeout_ms do
    Application.get_env(:rlm, :eval_timeout, @default_eval_timeout_ms)
  end

  defp default_lm_query_timeout_ms do
    Application.get_env(:rlm, :lm_query_timeout, default_eval_timeout_ms())
  end

  defp default_subagent_assessment_sample_rate do
    :rlm
    |> Application.get_env(:subagent_assessment_sample_rate, 0.25)
    |> normalize_sample_rate()
  end

  defp normalize_sample_rate(rate) when is_float(rate), do: clamp_sample_rate(rate)
  defp normalize_sample_rate(rate) when is_integer(rate), do: clamp_sample_rate(rate * 1.0)

  defp normalize_sample_rate(rate) when is_binary(rate) do
    case Float.parse(rate) do
      {parsed, _} -> clamp_sample_rate(parsed)
      _ -> 0.25
    end
  end

  defp normalize_sample_rate(_), do: 0.25

  defp clamp_sample_rate(rate) when rate < 0.0, do: 0.0
  defp clamp_sample_rate(rate) when rate > 1.0, do: 1.0
  defp clamp_sample_rate(rate), do: rate

  defp python_prelude do
    File.read!(Path.join(:code.priv_dir(:rlm), "python_prelude.py"))
  end
end
