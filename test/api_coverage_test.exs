defmodule JurisdictionalCli.ApiCoverageTest do
  use ExUnit.Case, async: true

  test "public routes the first commands did not call" do
    cases = [
      {["jurisdictions", "autocomplete", "--q", "vaca"], "GET",
       "/api/v1/jurisdictions/autocomplete", "q=vaca"},
      {["jurisdictions", "at-point", "--lat", "38.35", "--lng", "-121.98"], "GET",
       "/api/v1/jurisdictions/at_point", "lng=-121.98"},
      {["jurisdictions", "scene", "70118"], "GET", "/api/v1/jurisdictions/70118/scene", ""},
      {["meetings", "get", "9"], "GET", "/api/v1/meetings/9", ""},
      {["bodies", "positions", "--body", "22917"], "GET", "/api/v1/bodies/22917/positions", ""},
      {["activity", "--period", "7d"], "GET", "/api/v1/activity", "period=7d"},
      {["geo", "layers"], "GET", "/geo/base_layers.json", ""},
      {["geo", "jurisdiction", "70118"], "GET", "/geo/jurisdictions/70118/simplified.json", ""},
      {["well-known"], "GET", "/.well-known/oauth-authorization-server", ""},
      {["health"], "GET", "/healthz", ""},
      {["api", "GET", "/.well-known/oauth-authorization-server"], "GET",
       "/.well-known/oauth-authorization-server", ""}
    ]

    for {args, method, path, query} <- cases do
      assert_route(args, method, path, query)
    end
  end

  test "autocomplete requires a query" do
    {code, _out, err} = capture(["jurisdictions", "autocomplete"])
    assert code == 2
    assert err =~ "--q"
  end

  defp assert_route(args, method, path, query) do
    parent = self()

    {code, _out, err} =
      invoke(args, fn bypass ->
        Bypass.expect_once(bypass, method, path, fn conn ->
          send(parent, {:req, conn.method, conn.request_path, conn.query_string})
          Plug.Conn.resp(conn, 200, "{}")
        end)
      end)

    assert code == 0, "#{inspect(args)} exit #{code}: #{err}"
    assert_received {:req, ^method, ^path, raw}
    if query != "", do: assert(raw =~ query, "#{inspect(args)} query #{raw}")
  end

  defp invoke(args, setup) do
    bypass = Bypass.open()
    setup.(bypass)
    capture(["--host", "http://127.0.0.1:#{bypass.port}" | args])
  end

  defp capture(args) do
    home =
      Path.join(
        System.tmp_dir!(),
        "jcli-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(home)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(home) end)

    JurisdictionalCli.capture(args,
      home: home,
      now: ~U[2026-11-09 12:00:00Z],
      env: %{},
      capture?: true
    )
  end
end
