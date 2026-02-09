defmodule RLM.TruncateTest do
  use ExUnit.Case

  test "short text is returned unchanged" do
    assert RLM.Truncate.truncate("short", head: 4000, tail: 4000) == "short"
  end

  test "text exactly at limit is returned unchanged" do
    text = String.duplicate("x", 8000)
    assert RLM.Truncate.truncate(text, head: 4000, tail: 4000) == text
  end

  test "text over limit is truncated with marker" do
    text = String.duplicate("x", 10_000)
    result = RLM.Truncate.truncate(text, head: 4000, tail: 4000)

    assert result =~ "... [truncated 2000 chars] ..."
    assert String.length(result) < String.length(text)

    # Head and tail are preserved
    assert String.starts_with?(result, String.duplicate("x", 4000))
    assert String.ends_with?(result, String.duplicate("x", 4000))
  end

  test "preserves head and tail content with distinguishable chars" do
    head_part = String.duplicate("H", 5000)
    tail_part = String.duplicate("T", 5000)
    text = head_part <> tail_part

    result = RLM.Truncate.truncate(text, head: 4000, tail: 4000)

    assert String.starts_with?(result, String.duplicate("H", 4000))
    assert String.ends_with?(result, String.duplicate("T", 4000))
    assert result =~ "truncated 2000 chars"
  end

  test "uses default head/tail of 4000" do
    text = String.duplicate("x", 10_000)
    result = RLM.Truncate.truncate(text)
    assert result =~ "truncated 2000 chars"
  end
end
