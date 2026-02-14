defmodule RLM.Bench.SourceManifestTest do
  use ExUnit.Case, async: true

  alias RLM.Bench.SourceManifest

  test "loads valid manifest" do
    path = Path.join(System.tmp_dir!(), "manifest_#{System.unique_integer([:positive])}.json")

    body =
      Jason.encode!(%{
        version: "v1",
        sources: [%{id: "a", url: "https://example.com/a.txt", type: "txt"}]
      })

    File.write!(path, body)

    assert {:ok, %{"version" => "v1", "sources" => [_]}} = SourceManifest.load(path)
  end

  test "rejects malformed manifest" do
    path = Path.join(System.tmp_dir!(), "manifest_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{sources: [%{id: "a"}]}))

    assert {:error, reason} = SourceManifest.load(path)
    assert reason =~ "Manifest"
  end
end
