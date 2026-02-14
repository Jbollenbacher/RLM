defmodule Mix.Tasks.Rlm.Bench.Build do
  use Mix.Task

  alias RLM.Bench.Paths
  alias RLM.Bench.TaskBuilder

  @shortdoc "Build assessment-driven benchmark tasks from pulled corpus"

  @impl true
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [profile: :string, output: :string]
      )

    raise_on_invalid_flags!(invalid)
    Mix.Task.run("app.start")

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

  defp raise_on_invalid_flags!([]), do: :ok

  defp raise_on_invalid_flags!(invalid) do
    invalid_list =
      invalid
      |> Enum.map(&format_invalid_option/1)
      |> Enum.join(", ")

    Mix.raise("Unknown or invalid options: #{invalid_list}")
  end

  defp format_invalid_option({flag, _value}), do: to_string(flag)
  defp format_invalid_option(flag), do: to_string(flag)
end
