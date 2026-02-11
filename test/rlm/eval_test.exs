defmodule RLM.EvalTest do
  use ExUnit.Case

  describe "eval correctness (spec test 1)" do
    test "captures stdout from IO.puts" do
      {:ok, stdout, _result, _bindings} = RLM.Eval.eval(~s[IO.puts("hello")], [])
      assert stdout == "hello\n"
    end

    test "returns unchanged bindings when no assignment" do
      {:ok, _stdout, _result, bindings} = RLM.Eval.eval(~s[IO.puts("hello")], [])
      assert bindings == []
    end
  end

  describe "binding persistence (spec test 2)" do
    test "bindings persist across eval calls" do
      {:ok, _, _, bindings} = RLM.Eval.eval("x = 42", [])
      {:ok, stdout, _, _} = RLM.Eval.eval("IO.puts(x)", bindings)
      assert stdout == "42\n"
    end

    test "multiple bindings persist" do
      {:ok, _, _, b1} = RLM.Eval.eval("x = 1", [])
      {:ok, _, _, b2} = RLM.Eval.eval("y = x + 1", b1)
      {:ok, stdout, _, _} = RLM.Eval.eval("IO.puts(x + y)", b2)
      assert stdout == "3\n"
    end
  end

  describe "error handling" do
    test "raises return error tuple with unchanged bindings" do
      {:error, stdout, bindings} = RLM.Eval.eval(~s[raise "boom"], x: 42)
      assert stdout =~ "boom"
      assert bindings == [x: 42]
    end

    test "syntax errors return error tuple" do
      {:error, stdout, bindings} = RLM.Eval.eval("def foo(", [])
      assert stdout =~ "error"
      assert bindings == []
    end
  end

  describe "crash safety" do
    test "exit(:kill) does not crash the host process" do
      {:error, stdout, []} = RLM.Eval.eval("exit(:kill)", [])
      assert stdout =~ "crash" or stdout =~ "kill" or stdout =~ "exit"
    end
  end

  describe "timeout" do
    test "infinite sleep times out" do
      {:error, stdout, []} = RLM.Eval.eval("Process.sleep(:infinity)", [], timeout: 500)
      assert stdout =~ "timed out"
    end
  end

  describe "sandbox import" do
    test "chunks is available without module prefix" do
      {:ok, stdout, _, _} =
        RLM.Eval.eval(
          ~s[chunks("abcdef", 3) |> Enum.to_list() |> IO.inspect()],
          []
        )

      assert stdout =~ "abc"
      assert stdout =~ "def"
    end

    test "grep is available without module prefix" do
      {:ok, stdout, _, _} =
        RLM.Eval.eval(
          ~s[grep("foo", "line1\\nfoo bar\\nline3") |> IO.inspect()],
          []
        )

      assert stdout =~ "foo bar"
    end

    test "preview is available without module prefix" do
      {:ok, stdout, _, _} =
        RLM.Eval.eval(
          ~s[preview(%{a: 1}, 50) |> IO.puts()],
          []
        )

      assert stdout =~ "%{a: 1}"
    end
  end

  describe "result value" do
    test "returns the result of the last expression" do
      {:ok, _stdout, result, _bindings} = RLM.Eval.eval("1 + 2", [])
      assert result == 3
    end
  end
end
