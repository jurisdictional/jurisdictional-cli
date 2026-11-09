defmodule JurisdictionalCli.StoreTest do
  use ExUnit.Case, async: true

  alias JurisdictionalCli.Store

  test "a response is a body file plus an index entry" do
    dir = fresh_dir()

    assert {:ok, "get/api/v1/jurisdictions/70118.json"} =
             Store.put(dir, %{
               method: "GET",
               path: "/api/v1/jurisdictions/70118",
               query: %{},
               status: 200,
               body: ~s({"data":{"id":70118,"name":"Vacaville"}}),
               captured_at: "2026-11-09T12:00:00Z"
             })

    assert Jason.decode!(File.read!(Path.join(dir, "get/api/v1/jurisdictions/70118.json"))) ==
             %{"data" => %{"id" => 70118, "name" => "Vacaville"}}

    assert File.read!(Path.join(dir, "get/api/v1/jurisdictions/70118.json")) =~ "\n  "

    index = Jason.decode!(File.read!(Path.join(dir, "index.json")))

    assert index["entries"] == [
             %{
               "method" => "GET",
               "path" => "/api/v1/jurisdictions/70118",
               "query" => %{},
               "status" => 200,
               "file" => "get/api/v1/jurisdictions/70118.json",
               "captured_at" => "2026-11-09T12:00:00Z"
             }
           ]
  end

  test "a second request is added and the same request is replaced" do
    dir = fresh_dir()
    put!(dir, "/api/v1/healthz", %{}, ~s({"ok":true}), "2026-11-09T12:00:00Z")

    put!(
      dir,
      "/api/v1/juricode",
      %{"address" => "Vacaville, CA"},
      ~s({"data":[]}),
      "2026-11-09T12:00:01Z"
    )

    put!(
      dir,
      "/api/v1/juricode",
      %{"address" => "Vacaville, CA"},
      ~s({"data":[{"id":70118}]}),
      "2026-11-09T12:00:02Z"
    )

    index = Jason.decode!(File.read!(Path.join(dir, "index.json")))
    files = Enum.map(index["entries"], & &1["file"])

    assert files == [
             "get/api/v1/healthz.json",
             "get/api/v1/juricode__address_vacaville-ca.json"
           ]

    juricode = Enum.find(index["entries"], &(&1["path"] == "/api/v1/juricode"))
    assert juricode["captured_at"] == "2026-11-09T12:00:02Z"
    assert juricode["query"] == %{"address" => "Vacaville, CA"}

    assert Jason.decode!(File.read!(Path.join(dir, juricode["file"]))) ==
             %{"data" => [%{"id" => 70118}]}
  end

  test "a hidden well-known path is stored where other apps can see the file" do
    dir = fresh_dir()

    assert {:ok, "get/well-known/oauth-authorization-server.json"} =
             Store.put(dir, %{
               method: "GET",
               path: "/.well-known/oauth-authorization-server",
               query: %{},
               status: 200,
               body: "{}",
               captured_at: "2026-11-09T12:00:00Z"
             })

    assert File.exists?(Path.join(dir, "get/well-known/oauth-authorization-server.json"))
  end

  test "a body that contains a token is not written" do
    dir = fresh_dir()
    File.write!(Path.join(dir, "index.json"), ~s({"entries":[]}\n))

    assert {:error, :token} =
             Store.put(dir, %{
               method: "POST",
               path: "/api/v1/auth/token",
               query: %{},
               status: 200,
               body: ~s({"access_token":"secret","refresh_token":"also"}),
               captured_at: "2026-11-09T12:00:00Z"
             })

    assert File.read!(Path.join(dir, "index.json")) == ~s({"entries":[]}\n)
    refute File.dir?(Path.join(dir, "post"))
  end

  test "a path that already ends in .json keeps one extension" do
    assert Store.relative_path("GET", "/geo/base_layers.json", %{}) ==
             "get/geo/base_layers.json"

    assert Store.relative_path("GET", "/api/v1/agencies", %{"jurisdiction_id" => "70118"}) ==
             "get/api/v1/agencies__jurisdiction_id_70118.json"

    assert Store.relative_path("GET", "/api/v1/nearby", %{"lat" => "38.35", "lng" => "-121.98"}) ==
             "get/api/v1/nearby__lat_38.35__lng_-121.98.json"
  end

  defp put!(dir, path, query, body, at) do
    assert {:ok, _} =
             Store.put(dir, %{
               method: "GET",
               path: path,
               query: query,
               status: 200,
               body: body,
               captured_at: at
             })
  end

  defp fresh_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "jcli-store-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
