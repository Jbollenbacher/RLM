defmodule RLM.HelpersTest do
  use ExUnit.Case

  describe "chunks/2" do
    test "splits string into chunks" do
      result = RLM.Helpers.chunks("abcdefghij", 3) |> Enum.to_list()
      assert result == ["abc", "def", "ghi", "j"]
    end

    test "single chunk when size >= string length" do
      result = RLM.Helpers.chunks("abc", 10) |> Enum.to_list()
      assert result == ["abc"]
    end

    test "empty string returns empty list" do
      result = RLM.Helpers.chunks("", 3) |> Enum.to_list()
      assert result == []
    end

    test "returns a lazy enumerable (not a list)" do
      stream = RLM.Helpers.chunks("abcdef", 2)
      refute is_list(stream)
      assert Enum.to_list(stream) == ["ab", "cd", "ef"]
    end
  end

  describe "grep/2" do
    test "finds matching lines with string pattern" do
      result = RLM.Helpers.grep("foo", "line1\nfoo bar\nline3\nfoo baz")
      assert result == [{2, "foo bar"}, {4, "foo baz"}]
    end

    test "finds matching lines with regex pattern" do
      result = RLM.Helpers.grep(~r/\d+/, "abc\n123\ndef")
      assert result == [{2, "123"}]
    end

    test "returns empty list when no matches" do
      result = RLM.Helpers.grep("missing", "line1\nline2")
      assert result == []
    end
  end

  describe "preview/2" do
    test "truncates long representations" do
      long_map = %{data: String.duplicate("x", 1000)}
      result = RLM.Helpers.preview(long_map, 50)
      assert String.length(result) == 50
    end

    test "short terms are returned fully" do
      result = RLM.Helpers.preview(%{a: 1})
      assert result =~ "%{a: 1}"
    end

    test "default truncation is 500 chars" do
      long_string = String.duplicate("x", 1000)
      result = RLM.Helpers.preview(long_string)
      assert String.length(result) <= 500
    end
  end

  describe "list_bindings/1" do
    test "returns name, type, and size for each binding" do
      bindings = [x: 42, name: "hello"]
      result = RLM.Helpers.list_bindings(bindings)

      assert [{:x, "integer", _}, {:name, "string", 5}] = result
    end

    test "handles various types" do
      bindings = [a: :atom, b: [1, 2], c: %{}, d: {1, 2}]
      result = RLM.Helpers.list_bindings(bindings)
      types = Enum.map(result, fn {_, type, _} -> type end)
      assert types == ["atom", "list", "map", "tuple"]
    end

    test "handles functions" do
      bindings = [f: fn -> :ok end]
      [{:f, type, _}] = RLM.Helpers.list_bindings(bindings)
      assert type == "function"
    end
  end
end
