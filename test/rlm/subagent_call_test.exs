defmodule RLM.SubagentCallTest do
  use ExUnit.Case

  test "terminates spawned subagent worker when caller process dies" do
    test_pid = self()

    caller =
      spawn(fn ->
        lm_query_fn = fn _text, _opts ->
          send(test_pid, {:subagent_worker, self()})
          Process.sleep(:infinity)
          {:ok, "never"}
        end

        _ =
          RLM.Subagent.Call.execute(
            lm_query_fn,
            "task",
            [model_size: :small],
            timeout_ms: 120_000
          )

        send(test_pid, :caller_returned)
      end)

    assert_receive {:subagent_worker, worker_pid}, 1_000
    worker_ref = Process.monitor(worker_pid)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^worker_ref, :process, ^worker_pid, _reason}, 2_000
    refute_receive :caller_returned, 50
  end
end
