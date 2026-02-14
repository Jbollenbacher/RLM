defmodule RLM.Bench.SourceManifest do
  @moduledoc false

  @required_source_keys ~w(id url type)

  def load(path) when is_binary(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         :ok <- validate(decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid JSON in source manifest #{path}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate(%{"version" => version, "sources" => sources})
       when is_binary(version) and is_list(sources) do
    sources
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {source, idx}, _acc ->
      case validate_source(source) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "Invalid source at index #{idx}: #{reason}"}}
      end
    end)
  end

  defp validate(_), do: {:error, "Manifest must include string `version` and list `sources`"}

  defp validate_source(source) when is_map(source) do
    missing = Enum.reject(@required_source_keys, &Map.has_key?(source, &1))

    cond do
      missing != [] ->
        {:error, "missing keys #{Enum.join(missing, ", ")}"}

      Enum.any?(@required_source_keys, fn key ->
        value = Map.get(source, key)
        not is_binary(value) or String.trim(value) == ""
      end) ->
        {:error, "id/url/type must be non-empty strings"}

      true ->
        :ok
    end
  end

  defp validate_source(_), do: {:error, "source must be an object"}
end
