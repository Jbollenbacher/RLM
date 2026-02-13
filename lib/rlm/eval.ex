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
          globals = build_globals(bindings, bridge)
          wrapped_code = python_prelude() <> "\n" <> code

          {result, python_globals} =
            Pythonx.eval(wrapped_code, globals,
              stdout_device: stdout_device,
              stderr_device: stderr_device
            )

          decoded_result = decode_term(result)

          final_answer =
            python_globals
            |> Map.get("final_answer")
            |> decode_term()
            |> normalize_final_answer()

          new_bindings =
            bindings
            |> Keyword.put(:python_globals, python_globals)
            |> Keyword.put(:final_answer, final_answer)

          send(caller, {:eval_result, :ok, decoded_result, new_bindings})
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
      {:eval_result, :ok, result, new_bindings} ->
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        {_, stderr} = StringIO.contents(stderr_device)
        StringIO.close(stdout_device)
        StringIO.close(stderr_device)
        {:ok, stdout <> stderr, result, new_bindings}

      {:eval_result, :error, formatted, original_bindings} ->
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        {_, stderr} = StringIO.contents(stderr_device)
        StringIO.close(stdout_device)
        StringIO.close(stderr_device)
        {:error, stdout <> stderr <> formatted, original_bindings}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {_, stdout} = StringIO.contents(stdout_device)
        {_, stderr} = StringIO.contents(stderr_device)
        StringIO.close(stdout_device)
        StringIO.close(stderr_device)
        {:error, "Process crashed: #{inspect(reason)}\n#{stdout}#{stderr}", bindings}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {_, stdout} = StringIO.contents(stdout_device)
        {_, stderr} = StringIO.contents(stderr_device)
        StringIO.close(stdout_device)
        StringIO.close(stderr_device)
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
    if Process.alive?(pid), do: send(pid, :stop)
    _ = File.rm_rf(dir)
    :ok
  end

  defp bridge_loop(requests_dir, responses_dir, lm_query_fn) do
    receive do
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
            write_json_atomic(response_path, result)
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
    encoded = Jason.encode!(payload)
    File.write!(tmp, encoded)
    File.rename(tmp, path)
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

  defp normalize_final_answer(other), do: other

  defp format_python_exception(error) do
    error
    |> Exception.message()
    |> String.replace_prefix("Python exception raised\n\n", "")
    |> String.replace(~r/^ {8}/m, "")
    |> String.trim_trailing()
  end

  defp python_prelude do
    ~S"""
    import json
    import re
    import time
    from pathlib import Path

    def _rlm_to_text(value):
        if isinstance(value, (bytes, bytearray)):
            return value.decode("utf-8", errors="replace")
        return value

    for _name in ("context", "workspace_root", "compacted_history", "last_stdout", "last_stderr", "_rlm_bridge_dir"):
        if _name in globals():
            globals()[_name] = _rlm_to_text(globals()[_name])

    def grep(pattern, string):
        text = _rlm_to_text(string)
        text = text if isinstance(text, str) else str(text)
        lines = text.split("\n")
        out = []

        if hasattr(pattern, "search"):
            for idx, line in enumerate(lines, 1):
                if pattern.search(line):
                    out.append((idx, line))
            return out

        needle = str(pattern)
        for idx, line in enumerate(lines, 1):
            if needle in line:
                out.append((idx, line))
        return out

    def latest_principal_message(context):
        if not isinstance(context, str):
            return ("error", "No chat entries found in context")
        pattern = re.compile(r"^\[RLM_Principal\]\n(.*?)(?=^\[RLM_(?:Principal|Agent)\]|\Z)", re.M | re.S)
        matches = pattern.findall(context)
        if not matches:
            return ("error", "No chat entries found in context")
        return ("ok", matches[-1].strip())

    def _rlm_workspace_root():
        root = _rlm_to_text(globals().get("workspace_root"))
        if not root:
            raise ValueError("workspace_root not set")
        return Path(root).resolve()

    def _rlm_resolve_workspace_path(path):
        root = _rlm_workspace_root()
        rel = "." if path is None else str(_rlm_to_text(path))
        target = (root / rel).resolve()
        if target != root and root not in target.parents:
            raise ValueError("Path is outside workspace root")
        return root, target

    def ls(path="."):
        try:
            _root, target = _rlm_resolve_workspace_path(path)
            if not target.exists() or not target.is_dir():
                return ("error", "Not a directory")
            entries = []
            for child in sorted(target.iterdir(), key=lambda p: p.name):
                entries.append(child.name + "/" if child.is_dir() else child.name)
            return ("ok", entries)
        except Exception as exc:
            return ("error", str(exc))

    def read_file(path, max_bytes=None):
        try:
            _root, target = _rlm_resolve_workspace_path(path)
            if not target.exists() or not target.is_file():
                return ("error", "Not a file")

            if max_bytes is None:
                return ("ok", target.read_text(encoding="utf-8", errors="replace"))

            n = int(max_bytes)
            if n <= 0:
                return ("error", "max_bytes must be a positive integer or nil")
            with target.open("rb") as f:
                data = f.read(n)
            return ("ok", data.decode("utf-8", errors="replace"))
        except Exception as exc:
            return ("error", str(exc))

    def _rlm_normalize_patch(patch):
        trimmed = patch.strip("\n")
        lines = trimmed.split("\n")
        non_empty = [line for line in lines if line != ""]
        if not non_empty:
            return ""

        min_indent = min(len(line) - len(line.lstrip(" \t")) for line in non_empty)
        if min_indent <= 0:
            return trimmed

        adjusted = []
        for line in lines:
            adjusted.append("" if line == "" else line[min_indent:])
        return "\n".join(adjusted)

    def edit_file(path, patch):
        try:
            if globals().get("workspace_read_only", False):
                return ("error", "Workspace is read-only")

            _root, target = _rlm_resolve_workspace_path(path)
            if not target.exists() or not target.is_file():
                return ("error", "Not a file")

            patch_text = _rlm_normalize_patch(patch)
            regex = re.compile(r"<<<<<<< SEARCH\r?\n(.*?)\r?\n=======\r?\n(.*?)\r?\n>>>>>>> REPLACE", re.S)
            blocks = regex.findall(patch_text)
            if not blocks:
                return ("error", "No edit blocks found. Use <<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE blocks.")

            if regex.sub("", patch_text).strip() != "":
                return ("error", "Patch contains text outside of edit blocks")

            for search, _replace in blocks:
                if search == "":
                    return ("error", "Search blocks cannot be empty")

            content = target.read_text(encoding="utf-8", errors="replace")

            for search, replace in blocks:
                count = content.count(search)
                if count == 0:
                    return ("error", "Search text not found in file")
                if count > 1:
                    return ("error", "Search text matched multiple occurrences. Add more surrounding context to make it unique.")
                content = content.replace(search, replace, 1)

            target.write_text(content, encoding="utf-8")
            return ("ok", f"Applied {len(blocks)} edit(s) to {path}")
        except Exception as exc:
            return ("error", str(exc))

    def create_file(path, content):
        try:
            if globals().get("workspace_read_only", False):
                return ("error", "Workspace is read-only")

            rel = str(_rlm_to_text(path))
            if rel.strip() == "":
                return ("error", "Path must be a non-empty file path")
            if rel.endswith("/"):
                return ("error", "Path must be a file, not a directory")

            _root, target = _rlm_resolve_workspace_path(rel)
            if target.exists() and target.is_dir():
                return ("error", "Path is a directory")

            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open("x", encoding="utf-8") as f:
                f.write(content)
            return ("ok", f"Created {path}")
        except FileExistsError:
            return ("error", "File already exists")
        except Exception as exc:
            return ("error", str(exc))

    def list_bindings():
        excluded = {
            "__builtins__", "json", "re", "time", "Path",
            "grep", "latest_principal_message",
            "ls", "read_file", "edit_file", "create_file",
            "list_bindings", "lm_query"
        }
        out = []
        for name, value in globals().items():
            if name in excluded or name.startswith("_rlm_") or name.startswith("__"):
                continue
            try:
                if isinstance(value, str):
                    size = len(value.encode("utf-8"))
                else:
                    size = len(repr(value).encode("utf-8"))
            except Exception:
                size = 0
            out.append((name, type(value).__name__, size))
        out.sort(key=lambda item: item[0])
        return out

    def _rlm_write_json_atomic(path, payload):
        tmp = path.with_suffix(path.suffix + ".tmp")
        tmp.write_text(json.dumps(payload), encoding="utf-8")
        tmp.replace(path)

    def lm_query(text, model_size="small"):
        bridge_dir = _rlm_to_text(globals().get("_rlm_bridge_dir"))
        if not bridge_dir:
            return ("error", "lm_query not available")

        requests_dir = Path(bridge_dir) / "requests"
        responses_dir = Path(bridge_dir) / "responses"
        request_id = f"{int(time.time() * 1000)}_{time.perf_counter_ns()}"
        request_path = requests_dir / f"{request_id}.json"
        response_path = responses_dir / f"{request_id}.json"
        timeout_ms = int(globals().get("_rlm_bridge_timeout_ms", 30000))

        try:
            _rlm_write_json_atomic(
                request_path,
                {"text": _rlm_to_text(text), "model_size": _rlm_to_text(model_size)}
            )

            deadline = time.time() + (timeout_ms / 1000.0)
            while time.time() < deadline:
                if response_path.exists():
                    data = json.loads(response_path.read_text(encoding="utf-8"))
                    try:
                        response_path.unlink()
                    except Exception:
                        pass
                    return (data.get("status", "error"), data.get("payload"))
                time.sleep(0.01)
        except Exception as exc:
            return ("error", str(exc))

        return ("error", f"lm_query timed out after {timeout_ms}ms")
    """
  end
end
