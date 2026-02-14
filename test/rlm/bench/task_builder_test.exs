defmodule RLM.Bench.TaskBuilderTest do
  use ExUnit.Case, async: false

  alias RLM.Bench.Paths
  alias RLM.Bench.TaskBuilder

  test "first task starts from first segment of source text" do
    unique = System.unique_integer([:positive, :monotonic])
    raw_dir = Paths.raw_dir()
    backup_dir = "#{raw_dir}_backup_#{unique}"
    had_raw_dir = File.dir?(raw_dir)

    if had_raw_dir do
      File.rename!(raw_dir, backup_dir)
    end

    File.mkdir_p!(raw_dir)

    on_exit(fn ->
      File.rm_rf(raw_dir)

      if had_raw_dir do
        File.rename!(backup_dir, raw_dir)
      end
    end)

    doc_id = "zzzz_task_builder_#{unique}"
    doc_path = Path.join(raw_dir, "#{doc_id}.txt")
    File.write!(doc_path, "AAAAABBBBB")

    wrapper_path = Path.join(System.tmp_dir!(), "task_wrapper_#{unique}.md")
    profile_path = Path.join(System.tmp_dir!(), "task_profile_#{unique}.json")
    output_path = Path.join(System.tmp_dir!(), "task_pool_#{unique}.jsonl")

    File.write!(
      wrapper_path,
      """
      Required: {{required_min_dispatches}}
      {{family_instruction}}
      """
    )

    File.write!(
      profile_path,
      Jason.encode!(%{
        target_task_count: 1,
        required_min_dispatches: 1,
        segment_size_chars: 5,
        segment_overlap_chars: 0,
        task_wrapper_path: wrapper_path,
        families: ["cross_section_compare"]
      })
    )

    assert {:ok, summary} = TaskBuilder.run(profile_path: profile_path, output_path: output_path)
    assert summary.task_count == 1

    [line] =
      output_path
      |> File.read!()
      |> String.split("\n", trim: true)

    task = Jason.decode!(line)
    context = File.read!(task["context_path"])

    assert context =~ "[SEGMENT_A]\nAAAAA"
    assert context =~ "[SEGMENT_B]\nBBBBB"
  end
end
