defmodule JurisdictionalCli.WritesTest do
  use ExUnit.Case, async: true

  test "json writes hit the documented paths" do
    home = fresh_home()

    page =
      write_json!(home, "page.json", %{"url" => "https://example.gov", "html" => "<p>hi</p>"})

    doc = write_json!(home, "doc.json", %{"jurisdiction_id" => 70118})
    claim = write_json!(home, "claim.json", %{"task_id" => 9, "accepted" => true})
    batch = Path.join(home, "rpc.json")
    File.write!(batch, ~s([{"jsonrpc":"2.0","id":1}]\n))

    parent = self()

    cases = [
      {[
         "contributions",
         "quick",
         "--entity-type",
         "agency",
         "--entity-id",
         "13012",
         "--field",
         "name",
         "--suggested-value",
         "City of Vacaville"
       ], "POST", "/api/v1/contributions/quick",
       %{
         "entity_type" => "agency",
         "entity_id" => 13012,
         "field" => "name",
         "suggested_value" => "City of Vacaville"
       }},
      {["gather", "submit", "--file", page], "POST", "/api/v1/gather/submissions",
       %{"url" => "https://example.gov", "html" => "<p>hi</p>"}},
      {["tax", "import", "--file", doc], "POST", "/api/v1/tax/import",
       %{"jurisdiction_id" => 70118}},
      {["sourcing", "results", "--file", claim], "POST", "/api/v1/sourcing/results",
       %{"task_id" => 9, "accepted" => true}},
      {["sourcing", "generate", "--file", claim], "POST", "/api/v1/sourcing/generate",
       %{"task_id" => 9, "accepted" => true}},
      {["images", "person", "4", "--url", "https://example.gov/a.jpg"], "POST",
       "/api/v1/people/4/images", %{"url" => "https://example.gov/a.jpg"}},
      {["images", "jurisdiction", "70118", "--kind", "seal"], "POST",
       "/api/v1/jurisdictions/70118/images", %{"kind" => "seal"}}
    ]

    for {args, method, path, expected} <- cases do
      {code, _out, err} =
        invoke(args, home, fn bypass ->
          Bypass.expect_once(bypass, method, path, fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, path, Jason.decode!(raw)})
            Plug.Conn.resp(conn, 201, ~s({"ok":true}))
          end)
        end)

      assert code == 0, "#{inspect(args)} exit #{code}: #{err}"
      assert_received {:body, ^path, ^expected}
    end

    {code, out, err} =
      invoke(["message", "--file", batch], home, fn bypass ->
        Bypass.expect_once(bypass, "POST", "/api/mcp/message", fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(parent, {:raw, raw})
          Plug.Conn.resp(conn, 200, ~s({"jsonrpc":"2.0","id":1,"result":{}}))
        end)
      end)

    assert code == 0, err
    assert out =~ "jsonrpc"
    assert_received {:raw, ~s([{"jsonrpc":"2.0","id":1}]\n)}
  end

  test "sourcing and image reads stay gets" do
    parent = self()

    cases = [
      {["sourcing", "next", "--jurisdiction-id", "70118"], "GET", "/api/v1/sourcing/next",
       "jurisdiction_id=70118"},
      {["sourcing", "stats"], "GET", "/api/v1/sourcing/stats", ""},
      {["images", "get", "9"], "GET", "/api/v1/images/9", ""}
    ]

    for {args, method, path, query} <- cases do
      {code, _out, err} =
        invoke(args, fresh_home(), fn bypass ->
          Bypass.expect_once(bypass, method, path, fn conn ->
            send(parent, {:req, path, conn.query_string})
            Plug.Conn.resp(conn, 200, "{}")
          end)
        end)

      assert code == 0, "#{inspect(args)} exit #{code}: #{err}"
      assert_received {:req, ^path, raw}
      if query != "", do: assert(raw == query)
      _ = method
    end
  end

  test "--image and --photo send a multipart file part to the upload paths" do
    home = fresh_home()
    png = Path.join(home, "headshot.png")
    File.write!(png, <<137, 80, 78, 71, 13, 10, 26, 10, "fake png bytes">>)
    jpg = Path.join(home, "seal.jpg")
    File.write!(jpg, <<255, 216, 255, "fake jpg bytes">>)
    digest = fn path -> :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower) end
    parent = self()

    cases = [
      {["images", "person", "4", "--image", png, "--kind", "headshot", "--face-box", ~s({"x":1})],
       "/api/v1/people/4/images", "image", png, "image/png",
       %{"kind" => "headshot", "face_box" => ~s({"x":1}), "image_sha256" => digest.(png)}},
      {["images", "jurisdiction", "70118", "--image", jpg, "--kind", "seal"],
       "/api/v1/jurisdictions/70118/images", "image", jpg, "image/jpeg",
       %{"kind" => "seal", "image_sha256" => digest.(jpg)}},
      {["contributions", "quick", "--photo", jpg, "--entity-type", "person", "--entity-id", "4"],
       "/api/v1/contributions/quick", "photo", jpg, "image/jpeg",
       %{"entity_type" => "person", "entity_id" => "4"}}
    ]

    for {args, path, part, file, content_type, fields} <- cases do
      {code, _out, err} =
        invoke(args, home, fn bypass ->
          Bypass.expect_once(bypass, "POST", path, fn conn ->
            [type] = Plug.Conn.get_req_header(conn, "content-type")

            conn =
              Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:multipart], pass: ["*/*"]))

            {upload, params} = Map.pop(conn.body_params, part)

            send(
              parent,
              {:multipart, path, type, File.read!(upload.path), upload.filename,
               upload.content_type, params}
            )

            Plug.Conn.resp(conn, 201, ~s({"ok":true}))
          end)
        end)

      assert code == 0, "#{inspect(args)} exit #{code}: #{err}"
      assert_received {:multipart, ^path, type, bytes, filename, ^content_type, params}
      assert type =~ "multipart/form-data; boundary="
      assert bytes == File.read!(file)
      assert filename == Path.basename(file)
      assert params == fields
    end
  end

  test "an upload flag without a readable file exits 2 before any request" do
    home = fresh_home()

    for args <- [
          ["images", "person", "4", "--image", Path.join(home, "missing.png")],
          ["contributions", "quick", "--photo", home]
        ] do
      {code, _out, err} = invoke(args, home, fn _bypass -> :ok end)
      assert code == 2, "#{inspect(args)} exit #{code}: #{err}"
      assert err =~ "no file at"
    end
  end

  test "a write that needs a file exits 2 without one" do
    for args <- [
          ["gather", "submit"],
          ["tax", "import"],
          ["sourcing", "results"],
          ["sourcing", "generate"],
          ["message"]
        ] do
      {code, _out, err} = invoke(args, fresh_home(), fn _bypass -> :ok end)
      assert code == 2, "#{inspect(args)} exit #{code}: #{err}"
      assert err =~ "--file" or err =~ "requires --file"
    end
  end

  test "message rejects flags other than --file" do
    home = fresh_home()
    path = Path.join(home, "rpc.json")
    File.write!(path, "{}")

    {code, _out, err} =
      invoke(["message", "--file", path, "--tool", "juricode"], home, fn _bypass -> :ok end)

    assert code == 2
    assert err =~ "only --file"
  end

  defp write_json!(home, name, object) do
    path = Path.join(home, name)
    File.write!(path, Jason.encode!(object))
    path
  end

  defp invoke(args, home, setup) do
    bypass = Bypass.open()
    setup.(bypass)

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
