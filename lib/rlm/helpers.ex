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
    Enum.map(bindings, fn {name, value} ->
      {name, type_of(value), term_size(value)}
    end)
  end

  defp matches?(pattern, line) when is_binary(pattern), do: String.contains?(line, pattern)
  defp matches?(%Regex{} = pattern, line), do: Regex.match?(pattern, line)

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
