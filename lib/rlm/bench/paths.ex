defmodule RLM.Bench.Paths do
  @moduledoc false

  @bench_root "bench"
  @data_root "bench_data"

  def bench_root, do: @bench_root
  def data_root, do: @data_root

  def default_manifest_path, do: Path.join([@bench_root, "manifests", "sources_v1.json"])
  def default_profile_path, do: Path.join([@bench_root, "profiles", "optimize_v1.json"])
  def default_pool_path, do: Path.join([@data_root, "tasks", "pool_v1.jsonl"])

  def raw_dir, do: Path.join(@data_root, "raw")
  def context_dir, do: Path.join(@data_root, "contexts")
  def tasks_dir, do: Path.join(@data_root, "tasks")
  def runs_dir, do: Path.join(@data_root, "runs")
  def ab_dir, do: Path.join(@data_root, "ab")
  def optimize_dir, do: Path.join(@data_root, "optimize")

  def ensure_dir!(path) do
    File.mkdir_p!(path)
    path
  end
end
