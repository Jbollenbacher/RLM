defmodule RLM.Eval do
  @python_prelude File.read!(Path.join(:code.priv_dir(:rlm), "python_prelude.py"))

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
      fn ->
        do_eval(code, bindings, timeout)
      end,
      &eval_status/1
    )
  end

  defp do_eval(code, bindings, timeout) do
    {:ok, stdout_device} = StringIO.open("")
    {:ok, stderr_device} = StringIO.open("")
    caller = self()

    pid =
      spawn(fn ->
        bridge = start_lm_query_bridge(bindings, timeout)

        try do
          with :ok <- ensure_pythonx_runtime() do
            globals = build_globals(bindings, bridge)
            wrapped_code = python_prelude() <> "\n" <> code

            {result, python_globals} =
              Pythonx.eval(wrapped_code, globals,
                stdout_device: stdout_device,
                stderr_device: stderr_device
              )

            decoded_result = decode_term(result)
            captured_output = decode_captured_output(python_globals)

            final_answer =
              python_globals
              |> Map.get("final_answer")
              |> decode_term()
              |> normalize_final_answer()

            new_bindings =
              bindings
              |> Keyword.put(:python_globals, prune_internal_globals(python_globals))
              |> Keyword.put(:final_answer, final_answer)

            send(caller, {:eval_result, :ok, decoded_result, new_bindings, captured_output})
          else
            {:error, reason} ->
              send(caller, {:eval_result, :error, reason, bindings})
          end
        rescue
          e in Pythonx.Error ->
            formatted = format_python_exception(e)
            send(caller, {:eval_result, :error, formatted, bindings})

          e ->
            formatted = Exception.format(:error, e, __STACKTRACE__)
            send(caller, {:eval_result, :error, formatted, bindings})
        catch
          kind, value ->
            formatted = Exception.format(kind, value, __STACKTRACE__)
            send(caller, {:eval_result, :error, formatted, bindings})
        after
          stop_lm_query_bridge(bridge)
        end
      end)

    ref = Process.monitor(pid)

    receive do
      {:eval_result, :ok, result, new_bindings, captured_output} ->
        Process.demonitor(ref, [:flush])
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:ok, captured_output <> stdout <> stderr, result, new_bindings}

      {:eval_result, :error, formatted, original_bindings} ->
        Process.demonitor(ref, [:flush])
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:error, stdout <> stderr <> formatted, original_bindings}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:error, "Process crashed: #{inspect(reason)}\n#{stdout}#{stderr}", bindings}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {stdout, stderr} = collect_output(stdout_device, stderr_device)
        {:error, "Evaluation timed out after #{timeout}ms\n#{stdout}#{stderr}", bindings}
    end
  end

  defp eval_status({:ok, _stdout, _result, _bindings}), do: :ok
  defp eval_status(_), do: :error

  defp build_globals(bindings, bridge) do
    persisted = Keyword.get(bindings, :python_globals, %{})

    current =
      bindings
      |> Enum.reject(fn {key, _value} -> key in [:lm_query, :python_globals] end)
      |> Enum.into(%{}, fn {key, value} -> {Atom.to_string(key), value} end)

    bridge_globals = %{
      "_rlm_bridge_dir" => if(bridge, do: bridge.dir, else: nil),
      "_rlm_bridge_timeout_ms" => if(bridge, do: bridge.timeout_ms, else: nil)
    }

    persisted
    |> Map.merge(current)
    |> Map.merge(bridge_globals)
  end

  defp start_lm_query_bridge(bindings, timeout) do
    case Keyword.get(bindings, :lm_query) do
      lm_query_fn when is_function(lm_query_fn, 2) ->
        base_dir = Path.join(System.tmp_dir!(), RLM.Helpers.unique_id("rlm_python_bridge"))
        requests_dir = Path.join(base_dir, "requests")
        responses_dir = Path.join(base_dir, "responses")
        File.mkdir_p!(requests_dir)
        File.mkdir_p!(responses_dir)

        pid = spawn_link(fn -> bridge_loop(requests_dir, responses_dir, lm_query_fn) end)
        %{pid: pid, dir: base_dir, timeout_ms: timeout}

      _ ->
        nil
    end
  end

  defp stop_lm_query_bridge(nil), do: :ok

  defp stop_lm_query_bridge(%{pid: pid, dir: dir}) do
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

  defp bridge_loop(requests_dir, responses_dir, lm_query_fn) do
    receive do
      {:stop, caller} ->
        send(caller, {:bridge_stopped, self()})
        :ok

      :stop ->
        :ok
    after
      15 ->
        process_requests(requests_dir, responses_dir, lm_query_fn)
        bridge_loop(requests_dir, responses_dir, lm_query_fn)
    end
  end

  defp process_requests(requests_dir, responses_dir, lm_query_fn) do
    case File.ls(requests_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.each(fn file ->
          request_path = Path.join(requests_dir, file)
          response_path = Path.join(responses_dir, file)

          with {:ok, raw} <- File.read(request_path),
               {:ok, payload} <- Jason.decode(raw) do
            result = handle_lm_query_request(payload, lm_query_fn)
            _ = write_json_atomic(response_path, result)
            _ = File.rm(request_path)
          end
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp handle_lm_query_request(%{"text" => text, "model_size" => model_size}, lm_query_fn)
       when is_binary(text) do
    opts = [model_size: parse_model_size(model_size)]

    case lm_query_fn.(text, opts) do
      {:ok, payload} -> %{"status" => "ok", "payload" => json_term(payload)}
      {:error, reason} -> %{"status" => "error", "payload" => json_term(reason)}
      other -> %{"status" => "error", "payload" => "Invalid lm_query return: #{inspect(other)}"}
    end
  rescue
    e ->
      %{"status" => "error", "payload" => Exception.message(e)}
  end

  defp handle_lm_query_request(_payload, _lm_query_fn) do
    %{"status" => "error", "payload" => "Malformed lm_query request"}
  end

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
    size
    |> String.trim()
    |> String.trim_leading(":")
    |> String.downcase()
    |> case do
      "large" -> :large
      _ -> :small
    end
  end

  defp parse_model_size(_), do: :small

  defp json_term(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_term(value) when is_atom(value), do: Atom.to_string(value)
  defp json_term(value) when is_list(value), do: Enum.map(value, &json_term/1)

  defp json_term(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&json_term/1)

  defp json_term(value) when is_map(value) do
    Enum.into(value, %{}, fn {k, v} ->
      {to_string(k), json_term(v)}
    end)
  end

  defp json_term(value), do: inspect(value)

  defp decode_term(nil), do: nil

  defp decode_term(term) do
    Pythonx.decode(term)
  rescue
    _ -> term
  end

  defp normalize_final_answer(nil), do: nil
  defp normalize_final_answer({:ok, _answer} = answer), do: answer
  defp normalize_final_answer({:error, _reason} = answer), do: answer
  defp normalize_final_answer({"ok", answer}), do: {:ok, answer}
  defp normalize_final_answer({"error", reason}), do: {:error, reason}
  defp normalize_final_answer([status, payload]), do: normalize_final_answer({status, payload})

  defp normalize_final_answer(%{"status" => status, "payload" => payload}) do
    normalize_final_answer({status, payload})
  end

  defp normalize_final_answer(other), do: {:invalid, other}

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
      "_rlm_bridge_timeout_ms"
    ])
  end

  defp decode_captured_output(python_globals) when is_map(python_globals) do
    stdout = python_globals |> Map.get("_rlm_stdout_buffer") |> decode_output_chunks()
    stderr = python_globals |> Map.get("_rlm_stderr_buffer") |> decode_output_chunks()
    stdout <> stderr
  end

  defp decode_output_chunks(nil), do: ""

  defp decode_output_chunks(chunks) do
    chunks
    |> decode_term()
    |> normalize_output_chunks()
  end

  defp normalize_output_chunks(chunks) when is_list(chunks) do
    Enum.map_join(chunks, "", &chunk_to_string/1)
  end

  defp normalize_output_chunks(other), do: chunk_to_string(other)

  defp chunk_to_string(chunk) when is_binary(chunk), do: chunk

  defp chunk_to_string(chunk) when is_list(chunk) do
    chunk
    |> List.to_string()
  rescue
    _ -> inspect(chunk)
  end

  defp chunk_to_string(chunk) do
    to_string(chunk)
  rescue
    _ -> inspect(chunk)
  end

  defp format_python_exception(error) do
    error
    |> Exception.message()
    |> String.replace_prefix("Python exception raised\n\n", "")
    |> String.replace(~r/^ {8}/m, "")
    |> String.trim_trailing()
  end

  defp python_prelude, do: @python_prelude
end
