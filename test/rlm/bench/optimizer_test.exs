defmodule RLM.Bench.OptimizerTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.Optimizer

  test "run_id_for_cycle embeds session id and cycle variant" do
    assert Optimizer.run_id_for_cycle("opt_session_1", 3, :a) == "opt_session_1_cycle3_a"
    assert Optimizer.run_id_for_cycle("opt_session_1", 3, :b) == "opt_session_1_cycle3_b"
  end

  test "run_id_for_cycle prevents cross-session collisions" do
    run_a = Optimizer.run_id_for_cycle("opt_session_1", 1, :a)
    run_b = Optimizer.run_id_for_cycle("opt_session_2", 1, :a)
    refute run_a == run_b
  end
end
