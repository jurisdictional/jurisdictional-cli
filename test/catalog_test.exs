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

      # Each entry is a receipt: the file still matches its digest, and names its URL.
      assert entry["sha256"] == :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
             "#{entry["file"]} no longer matches its sha256"

      assert String.starts_with?(entry["url"], "https://jurisdictional.org" <> entry["path"]),
             entry["file"]

      if entry["path"] == "/healthz" do
        assert String.trim(raw) == "ok"
      else
        assert {:ok, _} = Jason.decode(raw)
      end
    end

    assert Enum.any?(index["entries"], &(&1["path"] == "/api/v1/juricode"))

    # App use and account settings stay out of the public catalog.
    refute Enum.any?(index["entries"], fn entry ->
             String.starts_with?(entry["path"], "/api/v1/activity") or
               String.starts_with?(entry["path"], "/api/v1/me") or
               String.starts_with?(entry["path"], "/api/v1/devices") or
               String.starts_with?(entry["path"], "/api/v1/sync") or
               String.starts_with?(entry["path"], "/api/v1/auth")
           end)
  end
end
