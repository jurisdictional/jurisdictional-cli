defmodule JurisdictionalCli.AccountTest do
  use ExUnit.Case, async: true

  test "signed-in reads" do
    cases = [
      {["me"], "GET", "/api/v1/me", ""},
      {["me", "jurisdictions"], "GET", "/api/v1/me/jurisdictions", ""},
      {["me", "officials"], "GET", "/api/v1/me/officials", ""},
      {["me", "contributions"], "GET", "/api/v1/me/contributions", ""},
      {["me", "feed"], "GET", "/api/v1/me/feed", ""},
      {["me", "notifications"], "GET", "/api/v1/me/notification-preferences", ""},
      {["devices", "list"], "GET", "/api/v1/devices", ""},
      {["devices", "remove", "phone-1"], "DELETE", "/api/v1/devices/phone-1", ""},
      {["sync", "jurisdictions", "--since", "2026-01-01"], "GET", "/api/v1/sync/jurisdictions",
       "since=2026-01-01"},
      {["sync", "officials"], "GET", "/api/v1/sync/officials", ""}
    ]

    for {args, method, path, query} <- cases do
      assert_route(args, method, path, query)
    end
  end

  test "devices add and notification updates send json" do
    parent = self()

    {code, _out, err} =
      invoke(
        ["devices", "add", "--platform", "ios", "--device-id", "phone-1", "--push-token", "abc"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/devices", fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(raw)})
            Plug.Conn.resp(conn, 201, ~s({"data":{"id":1}}))
          end)
        end
      )

    assert code == 0, err

    assert_received {:body,
                     %{"platform" => "ios", "device_id" => "phone-1", "push_token" => "abc"}}

    {code, _out, err} =
      invoke(["me", "notifications", "set", "--meetings", "true"], fn bypass ->
        Bypass.expect_once(bypass, "PUT", "/api/v1/me/notification-preferences", fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:prefs, Jason.decode!(raw)})
          Plug.Conn.resp(conn, 200, ~s({"data":{"meetings":true}}))
        end)
      end)

    assert code == 0, err
    assert_received {:prefs, %{"meetings" => true}}
  end

  test "logout revokes the refresh token and leaves the long-lived token file" do
    home = fresh_home()
    dir = Path.join(home, ".jurisdictional")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "token"), "long-lived\n")

    File.write!(
      Path.join(dir, "credentials.json"),
      Jason.encode!(%{"access_token" => "old", "refresh_token" => "ref"})
    )

    parent = self()

    {code, _out, err} =
      invoke(
        ["logout"],
        fn bypass ->
          Bypass.expect_once(bypass, "DELETE", "/api/v1/auth/token", fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)

            send(
              parent,
              {:body, Jason.decode!(raw), Plug.Conn.get_req_header(conn, "authorization")}
            )

            Plug.Conn.resp(conn, 200, ~s({"ok":true}))
          end)
        end,
        home: home
      )

    assert code == 0, err
    assert_received {:body, %{"refresh_token" => "ref"}, ["Bearer old"]}
    refute File.exists?(Path.join(dir, "credentials.json"))
    assert File.read!(Path.join(dir, "token")) == "long-lived\n"
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

  defp invoke(args, setup, opts \\ []) do
    bypass = Bypass.open()
    setup.(bypass)
    home = Keyword.get(opts, :home) || fresh_home()

    JurisdictionalCli.capture(
      ["--host", "http://127.0.0.1:#{bypass.port}" | args],
      home: home,
      now: ~U[2026-11-09 12:00:00Z],
      env: %{},
      capture?: true
    )
  end

  defp fresh_home do
    home =
      Path.join(
        System.tmp_dir!(),
        "jcli-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(home)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(home) end)
    home
  end
end
