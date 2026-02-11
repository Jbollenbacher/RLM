defmodule RLM.Eval do
  @spec eval(String.t(), keyword(), keyword()) ::
          {:ok, String.t(), any(), keyword()}
          | {:error, String.t(), keyword()}
  def eval(code, bindings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    agent_id = Keyword.get(opts, :agent_id)
    iteration = Keyword.get(opts, :iteration)

    RLM.Observability.span(
      :eval,
      %{agent_id: agent_id, iteration: iteration},
      fn -> do_eval(code, bindings, timeout) end,
      &eval_status/1
    )
  end

  defp do_eval(code, bindings, timeout) do
    {:ok, stdout_device} = StringIO.open("")
    caller = self()

    # Wrap user code with sandbox import
    wrapped_code = "import RLM.Sandbox\n#{code}"

    pid =
      spawn(fn ->
        Process.group_leader(self(), stdout_device)

        # Set process dictionary for Sandbox functions that need runtime state
        Process.put(:rlm_bindings_info, RLM.Helpers.list_bindings(bindings))

        if lm_query_fn = Keyword.get(bindings, :lm_query) do
          Process.put(:rlm_lm_query_fn, lm_query_fn)
        end

        if workspace_root = Keyword.get(bindings, :workspace_root) do
          Process.put(:rlm_workspace_root, workspace_root)
        end

        Process.put(:rlm_workspace_read_only, Keyword.get(bindings, :workspace_read_only, false))

        try do
          {{result, new_bindings}, diagnostics} =
            Code.with_diagnostics(fn ->
              Code.eval_string(wrapped_code, bindings, file: "rlm_repl", line: 0)
            end)

          diagnostics_text = format_diagnostics(diagnostics)
          send(caller, {:eval_result, :ok, result, new_bindings, diagnostics_text})
        rescue
          e ->
            formatted = Exception.format(:error, e, __STACKTRACE__)
            send(caller, {:eval_result, :error, formatted, bindings, ""})
        catch
          kind, value ->
            formatted = Exception.format(kind, value, __STACKTRACE__)
            send(caller, {:eval_result, :error, formatted, bindings, ""})
        end
      end)

    ref = Process.monitor(pid)

    receive do
      {:eval_result, :ok, result, new_bindings, diagnostics_text} ->
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        StringIO.close(stdout_device)
        {:ok, stdout <> diagnostics_text, result, new_bindings}

      {:eval_result, :error, formatted, original_bindings, diagnostics_text} ->
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        StringIO.close(stdout_device)
        {:error, stdout <> diagnostics_text <> formatted, original_bindings}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {_, stdout} = StringIO.contents(stdout_device)
        StringIO.close(stdout_device)
        {:error, "Process crashed: #{inspect(reason)}\n#{stdout}", bindings}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        StringIO.close(stdout_device)
        {:error, "Evaluation timed out after #{timeout}ms\n#{stdout}", bindings}
    end
  end

  defp eval_status({:ok, _stdout, _result, _bindings}), do: :ok
  defp eval_status(_), do: :error

  defp format_diagnostics([]), do: ""

  defp format_diagnostics(diagnostics) do
    Enum.map_join(diagnostics, "\n", fn diag ->
      file = diag[:file] || diag[:source] || "unknown"
      {line, col} = diag[:position] || {nil, nil}

      location =
        case {line, col} do
          {nil, _} -> file
          {line, nil} -> "#{file}:#{line}"
          {line, col} -> "#{file}:#{line}:#{col}"
        end

      severity = diag[:severity] || :warning
      message = diag[:message] || "diagnostic"
      "#{severity}: #{message}\n  #{location}"
    end) <> "\n"
  end
end
