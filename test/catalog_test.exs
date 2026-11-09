defmodule JurisdictionalCli.CatalogTest do
  use ExUnit.Case, async: true

  test "the checked-in catalog points at a file for every entry" do
    root = Path.expand("../responses", __DIR__)
    index = Jason.decode!(File.read!(Path.join(root, "index.json")))
    assert index["entries"] != []

    for entry <- index["entries"] do
      path = Path.join(root, entry["file"])
      assert File.regular?(path), entry["file"]
      raw = File.read!(path)

      if entry["path"] == "/healthz" do
        assert String.trim(raw) == "ok"
      else
        assert {:ok, _} = Jason.decode(raw)
      end
    end

    assert Enum.any?(index["entries"], &(&1["path"] == "/api/v1/juricode"))
  end
end
