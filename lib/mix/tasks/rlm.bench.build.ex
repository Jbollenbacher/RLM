defmodule Mix.Tasks.Rlm.Bench.Build do
  use Mix.Task

  alias RLM.Bench.Paths
  alias RLM.Bench.TaskBuilder

  @shortdoc "Build assessment-driven benchmark tasks from pulled corpus"

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, output: :string]
      )

    profile_path = Keyword.get(opts, :profile, Paths.default_profile_path())
    output_path = Keyword.get(opts, :output, Paths.default_pool_path())

    case TaskBuilder.run(profile_path: profile_path, output_path: output_path) do
      {:ok, summary} ->
        Mix.shell().info(
          "Built #{summary.task_count} tasks to #{summary.output_path} using profile #{summary.profile_path}"
        )

      {:error, reason} ->
        Mix.raise(reason)
    end
  end
end
