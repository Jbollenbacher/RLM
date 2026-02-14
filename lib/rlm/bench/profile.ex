defmodule RLM.Bench.Profile do
  @moduledoc false

  alias RLM.Bench.Paths

  def load(path \\ nil) do
    path = path || Paths.default_profile_path()

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid profile JSON #{path}: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, "Failed to load profile #{path}: #{inspect(reason)}"}
    end
  end

  def get(profile, path, default) when is_list(path) do
    Enum.reduce_while(path, profile, fn key, acc ->
      if is_map(acc) and Map.has_key?(acc, key) do
        {:cont, Map.get(acc, key)}
      else
        {:halt, default}
      end
    end)
  end
end
