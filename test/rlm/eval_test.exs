defmodule RLM.EvalTest do
  use ExUnit.Case

  describe "eval correctness (spec test 1)" do
    test "captures stdout from print" do
      {:ok, stdout, _stderr, _result, _bindings} = RLM.Eval.eval(~s[print("hello")], [])
      assert stdout == "hello\n"
    end

    test "stores Python globals in bindings" do
      {:ok, _stdout, _stderr, _result, bindings} = RLM.Eval.eval(~s[print("hello")], [])
      assert is_map(Keyword.get(bindings, :python_globals))
    end
  end

  describe "binding persistence (spec test 2)" do
    test "bindings persist across eval calls" do
      {:ok, _, _, _, bindings} = RLM.Eval.eval("x = 42", [])
      {:ok, stdout, _, _, _} = RLM.Eval.eval("print(x)", bindings)
      assert stdout == "42\n"
    end

    test "multiple bindings persist" do
      {:ok, _, _, _, b1} = RLM.Eval.eval("x = 1", [])
      {:ok, _, _, _, b2} = RLM.Eval.eval("y = x + 1", b1)
      {:ok, stdout, _, _, _} = RLM.Eval.eval("print(x + y)", b2)
      assert stdout == "3\n"
    end
  end

  describe "error handling" do
    test "runtime errors return error tuple with unchanged bindings" do
      {:error, stdout, stderr, bindings} = RLM.Eval.eval(~s[raise Exception("boom")], x: 42)
      assert stdout <> stderr =~ "boom"
      assert bindings == [x: 42]
    end

    test "syntax errors return error tuple" do
      {:error, stdout, stderr, bindings} = RLM.Eval.eval("def foo(", [])
      assert stdout <> stderr =~ "SyntaxError"
      assert bindings == []
    end
  end

  describe "timeout" do
    test "infinite sleep times out" do
      {:error, _stdout, stderr, []} =
        RLM.Eval.eval("import time\ntime.sleep(9999)", [], timeout: 500)

      assert stderr =~ "timed out"
    end
  end

  describe "helper functions" do
    test "grep is available without module prefix" do
      {:ok, stdout, _stderr, _, _} =
        RLM.Eval.eval(
          ~s[print(grep("foo", "line1\\nfoo bar\\nline3"))],
          []
        )

      assert stdout =~ "foo bar"
    end

    test "chunks is not available" do
      {:error, stdout, stderr, []} = RLM.Eval.eval(~s[chunks("abcdef", 3)], [])
      combined = stdout <> stderr
      assert combined =~ "NameError"
      assert combined =~ "chunks"
    end

    test "preview is not available" do
      {:error, stdout, stderr, []} = RLM.Eval.eval(~s[preview({"a": 1}, 50)], [])
      combined = stdout <> stderr
      assert combined =~ "NameError"
      assert combined =~ "preview"
    end
  end

  describe "result value" do
    test "returns the result of the last expression" do
      {:ok, _stdout, _stderr, result, _bindings} = RLM.Eval.eval("1 + 2", [])
      assert result == 3
    end
  end

  describe "async lm_query helpers" do
    test "await surfaces specific lm_query errors" do
      {:ok, stdout, _stderr, _result, _bindings} =
        RLM.Eval.eval(
          ~s[
job_id = lm_query("subtask")
try:
    await_lm_query(job_id, timeout_ms=1_000)
except Exception as exc:
    print(exc)
],
          lm_query: fn _text, _opts -> {:error, "boom"} end
        )

      assert stdout =~ "boom"
    end

    test "dispatch returns child id and poll observes running job" do
      {:ok, stdout, _stderr, _result, _bindings} =
        RLM.Eval.eval(
          ~s[
job_id = lm_query("slow-subtask")
state = poll_lm_query(job_id)
print(job_id.startswith("agent_"))
print(state.get("state"))
],
          lm_query: fn _text, _opts ->
            Process.sleep(250)
            {:ok, "done"}
          end
        )

      assert stdout =~ "True"
      assert stdout =~ "running"
    end

    test "await raises in Python when subagent crashes" do
      lm_query_fn = fn _text, _opts ->
        exit(:killed)
      end

      {:ok, stdout, _stderr, _result, _bindings} =
        RLM.Eval.eval(
          ~s[
job_id = lm_query("subtask")
try:
    await_lm_query(job_id, timeout_ms=1_000)
except Exception as exc:
    print(exc)
],
          lm_query: lm_query_fn
        )

      assert stdout =~ "killed"
    end

    test "sampled terminal jobs can be assessed" do
      {:ok, stdout, _stderr, _result, _bindings} =
        RLM.Eval.eval(
          ~s[
job_id = lm_query("subtask")
_ = await_lm_query(job_id, timeout_ms=1_000)
state = assess_lm_query(job_id, "satisfied", reason="useful result")
print(state.get("assessment", {}).get("verdict"))
],
          lm_query: fn _text, _opts -> {:ok, "done"} end,
          subagent_assessment_sample_rate: 1.0
        )

      assert stdout =~ "satisfied"
    end

    test "assess_lm_query errors when job has not terminated" do
      {:ok, stdout, _stderr, _result, _bindings} =
        RLM.Eval.eval(
          ~s[
job_id = lm_query("slow-subtask")
try:
    assess_lm_query(job_id, "dissatisfied", reason="premature")
except Exception as exc:
    print(exc)
],
          lm_query: fn _text, _opts ->
            Process.sleep(300)
            {:ok, "done"}
          end,
          subagent_assessment_sample_rate: 1.0
        )

      assert stdout =~ "still running"
    end
  end

  describe "dispatch assessment helper" do
    test "captures dispatch assessment in bindings" do
      {:ok, _stdout, _stderr, _result, bindings} =
        RLM.Eval.eval(
          ~s[
assess_dispatch("satisfied", reason="clear dispatch")
final_answer = "done"
],
          parent_agent_id: "agent_parent",
          dispatch_assessment_required: true
        )

      assert Keyword.get(bindings, :dispatch_assessment) == %{
               verdict: :satisfied,
               reason: "clear dispatch"
             }
    end

    test "errors when called without a parent agent" do
      {:error, stdout, stderr, _bindings} =
        RLM.Eval.eval(
          ~s[
assess_dispatch("satisfied", reason="n/a")
],
          []
        )

      assert stdout <> stderr =~ "only available for subagents"
    end

    test "is a no-op when dispatch assessment is not required" do
      {:ok, _stdout, _stderr, _result, bindings} =
        RLM.Eval.eval(
          ~s[
result = assess_dispatch("satisfied", reason="optional")
],
          parent_agent_id: "agent_parent",
          dispatch_assessment_required: false
        )

      assert Keyword.get(bindings, :dispatch_assessment) == nil
    end
  end
end
