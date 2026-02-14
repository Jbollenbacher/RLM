defmodule RLM.Bench.Util do
  @moduledoc false

  @spec to_float(term(), float()) :: float()
  def to_float(value, default \\ 0.0)
  def to_float(value, _default) when is_float(value), do: value
  def to_float(value, _default) when is_integer(value), do: value * 1.0

  def to_float(value, default) when is_binary(value) do
    case Float.parse(value) do
      {parsed, _} -> parsed
      _ -> default
    end
  end

  def to_float(_value, default), do: default

  @spec get_number(map(), term(), float()) :: float()
  def get_number(map, key, default \\ 0.0) when is_map(map) do
    value = Map.get(map, key, Map.get(map, to_string(key), default))
    to_float(value, default)
  end

  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Enum.into(map, %{}, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(other), do: other

  @spec timestamp_id(String.t()) :: String.t()
  def timestamp_id(prefix) do
    ts =
      DateTime.utc_now()
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()
      |> String.replace(":", "-")

    "#{prefix}_#{ts}_#{System.unique_integer([:positive])}"
  end

  @spec tail_lines(String.t(), non_neg_integer()) :: String.t()
  def tail_lines(body, n) when is_binary(body) and is_integer(n) and n > 0 do
    body
    |> String.split("\n", trim: true)
    |> Enum.take(-n)
    |> Enum.join("\n")
  end

  def tail_lines(body, _n) when is_binary(body), do: body

  @spec load_json(String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def load_json(path, label \\ "file") do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid JSON in #{label} #{path}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "Failed to load #{label} #{path}: #{inspect(reason)}"}
    end
  end
end
