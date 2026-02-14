defmodule Mix.Tasks.Rlm.Bench.Pull do
  use Mix.Task

  alias RLM.Bench.Paths
  alias RLM.Bench.Pull

  @shortdoc "Download benchmark source corpus into bench_data/raw"

  @impl true
  def run(args) do
    {opts, _positional, invalid} =
      OptionParser.parse(args,
        strict: [manifest: :string, force: :boolean, only: :string]
      )

    raise_on_invalid_flags!(invalid)
    Mix.Task.run("app.start")

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
