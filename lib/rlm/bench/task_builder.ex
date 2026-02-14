defmodule RLM.Bench.TaskBuilder do
  @moduledoc false

  alias RLM.Bench.JSONL
  alias RLM.Bench.Paths
  alias RLM.Bench.Profile

  @families [
    "cross_section_compare",
    "constraint_extraction_matrix",
    "contradiction_hunt",
    "procedure_reconstruction",
    "evidence_linking"
  ]

  @segment_size 12_000
  @segment_overlap 800

  def run(opts \\ []) do
    profile_path = Keyword.get(opts, :profile_path, Paths.default_profile_path())
    output_path = Keyword.get(opts, :output_path, Paths.default_pool_path())

    with {:ok, profile} <- Profile.load(profile_path),
         {:ok, docs} <- load_documents() do
      target_count = Profile.get(profile, ["target_task_count"], 120)
      required_min_dispatches = Profile.get(profile, ["required_min_dispatches"], 2)

      context_dir = Paths.ensure_dir!(Paths.context_dir())
      Paths.ensure_dir!(Path.dirname(output_path))

      wrapper = File.read!(Path.join([Paths.bench_root(), "templates", "task_wrapper.md"]))
      family_instructions = load_family_instructions()

      tasks =
        build_tasks(
          docs,
          target_count,
          required_min_dispatches,
          wrapper,
          family_instructions,
          context_dir
        )

      JSONL.write!(output_path, tasks)

      {:ok,
       %{
         task_count: length(tasks),
         output_path: output_path,
         context_dir: context_dir,
         profile_path: profile_path
       }}
    end
  end

  defp load_documents do
    raw_dir = Paths.raw_dir()

    if not File.dir?(raw_dir) do
      {:error, "Raw corpus directory not found: #{raw_dir}. Run `mix rlm.bench.pull` first."}
    else
      docs =
        raw_dir
        |> Path.join("*.txt")
        |> Path.wildcard()
        |> Enum.sort()
        |> Enum.map(fn path ->
          %{
            id: Path.basename(path, ".txt"),
            path: path,
            text: File.read!(path)
          }
        end)
        |> Enum.filter(&(String.trim(&1.text) != ""))

      if docs == [] do
        {:error, "No pulled text sources found in #{raw_dir}."}
      else
        {:ok, docs}
      end
    end
  end

  defp load_family_instructions do
    Enum.into(@families, %{}, fn family ->
      path = Path.join([Paths.bench_root(), "templates", "family_#{family}.md"])
      instruction = File.read!(path) |> String.trim()
      {family, instruction}
    end)
  end

  defp build_tasks(
         docs,
         target_count,
         required_min_dispatches,
         wrapper,
         family_instructions,
         context_dir
       ) do
    doc_segments = Enum.map(docs, &build_segments/1)
    families = Stream.cycle(@families)
    segments_stream = Stream.cycle(doc_segments)

    1..target_count
    |> Enum.zip(families)
    |> Enum.zip(segments_stream)
    |> Enum.map(fn {{task_index, family}, doc} ->
      segment_a = pick_segment(doc.segments, task_index)
      segment_b = pick_segment(doc.segments, task_index + 1)

      task_id =
        ["v1", doc.id, family, String.pad_leading(Integer.to_string(task_index), 4, "0")]
        |> Enum.join("_")

      context =
        [
          "[SOURCE_ID] #{doc.id}",
          "[SEGMENT_A]",
          segment_a,
          "",
          "[SEGMENT_B]",
          segment_b
        ]
        |> Enum.join("\n")

      context_path = Path.join(context_dir, "#{task_id}.txt")
      File.write!(context_path, context)

      family_instruction = Map.fetch!(family_instructions, family)

      query =
        wrapper
        |> String.replace(
          "{{required_min_dispatches}}",
          Integer.to_string(required_min_dispatches)
        )
        |> String.replace("{{family_instruction}}", family_instruction)

      %{
        task_id: task_id,
        family: family,
        source_ids: [doc.id],
        context_path: context_path,
        query: query,
        required_min_dispatches: required_min_dispatches,
        tags: ["assessment_optimization", "delegation_required", family]
      }
    end)
  end

  defp build_segments(doc) do
    segments = split_with_overlap(doc.text, @segment_size, @segment_overlap)
    %{id: doc.id, path: doc.path, segments: segments}
  end

  defp split_with_overlap(text, segment_size, overlap) do
    do_split(text, segment_size, overlap, 0, [])
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp do_split(text, segment_size, overlap, offset, acc) do
    total = String.length(text)

    if offset >= total do
      acc
    else
      chunk = String.slice(text, offset, segment_size) || ""
      next_offset = max(offset + segment_size - overlap, offset + 1)
      do_split(text, segment_size, overlap, next_offset, [chunk | acc])
    end
  end

  defp pick_segment([], _idx), do: ""

  defp pick_segment(segments, idx) do
    Enum.at(segments, rem(idx, length(segments)))
  end
end
