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

  test "edit_file applies search/replace blocks", %{root: root} do
    patch = """
    <<<<<<< SEARCH
    hello
    =======
    hello world
    >>>>>>> REPLACE
    """

    assert {:ok, _message} = RLM.Helpers.edit_file(root, "a.txt", patch)
    assert {:ok, "hello world"} = RLM.Helpers.read_file(root, "a.txt")
  end

  test "edit_file errors when search text not found", %{root: root} do
    patch = """
    <<<<<<< SEARCH
    missing
    =======
    replaced
    >>>>>>> REPLACE
    """

    assert {:error, _reason} = RLM.Helpers.edit_file(root, "a.txt", patch)
  end

  test "create_file creates a new file", %{root: root} do
    assert {:ok, _message} = RLM.Helpers.create_file(root, "new.txt", "contents")
    assert {:ok, "contents"} = RLM.Helpers.read_file(root, "new.txt")
  end

  test "create_file creates parent directories", %{root: root} do
    assert {:ok, _message} = RLM.Helpers.create_file(root, "nested/dir/file.txt", "data")
    assert {:ok, "data"} = RLM.Helpers.read_file(root, "nested/dir/file.txt")
  end

  test "create_file errors when file exists", %{root: root} do
    assert {:error, _reason} = RLM.Helpers.create_file(root, "a.txt", "overwrite")
  end

  test "create_file rejects directory paths", %{root: root} do
    assert {:error, _reason} = RLM.Helpers.create_file(root, "sub/", "data")
  end

end
