defmodule Mix.Tasks.Rlm.Bench.Pull do
  use Mix.Task

  alias RLM.Bench.Paths
  alias RLM.Bench.Pull

  @shortdoc "Download benchmark source corpus into bench_data/raw"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [manifest: :string, force: :boolean, only: :string]
      )

    manifest_path = Keyword.get(opts, :manifest, Paths.default_manifest_path())

    case Pull.run(manifest_path,
           force: Keyword.get(opts, :force, false),
           only: Keyword.get(opts, :only, "")
         ) do
      {:ok, summary} ->
        Mix.shell().info(
          "Pulled corpus successfully. downloaded=#{summary.downloaded} index=#{summary.index_path}"
        )

      {:error, summary} when is_map(summary) ->
        Mix.shell().error(
          "Pull completed with failures. downloaded=#{summary.downloaded} failed=#{summary.failed} index=#{summary.index_path}"
        )

        Enum.each(summary.failures, fn failure ->
          Mix.shell().error("- #{failure.id}: #{failure.reason}")
        end)

        System.halt(1)

      {:error, reason} ->
        Mix.raise(reason)
    end
  end
end
