defmodule RLM.Helpers do
  @spec chunks(String.t(), pos_integer()) :: Enumerable.t()
  def chunks(string, size) when is_binary(string) and is_integer(size) and size > 0 do
    Stream.unfold(string, fn
      "" -> nil
      s -> {String.slice(s, 0, size), String.slice(s, size..-1//1)}
    end)
  end

  @spec grep(String.t() | Regex.t(), String.t()) :: [{pos_integer(), String.t()}]
  def grep(pattern, string) when is_binary(string) do
    string
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _idx} -> matches?(pattern, line) end)
    |> Enum.map(fn {line, idx} -> {idx, line} end)
  end

  @spec preview(any(), pos_integer()) :: String.t()
  def preview(term, n \\ 500) do
    term
    |> inspect(limit: :infinity, printable_limit: :infinity, pretty: true)
    |> String.slice(0, n)
  end

  @spec list_bindings(keyword()) :: [{atom(), String.t(), non_neg_integer()}]
  def list_bindings(bindings) when is_list(bindings) do
    bindings
    |> Enum.reject(fn {name, _value} -> name in [:workspace_root, :workspace_read_only] end)
    |> Enum.map(fn {name, value} ->
      {name, type_of(value), term_size(value)}
    end)
  end

  @spec ls(String.t() | nil, String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def ls(root, path \\ ".") do
    with {:ok, resolved} <- resolve_workspace_path(root, path),
         true <- File.dir?(resolved) || {:error, "Not a directory"} do
      entries =
        resolved
        |> File.ls!()
        |> Enum.map(fn entry ->
          if File.dir?(Path.join(resolved, entry)), do: entry <> "/", else: entry
        end)
        |> Enum.sort()

      {:ok, entries}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec read_file(String.t() | nil, String.t(), pos_integer() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def read_file(root, path, max_bytes \\ nil) do
    with {:ok, resolved} <- resolve_workspace_path(root, path),
         true <- File.regular?(resolved) || {:error, "Not a file"} do
      case max_bytes do
        nil ->
          File.read(resolved)

        n when is_integer(n) and n > 0 ->
          read_bytes(resolved, n)

        _ ->
          {:error, "max_bytes must be a positive integer or nil"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec edit_file(String.t() | nil, String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def edit_file(root, path, patch) when is_binary(path) and is_binary(patch) do
    with {:ok, resolved} <- resolve_workspace_path(root, path),
         true <- File.regular?(resolved) || {:error, "Not a file"},
         {:ok, edits} <- parse_edit_blocks(patch),
         {:ok, content} <- File.read(resolved),
         {:ok, updated} <- apply_edit_blocks(content, edits),
         :ok <- File.write(resolved, updated) do
      {:ok, "Applied #{length(edits)} edit(s) to #{path}"}
    else
      {:error, reason} -> {:error, format_file_error(reason)}
    end
  end

  def edit_file(_root, _path, _patch), do: {:error, "path and patch must be strings"}


  @chat_user_marker "[RLM_User]"
  @chat_assistant_marker "[RLM_Assistant]"

  @spec chat_marker(:user | :assistant) :: String.t()
  def chat_marker(:user), do: @chat_user_marker
  def chat_marker(:assistant), do: @chat_assistant_marker

  @spec latest_user_message(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def latest_user_message(context) when is_binary(context) do
    pattern =
      ~r/^\[RLM_User\]\n(.*?)(?=^\[RLM_(?:User|Assistant)\]|\z)/ms

    case Regex.scan(pattern, context) do
      [] ->
        {:error, "No chat entries found in context"}

      matches ->
        message =
          matches
          |> List.last()
          |> Enum.at(1)
          |> String.trim()

        {:ok, message}
    end
  end

  defp matches?(pattern, line) when is_binary(pattern), do: String.contains?(line, pattern)
  defp matches?(%Regex{} = pattern, line), do: Regex.match?(pattern, line)

  defp resolve_workspace_path(nil, _path), do: {:error, "workspace_root not set"}

  defp resolve_workspace_path(root, path) when is_binary(root) and is_binary(path) do
    root_abs = Path.expand(root)
    target = Path.expand(path, root_abs)

    if path_within_root?(root_abs, target) do
      {:ok, target}
    else
      {:error, "Path is outside workspace root"}
    end
  end

  defp path_within_root?(root_abs, target) do
    root_parts = Path.split(root_abs)
    target_parts = Path.split(target)
    Enum.take(target_parts, length(root_parts)) == root_parts
  end

  defp read_bytes(path, n) do
    case File.open(path, [:read, :binary]) do
      {:ok, device} ->
        data = IO.binread(device, n) || ""
        File.close(device)
        {:ok, data}

      {:error, reason} ->
        {:error, "Failed to open file: #{inspect(reason)}"}
    end
  end

  defp parse_edit_blocks(patch) do
    patch = normalize_patch(patch)

    regex =
      ~r/<<<<<<< SEARCH\r?\n(.*?)\r?\n=======\r?\n(.*?)\r?\n>>>>>>> REPLACE/s

    blocks = Regex.scan(regex, patch)

    cond do
      blocks == [] ->
        {:error,
         "No edit blocks found. Use <<<<<<< SEARCH ... ======= ... >>>>>>> REPLACE blocks."}

      String.trim(Regex.replace(regex, patch, "")) != "" ->
        {:error, "Patch contains text outside of edit blocks"}

      true ->
        edits =
          Enum.map(blocks, fn [_all, search, replace] ->
            {search, replace}
          end)

        case Enum.find(edits, fn {search, _replace} -> search == "" end) do
          nil -> {:ok, edits}
          _ -> {:error, "Search blocks cannot be empty"}
        end
    end
  end

  defp apply_edit_blocks(content, edits) do
    Enum.reduce_while(edits, {:ok, content}, fn {search, replace}, {:ok, acc} ->
      case :binary.matches(acc, search) do
        [] ->
          {:halt, {:error, "Search text not found in file"}}

        [_match] ->
          updated = String.replace(acc, search, replace, global: false)
          {:cont, {:ok, updated}}

        _multiple ->
          {:halt,
           {:error,
            "Search text matched multiple occurrences. Add more surrounding context to make it unique."}}
      end
    end)
  end

  defp normalize_patch(patch) do
    trimmed = String.trim(patch, "\n")
    lines = String.split(trimmed, "\n", trim: false)

    min_indent =
      lines
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&leading_indent/1)
      |> case do
        [] -> 0
        indents -> Enum.min(indents)
      end

    if min_indent > 0 do
      lines
      |> Enum.map(fn line ->
        if line == "" do
          ""
        else
          String.slice(line, min_indent..-1//1)
        end
      end)
      |> Enum.join("\n")
    else
      trimmed
    end
  end

  defp leading_indent(line) do
    line
    |> String.to_charlist()
    |> Enum.take_while(&(&1 == ?\s or &1 == ?\t))
    |> length()
  end

  defp format_file_error(reason) when is_atom(reason),
    do: "File operation failed: #{inspect(reason)}"

  defp format_file_error(reason) when is_binary(reason), do: reason
  defp format_file_error(reason), do: "File operation failed: #{inspect(reason)}"

  defp type_of(value) when is_binary(value), do: "string"
  defp type_of(value) when is_integer(value), do: "integer"
  defp type_of(value) when is_float(value), do: "float"
  defp type_of(value) when is_atom(value), do: "atom"
  defp type_of(value) when is_list(value), do: "list"
  defp type_of(value) when is_map(value), do: "map"
  defp type_of(value) when is_tuple(value), do: "tuple"
  defp type_of(value) when is_function(value), do: "function"
  defp type_of(value) when is_pid(value), do: "pid"
  defp type_of(_value), do: "other"

  defp term_size(value) when is_binary(value), do: byte_size(value)
  defp term_size(value), do: :erlang.term_to_binary(value) |> byte_size()
end
