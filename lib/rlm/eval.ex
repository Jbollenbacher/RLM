defmodule RLM.Eval do
  @spec eval(String.t(), keyword(), keyword()) ::
          {:ok, String.t(), any(), keyword()}
          | {:error, String.t(), keyword()}
  def eval(code, bindings, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
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

        try do
          {result, new_bindings} =
            Code.eval_string(wrapped_code, bindings, file: "rlm_repl", line: 0)

          send(caller, {:eval_result, :ok, result, new_bindings})
        rescue
          e ->
            formatted = Exception.format(:error, e, __STACKTRACE__)
            IO.write(stdout_device, formatted)
            send(caller, {:eval_result, :error, formatted, bindings})
        catch
          kind, value ->
            formatted = Exception.format(kind, value, __STACKTRACE__)
            IO.write(stdout_device, formatted)
            send(caller, {:eval_result, :error, formatted, bindings})
        end
      end)

    ref = Process.monitor(pid)

    receive do
      {:eval_result, :ok, result, new_bindings} ->
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        StringIO.close(stdout_device)
        {:ok, stdout, result, new_bindings}

      {:eval_result, :error, _formatted, original_bindings} ->
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        StringIO.close(stdout_device)
        {:error, stdout, original_bindings}

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
end
