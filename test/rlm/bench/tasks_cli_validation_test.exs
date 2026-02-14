defmodule RLM.Bench.TasksCliValidationTest do
  use ExUnit.Case, async: true

  @cases [
    {Mix.Tasks.Rlm.Bench.Run, ["--not-a-real-flag"]},
    {Mix.Tasks.Rlm.Bench.Optimize, ["--not-a-real-flag"]},
    {Mix.Tasks.Rlm.Bench.Ab, ["--not-a-real-flag"]},
    {Mix.Tasks.Rlm.Bench.Build, ["--not-a-real-flag"]},
    {Mix.Tasks.Rlm.Bench.Pull, ["--not-a-real-flag"]},
    {Mix.Tasks.Rlm.Bench.Logs, ["--not-a-real-flag"]}
  ]

  for {task_module, args} <- @cases do
    test "#{inspect(task_module)} rejects unknown flags" do
      assert_raise Mix.Error, ~r/Unknown or invalid options/, fn ->
        unquote(task_module).run(unquote(args))
      end
    end
  end
end
