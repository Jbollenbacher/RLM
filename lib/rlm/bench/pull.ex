defmodule RLM.Bench.Pull do
  @moduledoc false

  alias RLM.Bench.Paths
  alias RLM.Bench.SourceManifest

  def run(manifest_path, opts \\ []) do
    only_ids = parse_only_ids(Keyword.get(opts, :only, ""))
    force? = Keyword.get(opts, :force, false)

    with {:ok, manifest} <- SourceManifest.load(manifest_path) do
      raw_dir = Paths.ensure_dir!(Paths.raw_dir())

      sources =
        manifest
        |> Map.get("sources", [])
        |> filter_sources(only_ids)

      {ok, failed} =
        Enum.reduce(sources, {[], []}, fn source, {acc_ok, acc_failed} ->
          case download_source(source, raw_dir, force?) do
            {:ok, row} -> {[row | acc_ok], acc_failed}
            {:error, row} -> {acc_ok, [row | acc_failed]}
          end
        end)

      ok = Enum.reverse(ok)
      failed = Enum.reverse(failed)

      index = %{
        manifest_version: Map.get(manifest, "version"),
        generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        sources: ok,
        failed: failed
      }

      index_path = Path.join(raw_dir, "index.json")
      File.write!(index_path, Jason.encode!(index, pretty: true))

      if failed == [] do
        {:ok, %{downloaded: length(ok), failed: 0, index_path: index_path}}
      else
        {:error,
         %{
           downloaded: length(ok),
           failed: length(failed),
           index_path: index_path,
           failures: failed
         }}
      end
    end
  end

  defp parse_only_ids(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  defp filter_sources(sources, only_ids) do
    if MapSet.size(only_ids) == 0 do
      sources
    else
      Enum.filter(sources, fn source -> MapSet.member?(only_ids, Map.get(source, "id")) end)
    end
  end

  defp download_source(source, raw_dir, force?) do
    id = Map.fetch!(source, "id")
    path = Path.join(raw_dir, "#{id}.txt")

    if File.exists?(path) and not force? do
      with {:ok, body} <- File.read(path) do
        {:ok, index_row(source, path, body, true)}
      else
        {:error, reason} ->
          {:error, %{id: id, url: Map.get(source, "url"), reason: inspect(reason)}}
      end
    else
      case Req.get(Map.fetch!(source, "url"), receive_timeout: 120_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) ->
          File.write!(path, body)
          {:ok, index_row(source, path, body, false)}

        {:ok, %{status: status}} ->
          {:error,
           %{
             id: id,
             url: Map.get(source, "url"),
             reason: "HTTP status #{status} while downloading"
           }}

        {:error, reason} ->
          {:error, %{id: id, url: Map.get(source, "url"), reason: Exception.message(reason)}}
      end
    end
  end

  defp index_row(source, path, body, reused?) do
    %{
      id: Map.get(source, "id"),
      url: Map.get(source, "url"),
      type: Map.get(source, "type"),
      license: Map.get(source, "license"),
      path: path,
      bytes: byte_size(body),
      sha256: sha256(body),
      reused: reused?,
      downloaded_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end
end
