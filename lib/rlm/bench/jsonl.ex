defmodule RLM.Bench.JSONL do
  @moduledoc false

  def read(path) do
    path
    |> File.stream!([], :line)
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(fn line -> Jason.decode!(line) end)
  end

  def write!(path, rows) when is_list(rows) do
    body = Enum.map_join(rows, "\n", &Jason.encode!/1)
    File.write!(path, body <> "\n")
  end
end
