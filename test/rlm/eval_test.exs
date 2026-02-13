defmodule RLM.EvalTest do
  use ExUnit.Case

  describe "eval correctness (spec test 1)" do
    test "captures stdout from print" do
      {:ok, stdout, _result, _bindings} = RLM.Eval.eval(~s[print("hello")], [])
      assert stdout == "hello\n"
    end

    test "stores Python globals in bindings" do
      {:ok, _stdout, _result, bindings} = RLM.Eval.eval(~s[print("hello")], [])
      assert is_map(Keyword.get(bindings, :python_globals))
    end
  end

  describe "binding persistence (spec test 2)" do
    test "bindings persist across eval calls" do
      {:ok, _, _, bindings} = RLM.Eval.eval("x = 42", [])
      {:ok, stdout, _, _} = RLM.Eval.eval("print(x)", bindings)
      assert stdout == "42\n"
    end

    test "multiple bindings persist" do
      {:ok, _, _, b1} = RLM.Eval.eval("x = 1", [])
      {:ok, _, _, b2} = RLM.Eval.eval("y = x + 1", b1)
      {:ok, stdout, _, _} = RLM.Eval.eval("print(x + y)", b2)
      assert stdout == "3\n"
    end
  end

  describe "error handling" do
    test "runtime errors return error tuple with unchanged bindings" do
      {:error, stdout, bindings} = RLM.Eval.eval(~s[raise Exception("boom")], x: 42)
      assert stdout =~ "boom"
      assert bindings == [x: 42]
    end

    test "syntax errors return error tuple" do
      {:error, stdout, bindings} = RLM.Eval.eval("def foo(", [])
      assert stdout =~ "SyntaxError"
      assert bindings == []
    end
  end

  describe "timeout" do
    test "infinite sleep times out" do
      {:error, stdout, []} = RLM.Eval.eval("import time\ntime.sleep(9999)", [], timeout: 500)
      assert stdout =~ "timed out"
    end
  end

  describe "helper functions" do
    test "grep is available without module prefix" do
      {:ok, stdout, _, _} =
        RLM.Eval.eval(
          ~s[print(grep("foo", "line1\\nfoo bar\\nline3"))],
          []
        )

      assert stdout =~ "foo bar"
    end

    test "chunks is not available" do
      {:error, stdout, []} = RLM.Eval.eval(~s[chunks("abcdef", 3)], [])
      assert stdout =~ "NameError"
      assert stdout =~ "chunks"
    end

    test "preview is not available" do
      {:error, stdout, []} = RLM.Eval.eval(~s[preview({"a": 1}, 50)], [])
      assert stdout =~ "NameError"
      assert stdout =~ "preview"
    end
  end

  describe "result value" do
    test "returns the result of the last expression" do
      {:ok, _stdout, result, _bindings} = RLM.Eval.eval("1 + 2", [])
      assert result == 3
    end
  end

  describe "lm_query crash fallback" do
    test "preserves specific lm_query errors as return values" do
      {:ok, stdout, _result, _bindings} =
        RLM.Eval.eval(~s[print(lm_query("subtask"))], lm_query: fn _text, _opts -> {:error, "boom"} end)

      assert stdout =~ "boom"
    end

    test "raises in Python when watcher identifies a crashed subagent" do
      unless Process.whereis(RLM.Observability.Store) do
        start_supervised!(
          {RLM.Observability.Store,
           [max_events_per_agent: 50, max_context_snapshots_per_agent: 10, max_agents: 10]}
        )
      end

      lm_query_fn = fn _text, opts ->
        child_agent_id = Keyword.fetch!(opts, :child_agent_id)
        RLM.Observability.Tracker.start_agent(child_agent_id, nil, "model", 1)

        RLM.Observability.Tracker.end_agent(child_agent_id, :error, %{
          source: :pid_down,
          reason: ":killed"
        })

        exit(:killed)
      end

      {:error, stdout, _bindings} = RLM.Eval.eval(~s[lm_query("subtask")], lm_query: lm_query_fn)
      assert stdout =~ "Subagent crashed before returning a result (watcher)"
    end
  end
end
