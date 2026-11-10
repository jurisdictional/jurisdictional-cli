defmodule JurisdictionalCliTest do
  use ExUnit.Case, async: true

  @tools """
  {
    "tools": [
      {
        "name": "get_coverage",
        "description": "coverage",
        "inputSchema": {
          "type": "object",
          "properties": {"jurisdiction_id": {"type": "integer"}},
          "required": ["jurisdiction_id"]
        }
      },
      {
        "name": "delete_entity",
        "description": "delete",
        "inputSchema": {
          "type": "object",
          "properties": {"id": {"type": "integer"}, "dry_run": {"type": "boolean"}}
        }
      }
    ]
  }
  """

  test "api matches path and query and sends no token" do
    parent = self()

    {code, out, err} =
      invoke(
        [
          "api",
          "GET",
          "/juricode",
          "--address",
          "300 Hemlock St, Vacaville, CA",
          "--include",
          "seats"
        ],
        fn bypass ->
          Bypass.expect_once(bypass, "GET", "/api/v1/juricode", fn conn ->
            send(parent, {:req, conn.query_string, req_headers(conn)})
            Plug.Conn.resp(conn, 200, ~s({"data":{"address":"300 Hemlock St"}}))
          end)
        end
      )

    assert code == 0, err
    assert_received {:req, query, headers}
    assert query =~ "address=300+Hemlock+St"
    assert query =~ "include=seats"
    assert headers["authorization"] == nil
    assert headers["accept"] == "application/json"
    assert headers["user-agent"] =~ "jurisdictional-cli/"
    assert out =~ ~s("address":"300 Hemlock St")
  end

  test "an absolute /api path is not prefixed" do
    parent = self()

    {code, _out, err} =
      invoke(["api", "GET", "/api/mcp/tools"], fn bypass ->
        Bypass.expect_once(bypass, "GET", "/api/mcp/tools", fn conn ->
          send(parent, {:path, conn.request_path})
          Plug.Conn.resp(conn, 200, ~s({"tools":[]}))
        end)
      end)

    assert code == 0, err
    assert_received {:path, "/api/mcp/tools"}
  end

  test "profile sets the accept header and keeps the host" do
    parent = self()

    {code, _out, err} =
      invoke(["--profile", "hsds", "api", "GET", "/agencies/13012"], fn bypass ->
        Bypass.expect_once(bypass, "GET", "/api/v1/agencies/13012", fn conn ->
          send(parent, {:accept, req_headers(conn)["accept"]})
          Plug.Conn.resp(conn, 200, "{}")
        end)
      end)

    assert code == 0, err
    assert_received {:accept, ~s(application/json; profile="hsds")}
  end

  test "tool get_coverage posts the schema-typed arguments" do
    parent = self()

    {code, out, err} =
      invoke(
        ["--token", "jur_test", "tool", "get_coverage", "--jurisdiction-id", "81554"],
        fn bypass ->
          Bypass.expect_once(bypass, "GET", "/api/mcp/tools", fn conn ->
            assert req_headers(conn)["authorization"] == "Bearer jur_test"
            Plug.Conn.resp(conn, 200, @tools)
          end)

          Bypass.expect_once(bypass, "POST", "/api/mcp/execute", fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(raw)})
            Plug.Conn.resp(conn, 200, ~s({"agencies":3}))
          end)
        end
      )

    assert code == 0, err

    assert_received {:body,
                     %{"tool" => "get_coverage", "arguments" => %{"jurisdiction_id" => 81554}}}

    assert out =~ ~s("agencies":3)
  end

  test "curated reads use the router paths" do
    cases = [
      {["juricode", "300 Hemlock St, Vacaville, CA"], "/api/v1/juricode",
       "address=300+Hemlock+St"},
      {["jurisdictions", "list", "--q", "vacaville"], "/api/v1/jurisdictions", "q=vacaville"},
      {["jurisdictions", "get", "81554"], "/api/v1/jurisdictions/81554", ""},
      {["agencies", "list", "--jurisdiction", "81554"], "/api/v1/agencies",
       "jurisdiction_id=81554"},
      {["agencies", "get", "13012"], "/api/v1/agencies/13012", ""},
      {["bodies", "list", "--jurisdiction", "81554"], "/api/v1/jurisdictions/81554/bodies", ""},
      {["meetings", "list", "--body", "22917"], "/api/v1/bodies/22917/meetings", ""},
      {["people", "get", "445"], "/api/v1/people/445", ""},
      {["nearby", "--lat", "38.35", "--lng", "-121.98"], "/api/v1/nearby", "lat=38.35"}
    ]

    for {args, path, query} <- cases do
      parent = self()

      {code, _out, err} =
        invoke(args, fn bypass ->
          Bypass.expect_once(bypass, "GET", path, fn conn ->
            send(parent, {:req, conn.request_path, conn.query_string})
            Plug.Conn.resp(conn, 200, ~s({"data":[]}))
          end)
        end)

      assert code == 0, "#{inspect(args)} exit #{code}: #{err}"
      assert_received {:req, ^path, raw}
      if query != "", do: assert(raw =~ query, "#{inspect(args)} query #{raw}")
      if path == "/api/v1/nearby", do: assert(raw =~ "lng=-121.98")
      if path == "/api/v1/jurisdictions/81554/bodies", do: assert(raw == "")
    end
  end

  test "exit codes for 401, an error body, usage, and the network" do
    {code, _out, err} =
      invoke(["api", "GET", "/juricode"], fn bypass ->
        Bypass.expect_once(bypass, fn conn ->
          Plug.Conn.resp(conn, 401, ~s({"error":{"message":"no"}}))
        end)
      end)

    assert code == 4
    assert err =~ "jurisdictional login"

    {code, _out, _err} =
      invoke(["api", "GET", "/juricode"], fn bypass ->
        Bypass.expect_once(bypass, fn conn ->
          Plug.Conn.resp(conn, 422, ~s({"error":{"message":"no match"}}))
        end)
      end)

    assert code == 1

    {code, _out, err} = capture(["nope"])
    assert code == 2
    assert err =~ "unknown command"

    {code, _out, err} =
      capture(["--host", "http://127.0.0.1:1", "api", "GET", "/juricode"])

    assert code == 3, err
  end

  test "rate limit notice stays quiet when the limit is unlimited" do
    {code, _out, err} =
      invoke(["api", "GET", "/people/1"], fn bypass ->
        Bypass.expect_once(bypass, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-ratelimit-limit", "100")
          |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "5")
          |> Plug.Conn.resp(200, "{}")
        end)
      end)

    assert code == 0
    assert err =~ "rate limit: 5 of 100 remaining"

    {_code, _out, err} =
      invoke(["api", "GET", "/people/1"], fn bypass ->
        Bypass.expect_once(bypass, fn conn ->
          conn
          |> Plug.Conn.put_resp_header("x-ratelimit-limit", "unlimited")
          |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "unlimited")
          |> Plug.Conn.resp(200, "{}")
        end)
      end)

    assert err == ""
  end

  test "login has no password sign-in" do
    {code, _out, err} = capture(["login", "--password"])
    assert code == 2
    assert err =~ "unknown flag --password"

    {code, _out, err} = capture(["login", "--email", "ada@example.com"])
    assert code == 2
    assert err =~ "unknown flag --email"

    {code, out, _err} = capture(["help"])
    assert code == 0
    refute out =~ "password"
  end

  test "--paste refuses a token on the command line, without repeating it" do
    {code, out, err} = capture(["login", "--paste", "jur_ref-on-argv"])

    assert code == 2
    assert err =~ "shell history"
    refute err =~ "jur_ref-on-argv"
    refute out =~ "jur_ref-on-argv"
  end

  test "a pasted token never reaches output, credentials, or a saved file" do
    token = "jur_ref-Zq8!never-shown"
    home = fresh_home()
    dir = Path.join(home, "saved")
    parent = self()

    for status <- [200, 401, 500] do
      {_code, out, err} =
        invoke(
          ["login", "--paste", "--save", dir],
          fn bypass ->
            Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
              {:ok, raw, conn} = Plug.Conn.read_body(conn)
              send(parent, {:sent, Jason.decode!(raw)["refresh_token"]})

              body =
                if status == 200,
                  do: ~s({"access_token":"jur_new","refresh_token":"jur_ref","expires_in":3600}),
                  else: ~s({"error":"nope"})

              Plug.Conn.resp(conn, status, body)
            end)
          end,
          home: home,
          lines: [token],
          tty?: true
        )

      # The server still gets the real token.
      assert_received {:sent, ^token}
      assert err =~ "paste the token: "
      refute out =~ token
      refute err =~ token
    end

    {_code, out, err} =
      capture(["--host", "http://127.0.0.1:1", "login", "--paste"],
        home: home,
        lines: [token]
      )

    assert err =~ "request failed"
    refute out =~ token
    refute err =~ token

    for file <- Path.wildcard(Path.join(home, "**/*"), match_dot: true), File.regular?(file) do
      refute File.read!(file) =~ token, "token found in #{file}"
    end
  end

  test "an inspected secret shows as redacted" do
    secret = JurisdictionalCli.Secret.Redacted.wrap("jur_ref-Zq8!never-shown")

    refute inspect(secret) =~ "never-shown"
    refute inspect(%{"refresh_token" => secret}) =~ "never-shown"
    refute to_string(secret) =~ "never-shown"

    assert Jason.encode!(%{"refresh_token" => secret}) ==
             ~s({"refresh_token":"jur_ref-Zq8!never-shown"})
  end

  test "login --paste stores credentials at mode 600 and leaves the long-lived token file" do
    home = fresh_home()
    token = Path.join(home, ".jurisdictional/token")
    File.mkdir_p!(Path.dirname(token))
    File.write!(token, "long-lived\n")

    {code, out, err} =
      invoke(
        ["login", "--paste"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"access_token":"jur_new","refresh_token":"jur_ref","expires_in":3600,"user":{"email":"ada@example.com"}})
            )
          end)
        end,
        home: home,
        lines: ["jur_ref_shown"]
      )

    assert code == 0, err
    assert out =~ "stored credentials for ada@example.com"
    assert File.read!(token) == "long-lived\n"

    cred_path = Path.join(home, ".jurisdictional/credentials.json")
    stat = File.stat!(cred_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600

    saved = File.read!(cred_path)
    assert saved =~ "jur_new"
    assert saved =~ "2026-11-09T13:00:00Z"
    refute saved =~ "jur_ref_shown"
  end

  test "login with expires_in 0 does not store an expiry" do
    home = fresh_home()

    {code, _out, err} =
      invoke(
        ["login", "--paste"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"access_token":"jur_new","refresh_token":"jur_ref","expires_in":0})
            )
          end)
        end,
        home: home,
        lines: ["jur_ref_shown"]
      )

    assert code == 0, err
    saved = File.read!(Path.join(home, ".jurisdictional/credentials.json"))
    refute saved =~ "expires_at"
  end

  test "login opens the browser, prints the code, and stores tokens after approval" do
    home = fresh_home()
    token_file = Path.join(home, ".jurisdictional/token")
    File.mkdir_p!(Path.dirname(token_file))
    File.write!(token_file, "long-lived\n")
    parent = self()
    polls = :counters.new(1, [])

    {code, out, err} =
      invoke(
        ["login"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:device, req_headers(conn)["authorization"], Jason.decode!(raw)})

            Plug.Conn.resp(
              conn,
              200,
              Jason.encode!(%{
                "device_code" => "device-code-secret",
                "user_code" => "BCDF-GHJK",
                "verification_uri" => "https://jurisdictional.org/device",
                "verification_uri_complete" =>
                  "https://jurisdictional.org/device?user_code=BCDF-GHJK",
                "expires_in" => 600,
                "interval" => 5
              })
            )
          end)

          Bypass.expect(bypass, "POST", "/api/v1/auth/token", fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:poll, req_headers(conn)["authorization"], Jason.decode!(raw)})
            n = :counters.get(polls, 1)
            :counters.add(polls, 1, 1)

            if n == 0 do
              Plug.Conn.resp(
                conn,
                400,
                ~s({"error":"authorization_pending","error_description":"The request has not been approved yet."})
              )
            else
              Plug.Conn.resp(conn, 200, device_token_json())
            end
          end)
        end,
        home: home,
        device_name: "test-host",
        sleep: fn seconds -> send(parent, {:slept, seconds}) end,
        open: fn url -> send(parent, {:opened, url}) end
      )

    assert code == 0, err
    assert err =~ "Sign in at https://jurisdictional.org/device\n"
    assert err =~ "Code: BCDF-GHJK"
    assert err =~ "Device: test-host"
    assert err =~ "Waiting for approval."
    assert out =~ "stored credentials for ada@example.com"
    refute out =~ "device-code-secret"
    refute err =~ "device-code-secret"
    refute out =~ "jur_access"
    refute err =~ "jur_access"
    refute out =~ "jur_refresh"
    refute err =~ "jur_refresh"

    assert_received {:opened, "https://jurisdictional.org/device?user_code=BCDF-GHJK"}
    assert_received {:slept, 5}

    assert_received {
      :device,
      nil,
      %{"client_id" => "jurisdictional-cli", "device_name" => "test-host"}
    }

    assert_received {
      :poll,
      nil,
      %{
        "grant_type" => "urn:ietf:params:oauth:grant-type:device_code",
        "device_code" => "device-code-secret",
        "client_id" => "jurisdictional-cli"
      }
    }

    assert File.read!(token_file) == "long-lived\n"
    cred_path = Path.join(home, ".jurisdictional/credentials.json")
    stat = File.stat!(cred_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    saved = File.read!(cred_path)
    assert saved =~ "jur_access"
    assert saved =~ "jur_refresh"
    assert saved =~ "ada@example.com"
    assert saved =~ "2026-11-09T13:00:00Z"
  end

  test "login says when the browser cannot be opened and still waits" do
    home = fresh_home()

    {code, out, err} =
      invoke(
        ["login"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            Plug.Conn.resp(conn, 200, device_start_json())
          end)

          Bypass.expect_once(bypass, "POST", "/api/v1/auth/token", fn conn ->
            Plug.Conn.resp(conn, 200, device_token_json())
          end)
        end,
        home: home,
        device_name: "test-host",
        sleep: fn _seconds -> :ok end,
        open: fn _url -> :error end
      )

    assert code == 0, err
    assert err =~ "Could not open a browser."
    assert out =~ "stored credentials for ada@example.com"
  end

  test "login --no-browser prints the code and does not open a page" do
    home = fresh_home()
    parent = self()

    {code, _out, err} =
      invoke(
        ["login", "--no-browser"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            Plug.Conn.resp(conn, 200, device_start_json())
          end)

          Bypass.expect_once(bypass, "POST", "/api/v1/auth/token", fn conn ->
            Plug.Conn.resp(conn, 200, device_token_json())
          end)
        end,
        home: home,
        device_name: "test-host",
        sleep: fn _seconds -> :ok end,
        open: fn url -> send(parent, {:opened, url}) end
      )

    assert code == 0, err
    assert err =~ "Code: BCDF-GHJK"
    refute_received {:opened, _}
  end

  test "a denied device sign-in stores nothing" do
    home = fresh_home()

    {code, out, err} =
      invoke(
        ["login"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            Plug.Conn.resp(conn, 200, device_start_json())
          end)

          Bypass.expect_once(bypass, "POST", "/api/v1/auth/token", fn conn ->
            Plug.Conn.resp(
              conn,
              400,
              ~s({"error":"access_denied","error_description":"The request was denied."})
            )
          end)
        end,
        home: home,
        device_name: "test-host",
        sleep: fn _seconds -> :ok end,
        open: fn _url -> :ok end
      )

    assert code == 1, err
    assert err =~ "The sign-in was denied."
    assert out == ""
    refute File.exists?(Path.join(home, ".jurisdictional/credentials.json"))
  end

  test "an already used device sign-in stores nothing" do
    home = fresh_home()

    {code, _out, err} =
      invoke(
        ["login"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            Plug.Conn.resp(conn, 200, device_start_json())
          end)

          Bypass.expect_once(bypass, "POST", "/api/v1/auth/token", fn conn ->
            Plug.Conn.resp(
              conn,
              400,
              ~s({"error":"invalid_grant","error_description":"Unknown or already used device code."})
            )
          end)
        end,
        home: home,
        device_name: "test-host",
        sleep: fn _seconds -> :ok end,
        open: fn _url -> :ok end
      )

    assert code == 1, err
    assert err =~ "already used"
    refute File.exists?(Path.join(home, ".jurisdictional/credentials.json"))
    refute err =~ "device-code-secret"
  end

  test "polling too fast waits longer" do
    home = fresh_home()
    parent = self()
    polls = :counters.new(1, [])

    {code, _out, err} =
      invoke(
        ["login"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            Plug.Conn.resp(conn, 200, device_start_json())
          end)

          Bypass.expect(bypass, "POST", "/api/v1/auth/token", fn conn ->
            n = :counters.get(polls, 1)
            :counters.add(polls, 1, 1)

            if n == 0 do
              Plug.Conn.resp(
                conn,
                400,
                ~s({"error":"slow_down","error_description":"Polling too fast; wait 5 seconds longer between polls."})
              )
            else
              Plug.Conn.resp(conn, 200, device_token_json())
            end
          end)
        end,
        home: home,
        device_name: "test-host",
        sleep: fn seconds -> send(parent, {:slept, seconds}) end,
        open: fn _url -> :ok end
      )

    assert code == 0, err
    assert_received {:slept, 10}
  end

  test "a server without browser sign-in points at --token" do
    home = fresh_home()

    {code, _out, err} =
      invoke(
        ["login"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/device", fn conn ->
            Plug.Conn.resp(conn, 404, "not found")
          end)
        end,
        home: home,
        device_name: "test-host",
        open: fn _url -> send(self(), :opened) end
      )

    assert code == 1, err
    assert err =~ "--token"
    refute_received :opened
  end

  test "login --token is refused because that flag is a one-shot bearer" do
    {code, out, err} = capture(["login", "--token", "jur_secret"])

    assert code == 2
    assert err =~ "login --paste"
    assert out == ""
    refute err =~ "jur_secret"
  end

  test "login --paste redeems the refresh token shown on the approval page" do
    home = fresh_home()
    token_file = Path.join(home, ".jurisdictional/token")
    File.mkdir_p!(Path.dirname(token_file))
    File.write!(token_file, "long-lived\n")
    parent = self()

    {code, out, err} =
      invoke(
        ["login", "--paste"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:refresh, req_headers(conn)["authorization"], Jason.decode!(raw)})

            Plug.Conn.resp(
              conn,
              200,
              ~s({"access_token":"jur_access","refresh_token":"jur_refresh_new","expires_in":3600})
            )
          end)
        end,
        home: home,
        tty?: true,
        lines: ["jur_ref_shown"]
      )

    assert code == 0, err
    assert err =~ "paste the token: "
    assert err =~ "signing in"
    assert out =~ "stored credentials"
    refute out =~ "for "
    refute out =~ "jur_ref_shown"
    refute err =~ "jur_ref_shown"
    refute out =~ "jur_access"
    assert_received {:refresh, nil, %{"refresh_token" => "jur_ref_shown"}}
    assert File.read!(token_file) == "long-lived\n"
    saved = File.read!(Path.join(home, ".jurisdictional/credentials.json"))
    assert saved =~ "jur_access"
    assert saved =~ "jur_refresh_new"
    refute saved =~ "jur_ref_shown"
  end

  test "a rejected pasted token is not stored" do
    home = fresh_home()

    {code, out, err} =
      invoke(
        ["login", "--paste"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            Plug.Conn.resp(conn, 401, ~s({"error":{"message":"Invalid refresh token"}}))
          end)
        end,
        home: home,
        lines: ["jur_ref_shown"]
      )

    assert code == 4
    assert err =~ "was not accepted"
    assert out =~ "Invalid refresh token"
    refute err =~ "jur_ref_shown"
    refute out =~ "jur_ref_shown"
    refute File.exists?(Path.join(home, ".jurisdictional/credentials.json"))
  end

  defp device_start_json do
    Jason.encode!(%{
      "device_code" => "device-code-secret",
      "user_code" => "BCDF-GHJK",
      "verification_uri" => "https://jurisdictional.org/device",
      "verification_uri_complete" => "https://jurisdictional.org/device?user_code=BCDF-GHJK",
      "expires_in" => 600,
      "interval" => 5
    })
  end

  defp device_token_json do
    Jason.encode!(%{
      "access_token" => "jur_access",
      "refresh_token" => "jur_refresh",
      "expires_in" => 3600,
      "token_type" => "Bearer",
      "user" => %{"email" => "ada@example.com"}
    })
  end

  test "an unexpired credential is sent and not refreshed" do
    home = fresh_home()
    write_creds(home, %{"access_token" => "still-good", "refresh_token" => "ref"})
    parent = self()

    {code, _out, err} =
      invoke(
        ["api", "GET", "/people/1"],
        fn bypass ->
          Bypass.expect_once(bypass, "GET", "/api/v1/people/1", fn conn ->
            send(parent, {:auth, req_headers(conn)["authorization"]})
            Plug.Conn.resp(conn, 200, ~s({"data":{"id":1,"name":"Ada"}}))
          end)
        end,
        home: home
      )

    assert code == 0, err
    assert_received {:auth, "Bearer still-good"}
  end

  test "an expired credential is refreshed before the read" do
    home = fresh_home()

    write_creds(home, %{
      "access_token" => "old",
      "refresh_token" => "ref",
      "email" => "ada@example.com",
      "expires_at" => "2020-01-01T00:00:00Z"
    })

    parent = self()

    {code, _out, err} =
      invoke(
        ["api", "GET", "/people/1"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            Plug.Conn.resp(
              conn,
              200,
              ~s({"access_token":"new","refresh_token":"ref2","expires_in":3600})
            )
          end)

          Bypass.expect_once(bypass, "GET", "/api/v1/people/1", fn conn ->
            send(parent, {:auth, req_headers(conn)["authorization"]})
            Plug.Conn.resp(conn, 200, ~s({"data":{"id":1,"name":"Ada"}}))
          end)
        end,
        home: home
      )

    assert code == 0, err
    assert_received {:auth, "Bearer new"}
    saved = File.read!(Path.join(home, ".jurisdictional/credentials.json"))
    assert saved =~ "ada@example.com"
    assert saved =~ "new"
  end

  test "a rejected refresh falls through to the token file" do
    home = fresh_home()

    write_creds(home, %{
      "access_token" => "old",
      "refresh_token" => "ref",
      "expires_at" => "2020-01-01T00:00:00Z"
    })

    File.write!(Path.join(home, ".jurisdictional/token"), "long-lived\n")
    parent = self()

    {code, out, err} =
      invoke(
        ["api", "GET", "/people/1"],
        fn bypass ->
          Bypass.expect_once(bypass, "POST", "/api/v1/auth/refresh", fn conn ->
            Plug.Conn.resp(conn, 401, ~s({"error":{"message":"refresh-rejected"}}))
          end)

          Bypass.expect_once(bypass, "GET", "/api/v1/people/1", fn conn ->
            send(parent, {:auth, req_headers(conn)["authorization"]})
            Plug.Conn.resp(conn, 200, ~s({"data":{"id":1}}))
          end)
        end,
        home: home
      )

    assert code == 0, err
    assert_received {:auth, "Bearer long-lived"}
    refute out =~ "refresh-rejected"
    assert File.read!(Path.join(home, ".jurisdictional/token")) == "long-lived\n"
  end

  test "a revoked env token is sent and is not retried without it" do
    parent = self()

    {code, out, err} =
      invoke(
        ["api", "GET", "/people/1"],
        fn bypass ->
          Bypass.expect_once(bypass, "GET", "/api/v1/people/1", fn conn ->
            send(parent, {:auth, req_headers(conn)["authorization"]})
            Plug.Conn.resp(conn, 401, ~s({"error":"no"}))
          end)
        end,
        env: %{"JURISDICTIONAL_TOKEN" => "revoked"}
      )

    assert code == 4, err
    assert_received {:auth, "Bearer revoked"}
    assert err =~ "jurisdictional login"
    assert out =~ "no"
  end

  test "delete_entity is refused without --yes and sent with it" do
    parent = self()

    {code, _out, err} =
      invoke(["tool", "delete_entity", "--id", "9"], fn bypass ->
        Bypass.expect(bypass, fn conn ->
          send(parent, {:hit, conn.method, conn.request_path})
          Plug.Conn.resp(conn, 200, @tools)
        end)
      end)

    assert code == 2, err
    assert err =~ "refusing to call delete_entity"
    refute Enum.any?(flush(:hit), fn {_method, path} -> path == "/api/mcp/execute" end)

    parent = self()

    {code, _out, err} =
      invoke(["--yes", "tool", "delete_entity", "--id", "9"], fn bypass ->
        Bypass.expect(bypass, fn conn ->
          send(parent, {:hit, conn.method, conn.request_path})

          body =
            if conn.request_path == "/api/mcp/execute" do
              ~s({"deleted":true})
            else
              @tools
            end

          Plug.Conn.resp(conn, 200, body)
        end)
      end)

    assert code == 0, err
    assert Enum.count(flush(:hit), fn {_method, path} -> path == "/api/mcp/execute" end) == 1
  end

  test "dry-run skips the destructive confirmation" do
    parent = self()

    {code, _out, err} =
      invoke(["tool", "delete_entity", "--id", "9", "--dry-run", "true"], fn bypass ->
        Bypass.expect(bypass, fn conn ->
          if conn.request_path == "/api/mcp/execute" do
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(parent, {:body, Jason.decode!(raw)})
            Plug.Conn.resp(conn, 200, ~s({"dry_run":true}))
          else
            Plug.Conn.resp(conn, 200, @tools)
          end
        end)
      end)

    assert code == 0, err

    assert_received {:body,
                     %{"tool" => "delete_entity", "arguments" => %{"id" => 9, "dry_run" => true}}}
  end

  test "a tty prints a juricode table and --json stays raw" do
    body =
      ~s({"data":{"jurisdictions":[{"id":1,"level":"place","name":"Vacaville","geoid":"0681554"}]}})

    {code, out, err} =
      invoke(
        ["juricode", "300 Hemlock St"],
        fn bypass ->
          Bypass.expect_once(bypass, fn conn ->
            Plug.Conn.resp(conn, 200, body)
          end)
        end,
        tty?: true
      )

    assert code == 0, err
    assert out =~ "level"
    assert out =~ "Vacaville"
    refute out =~ "geoid"
    refute out =~ "0681554"

    {code, out, err} =
      invoke(
        ["--json", "juricode", "300 Hemlock St"],
        fn bypass ->
          Bypass.expect_once(bypass, fn conn ->
            Plug.Conn.resp(conn, 200, body)
          end)
        end,
        tty?: true
      )

    assert code == 0, err
    assert out =~ "geoid"
    assert out =~ "0681554"
  end

  test "help does not call the network" do
    {code, out, err} = capture(["help"])
    assert code == 0
    assert out =~ "juricode"
    assert err == ""
  end

  defp invoke(args, setup, opts \\ []) do
    bypass = Bypass.open()
    setup.(bypass)

    capture(
      ["--host", "http://127.0.0.1:#{bypass.port}" | args],
      opts
    )
  end

  defp capture(args, opts \\ []) do
    home = Keyword.get(opts, :home) || fresh_home()

    JurisdictionalCli.capture(
      args,
      home: home,
      now: ~U[2026-11-09 12:00:00Z],
      env: Keyword.get(opts, :env, %{}),
      lines: Keyword.get(opts, :lines, []),
      tty?: Keyword.get(opts, :tty?, false),
      capture?: true,
      sleep: Keyword.get(opts, :sleep),
      open: Keyword.get(opts, :open),
      device_name: Keyword.get(opts, :device_name)
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

  defp write_creds(home, creds) do
    dir = Path.join(home, ".jurisdictional")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "credentials.json"), Jason.encode!(creds))
  end

  defp req_headers(conn) do
    conn.req_headers
    |> Enum.map(fn {key, value} -> {String.downcase(key), value} end)
    |> Map.new()
  end

  defp flush(tag, acc \\ []) do
    receive do
      {^tag, method, path} -> flush(tag, [{method, path} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
