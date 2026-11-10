defmodule JurisdictionalCli.SaveTest do
  use ExUnit.Case, async: true

  test "--save writes the body and keeps it on stdout" do
    dir = fresh_dir()

    {code, out, err} =
      invoke(["jurisdictions", "get", "70118", "--save", dir], fn bypass ->
        Bypass.expect_once(bypass, "GET", "/api/v1/jurisdictions/70118", fn conn ->
          Plug.Conn.resp(conn, 200, ~s({"data":{"id":70118,"name":"Vacaville"}}))
        end)
      end)

    assert code == 0, err
    assert out =~ "Vacaville"
    assert err =~ "saved get/api/v1/jurisdictions/70118.json\n"

    stored = Jason.decode!(File.read!(Path.join(dir, "get/api/v1/jurisdictions/70118.json")))
    assert stored["data"]["id"] == 70118

    index = Jason.decode!(File.read!(Path.join(dir, "index.json")))
    assert hd(index["entries"])["captured_at"] == "2026-11-09T12:00:00Z"
    assert hd(index["entries"])["path"] == "/api/v1/jurisdictions/70118"
    assert hd(index["entries"])["status"] == 200
  end

  test "an index entry is a receipt: url, sha256 of the file, and the declared license" do
    dir = fresh_dir()

    {code, _out, err} =
      invoke(
        ["agencies", "list", "--jurisdiction", "70118", "--q", "fire & police", "--save", dir],
        fn bypass ->
          Bypass.expect_once(bypass, "GET", "/api/v1/agencies", fn conn ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(</api/v1/agencies?offset=100>; rel="next", </license>; rel="license")
            )
            |> Plug.Conn.resp(200, ~s({"data":[{"id":7,"name":"Fire"}]}))
          end)
        end
      )

    assert code == 0, err
    [entry] = Jason.decode!(File.read!(Path.join(dir, "index.json")))["entries"]
    file = File.read!(Path.join(dir, entry["file"]))

    assert entry["sha256"] == :crypto.hash(:sha256, file) |> Base.encode16(case: :lower)
    assert entry["url"] =~ ~r{\Ahttp://127\.0\.0\.1:\d+/api/v1/agencies\?}
    assert entry["url"] =~ "jurisdiction_id=70118"
    assert entry["url"] =~ "q=fire+%26+police"
    assert entry["license"] =~ ~r{\Ahttp://127\.0\.0\.1:\d+/license\z}
  end

  test "an index entry has no license key when the response names none" do
    dir = fresh_dir()

    {code, _out, err} =
      invoke(["jurisdictions", "get", "70118", "--save", dir], fn bypass ->
        Bypass.expect_once(bypass, "GET", "/api/v1/jurisdictions/70118", fn conn ->
          Plug.Conn.resp(conn, 200, ~s({"data":{"id":70118}}))
        end)
      end)

    assert code == 0, err
    [entry] = Jason.decode!(File.read!(Path.join(dir, "index.json")))["entries"]
    refute Map.has_key?(entry, "license")
    assert is_binary(entry["sha256"])
  end

  test "--save records a redirect as served instead of following it" do
    dir = fresh_dir()
    parent = self()

    {code, _out, _err} =
      invoke(["jurisdictions", "get", "70118", "--save", dir], fn bypass ->
        Bypass.stub(bypass, "GET", "/api/v1/jurisdictions/70118", fn conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "/api/v1/jurisdictions/1")
          |> Plug.Conn.resp(302, ~s({"moved":true}))
        end)

        Bypass.stub(bypass, "GET", "/api/v1/jurisdictions/1", fn conn ->
          send(parent, :followed)
          Plug.Conn.resp(conn, 200, ~s({"data":{"id":1}}))
        end)
      end)

    assert code == 1
    refute_received :followed
    [entry] = Jason.decode!(File.read!(Path.join(dir, "index.json")))["entries"]
    assert entry["status"] == 302
    assert entry["url"] =~ "/api/v1/jurisdictions/70118"
  end

  test "--save without a directory is a usage error" do
    {code, _out, err} = invoke(["health", "--save"], fn _bypass -> :ok end)
    assert code == 2
    assert err =~ "--save needs a value"
  end

  test "a token response is not saved" do
    dir = fresh_dir()

    {code, _out, err} =
      invoke(["jurisdictions", "get", "1", "--save", dir], fn bypass ->
        Bypass.expect_once(bypass, "GET", "/api/v1/jurisdictions/1", fn conn ->
          Plug.Conn.resp(conn, 200, ~s({"access_token":"secret"}))
        end)
      end)

    assert code == 1
    assert err =~ "not saving a response that contains a token"
    refute File.exists?(Path.join(dir, "index.json"))
    refute File.dir?(Path.join(dir, "get"))
  end

  test "login still stores credentials and does not copy the token into --save" do
    home = fresh_home()
    dir = fresh_dir()

    {code, out, err} =
      invoke(
        ["login", "--paste", "--save", dir],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"access_token":"jur_new","refresh_token":"jur_ref","expires_in":3600})
            )
          end)
        end,
        home: home,
        lines: ["jur_ref_shown"]
      )

    assert code == 1
    assert out =~ "stored credentials"
    assert err =~ "not saving a response that contains a token"
    assert File.read!(Path.join(home, ".jurisdictional/credentials.json")) =~ "jur_new"
    refute File.exists?(Path.join(dir, "index.json"))
    refute File.dir?(Path.join(dir, "post"))
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
      capture?: true,
      lines: Keyword.get(opts, :lines, [])
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

  defp fresh_dir do
    dir = Path.join(fresh_home(), "responses")
    File.mkdir_p!(dir)
    dir
  end
end
