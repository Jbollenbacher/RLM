defmodule RLM.WorkspaceTest do
  use ExUnit.Case

  setup do
    root = Path.join(System.tmp_dir!(), "rlm_ws_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "a.txt"), "hello")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join([root, "sub", "b.txt"]), "world")

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "ls lists files and directories", %{root: root} do
    assert {:ok, entries} = RLM.Helpers.ls(root, ".")
    assert Enum.sort(entries) == ["a.txt", "sub/"]
  end

  test "read_file reads file contents", %{root: root} do
    assert {:ok, "hello"} = RLM.Helpers.read_file(root, "a.txt")
  end

  test "read_file respects max_bytes", %{root: root} do
    assert {:ok, "he"} = RLM.Helpers.read_file(root, "a.txt", 2)
  end

  test "read_file rejects paths outside root", %{root: root} do
    assert {:error, _reason} = RLM.Helpers.read_file(root, "../etc/passwd")
  end

  test "ls rejects non-directories", %{root: root} do
    assert {:error, _reason} = RLM.Helpers.ls(root, "a.txt")
  end
end
