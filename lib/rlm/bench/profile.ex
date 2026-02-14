defmodule RLM.Bench.Profile do
  @moduledoc false

  alias RLM.Bench.Paths
  alias RLM.Bench.Util

  def load(path \\ nil) do
    Util.load_json(path || Paths.default_profile_path(), "profile")
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
