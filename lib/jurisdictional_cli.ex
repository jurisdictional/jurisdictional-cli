defmodule JurisdictionalCli do
  @moduledoc """
  Draft client for the Jurisdictional HTTP API.

  Public reads go to `/api/v1`.
  Tool calls go to `POST /api/mcp/execute`.
  The command prints the upstream body.
  """

  alias JurisdictionalCli.Client
  alias JurisdictionalCli.Present

  @exit_ok 0
  @exit_response 1
  @exit_usage 2
  @exit_network 3
  @exit_auth 4

  @usage """
  jurisdictional — client for the Jurisdictional HTTP API

  Usage:
    jurisdictional <command> [flags]

  Commands:
    login                          store a token from POST /api/v1/auth/token
    api METHOD PATH                call /api/v1 (or an absolute /api path)
    tools                          GET /api/mcp/tools
    tool NAME                      POST /api/mcp/execute
    juricode ADDRESS               GET /api/v1/juricode
    jurisdictions list|get ID|autocomplete|at-point|scene ID
    agencies list|get ID
    bodies list|positions
    meetings list|get ID
    people get ID
    nearby --lat N --lng N
    activity
    geo layers|jurisdiction ID
    well-known
    health

  Flags:
    --host URL       API origin (default https://jurisdictional.org, or JURISDICTIONAL_HOST)
    --token TOKEN    bearer token for this invocation (or JURISDICTIONAL_TOKEN)
    --json           print the upstream body
    --profile NAME   send Accept: application/json; profile="NAME"
    --yes            skip the confirmation prompt on a destructive tool

  A flag uses hyphens. The wire parameter uses underscores.
  juricode works with no token. login writes ~/.jurisdictional/credentials.json
  and leaves ~/.jurisdictional/token untouched.
  """

  def main(args) do
    args
    |> run()
    |> System.halt()
  end

  @doc false
  def capture(args, opts \\ []) do
    code = run(args, Keyword.put(opts, :capture?, true))
    {code, Process.get(:jurisdictional_cli_out, ""), Process.get(:jurisdictional_cli_err, "")}
  end

  def run(args, opts \\ []) do
    opts = normalize_opts(opts)
    reset_capture()

    with {:ok, globals, rest} <- split_globals(args) do
      case rest do
        [] ->
          write(opts, :stdout, @usage)
          @exit_ok

        ["help" | _] ->
          write(opts, :stdout, @usage)
          @exit_ok

        ["login" | cmd] ->
          login(opts, globals, cmd)

        ["api" | cmd] ->
          api(opts, globals, cmd)

        ["tools" | cmd] ->
          tools(opts, globals, cmd)

        ["tool" | cmd] ->
          tool(opts, globals, cmd)

        ["juricode" | cmd] ->
          juricode(opts, globals, cmd)

        [cmd | cmd_args]
        when cmd in ~w(jurisdictions agencies bodies meetings people nearby activity geo well-known health) ->
          curated(opts, globals, cmd, cmd_args)

        [cmd | _] ->
          write(opts, :stderr, "unknown command #{inspect(cmd)}\n#{@usage}")
          @exit_usage
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp normalize_opts(opts) do
    home = opts[:home] || System.get_env("HOME") || System.user_home!()
    now = opts[:now] || DateTime.utc_now()

    opts
    |> Keyword.put_new(:stdout, "")
    |> Keyword.put(:home, home)
    |> Keyword.put(:now, now)
    |> Keyword.put_new(:tty?, false)
    |> Keyword.put_new(:lines, [])
    |> Keyword.put(:captured, opts[:capture?] == true)
  end

  defp split_globals(args, globals \\ empty_globals(), acc \\ [])

  defp split_globals([], globals, acc), do: {:ok, globals, Enum.reverse(acc)}

  defp split_globals([flag, value | rest], globals, acc)
       when flag in ["--host", "--token", "--profile"] do
    if flag?(value) do
      {:error, "#{flag} needs a value"}
    else
      case put_global(globals, flag, value) do
        {:ok, globals} -> split_globals(rest, globals, acc)
        {:error, _} = error -> error
      end
    end
  end

  defp split_globals([flag | _], _globals, _acc)
       when flag in ["--host", "--token", "--profile"] do
    {:error, "#{flag} needs a value"}
  end

  defp split_globals(["--json" | rest], globals, acc) do
    split_globals(rest, %{globals | json: true}, acc)
  end

  defp split_globals(["--yes" | rest], globals, acc) do
    split_globals(rest, %{globals | yes: true}, acc)
  end

  defp split_globals([arg | rest], globals, acc) do
    split_globals(rest, globals, [arg | acc])
  end

  defp empty_globals do
    %{host: nil, token: nil, profile: nil, json: false, yes: false}
  end

  defp put_global(globals, "--host", value), do: {:ok, %{globals | host: value}}
  defp put_global(globals, "--token", value), do: {:ok, %{globals | token: value}}

  defp put_global(globals, "--profile", value) do
    if String.contains?(value, ["\"", " ", "\t"]) do
      {:error, "--profile must not contain spaces or quotes"}
    else
      {:ok, %{globals | profile: value}}
    end
  end

  defp parse_cmd(args, parsed \\ %{positionals: [], flags: %{}, help: false})

  defp parse_cmd([], parsed), do: {:ok, parsed}

  defp parse_cmd(["--" | rest], parsed) do
    {:ok, %{parsed | positionals: parsed.positionals ++ rest}}
  end

  defp parse_cmd([flag | rest], parsed) when flag in ["--help", "-h"] do
    parse_cmd(rest, %{parsed | help: true})
  end

  defp parse_cmd(["--" <> name | rest], parsed) do
    case rest do
      [value | rest] ->
        if flag?(value) do
          {:error, "--#{name} needs a value"}
        else
          if Map.has_key?(parsed.flags, name) do
            {:error, "--#{name} given twice"}
          else
            parse_cmd(rest, put_in(parsed.flags[name], value))
          end
        end

      [] ->
        {:error, "--#{name} needs a value"}
    end
  end

  defp parse_cmd(["-" <> _ = flag | _], _parsed), do: {:error, "unknown flag #{flag}"}

  defp parse_cmd([arg | rest], parsed) do
    parse_cmd(rest, %{parsed | positionals: parsed.positionals ++ [arg]})
  end

  defp flag?("--"), do: true
  defp flag?("--" <> _rest), do: true
  defp flag?("-" <> <<c, _::binary>>) when c in ?0..?9 or c == ?., do: false
  defp flag?("-" <> _rest), do: true
  defp flag?(_arg), do: false

  defp wire(flag), do: String.replace(flag, "-", "_")

  defp login(opts, globals, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      cond do
        parsed.help ->
          write(opts, :stdout, """
          usage: jurisdictional login [--email ADDRESS]

          Asks for your password and stores the token from POST /api/v1/auth/token.
          The server's access token expires; the refresh token is stored beside it.
          This does not write ~/.jurisdictional/token.
          """)

          @exit_ok

        parsed.positionals != [] ->
          write(opts, :stderr, "login takes no positional arguments\n")
          @exit_usage

        true ->
          do_login(opts, globals, parsed)
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp do_login(opts, globals, parsed) do
    email = parsed.flags["email"] || read_line(opts, "email: ")

    if email in [nil, ""] do
      write(opts, :stderr, "email is required\n")
      @exit_usage
    else
      # The draft reads the password with echo. A later pass can hide it on a TTY.
      password = read_line(opts, "password: ")

      if password in [nil, ""] do
        write(opts, :stderr, "password is required\n")
        @exit_usage
      else
        with_host(opts, globals, fn session ->
          case Client.post(
                 session,
                 "/api/v1/auth/token",
                 %{
                   "email" => email,
                   "password" => password,
                   "device_id" => "jurisdictional-cli"
                 }
               ) do
            {:ok, _session, 200, body, _headers} ->
              store_login(opts, email, body)

            {:ok, _session, 401, body, _} ->
              write_raw(opts, body)
              @exit_auth

            {:ok, _session, _status, body, _} ->
              write_raw(opts, body)
              @exit_response

            {:network, reason} ->
              write(opts, :stderr, "request failed: #{inspect(reason)}\n")
              @exit_network

            {:error, code, message} ->
              write(opts, :stderr, message)
              code
          end
        end)
      end
    end
  end

  defp store_login(opts, email, body) do
    case Jason.decode(body) do
      {:ok, %{"access_token" => token} = parsed} when is_binary(token) and token != "" ->
        email = get_in(parsed, ["user", "email"]) || email
        expires_in = parsed["expires_in"] || 0

        creds = %{
          "access_token" => token,
          "refresh_token" => parsed["refresh_token"],
          "email" => email
        }

        creds =
          if expires_in > 0 do
            Map.put(
              creds,
              "expires_at",
              DateTime.add(opts[:now], expires_in, :second) |> DateTime.to_iso8601()
            )
          else
            creds
          end

        case Client.write_credentials(opts, creds) do
          :ok ->
            write(opts, :stderr, "stored credentials for #{email}\n")
            @exit_ok

          {:error, reason} ->
            write(opts, :stderr, "storing credentials: #{inspect(reason)}\n")
            @exit_usage
        end

      _ ->
        write(opts, :stderr, "login response had no access_token\n")
        @exit_response
    end
  end

  defp api(opts, globals, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      cond do
        parsed.help ->
          write(opts, :stdout, """
          usage: jurisdictional api METHOD PATH [--param value] [--file body.json]

          PATH starting with /api is used as-is. Any other absolute path is prefixed with /api/v1.
          The response body is printed unchanged.
          """)

          @exit_ok

        length(parsed.positionals) != 2 ->
          write(opts, :stderr, "usage: jurisdictional api METHOD PATH\n")
          @exit_usage

        true ->
          [method, path] = parsed.positionals

          with {:ok, path} <- api_path(path),
               {:ok, method} <- api_method(method),
               {:ok, query, body} <- api_payload(method, parsed.flags) do
            with_session(opts, globals, fn session ->
              raw_finish(
                opts,
                Client.request(session, method, path, query, body),
                true
              )
            end)
          else
            {:error, message} ->
              write(opts, :stderr, message <> "\n")
              @exit_usage
          end
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp api_path("/" <> _ = path) do
    cond do
      String.starts_with?(path, "/api/") or path == "/api" ->
        {:ok, path}

      origin_path?(path) ->
        {:ok, path}

      true ->
        {:ok, "/api/v1" <> path}
    end
  end

  defp api_path(_), do: {:error, "path must start with /"}

  defp origin_path?(path) do
    String.starts_with?(path, "/.well-known/") or String.starts_with?(path, "/geo/") or
      String.starts_with?(path, "/health/") or path in ["/health", "/healthz"]
  end

  defp api_method(method) do
    method = String.upcase(method)

    if method in ~w(GET POST PUT PATCH DELETE) do
      {:ok, method}
    else
      {:error, "unsupported method #{method}"}
    end
  end

  defp api_payload(method, flags) do
    with {:ok, object} <- object_from_file(flags) do
      flags = Map.delete(flags, "file")

      object =
        Enum.reduce(flags, object, fn {key, value}, acc ->
          Map.put(acc, wire(key), value)
        end)

      if method in ["GET", "DELETE"] do
        {:ok, object, nil}
      else
        {:ok, %{}, Jason.encode!(object)}
      end
    end
  end

  defp tools(opts, globals, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      cond do
        parsed.help ->
          write(opts, :stdout, "usage: jurisdictional tools\n\nGET /api/mcp/tools\n")
          @exit_ok

        parsed.positionals != [] or parsed.flags != %{} ->
          write(opts, :stderr, "tools takes no arguments\n")
          @exit_usage

        true ->
          with_session(opts, globals, fn session ->
            raw_finish(
              opts,
              Client.request(session, "GET", "/api/mcp/tools", %{}, nil),
              globals.json
            )
          end)
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp tool(opts, globals, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      case parsed.positionals do
        [name] ->
          with_session(opts, globals, fn session ->
            case load_tools(opts, session) do
              {:ok, session, schema} ->
                dispatch_tool(opts, globals, session, name, parsed, schema)

              {:error, code} ->
                code
            end
          end)

        _ ->
          write(opts, :stderr, "usage: jurisdictional tool NAME [--param value]\n")
          @exit_usage
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp dispatch_tool(opts, globals, session, name, parsed, schema) do
    if parsed.help do
      case Map.fetch(schema, name) do
        {:ok, tool} ->
          write(opts, :stdout, describe_tool(tool))
          @exit_ok

        :error ->
          write(opts, :stderr, "no tool named #{name} in GET /api/mcp/tools\n")
          @exit_usage
      end
    else
      with {:ok, arguments} <- tool_arguments(name, parsed.flags, schema) do
        if destructive?(name, schema) and not truthy?(parsed.flags["dry-run"]) and
             not globals.yes do
          confirm_or_send(opts, globals, session, name, arguments)
        else
          send_tool(opts, globals, session, name, arguments)
        end
      else
        {:error, message} ->
          write(opts, :stderr, message <> "\n")
          @exit_usage
      end
    end
  end

  defp confirm_or_send(opts, name) do
    if opts[:tty?] do
      answer = read_line(opts, "call #{name}? [y/N] ")

      if answer in ["y", "Y", "yes"] do
        :send
      else
        write(opts, :stderr, "not sent\n")
        @exit_usage
      end
    else
      write(opts, :stderr, "refusing to call #{name} without --yes\n")
      @exit_usage
    end
  end

  defp confirm_or_send(opts, globals, session, name, arguments) do
    case confirm_or_send(opts, name) do
      :send -> send_tool(opts, globals, session, name, arguments)
      code -> code
    end
  end

  defp send_tool(opts, globals, session, name, arguments) do
    body = Jason.encode!(%{"tool" => name, "arguments" => arguments})
    raw_finish(opts, Client.request(session, "POST", "/api/mcp/execute", %{}, body), globals.json)
  end

  defp juricode(opts, globals, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      cond do
        parsed.help ->
          write(
            opts,
            :stdout,
            "usage: jurisdictional juricode ADDRESS [--include LIST]\n\nGET /api/v1/juricode\n"
          )

          @exit_ok

        length(parsed.positionals) > 1 ->
          write(opts, :stderr, "usage: jurisdictional juricode ADDRESS\n")
          @exit_usage

        true ->
          flags =
            case parsed.positionals do
              [address] ->
                if Map.has_key?(parsed.flags, "address") do
                  :twice
                else
                  Map.put(parsed.flags, "address", address)
                end

              [] ->
                parsed.flags
            end

          cond do
            flags == :twice ->
              write(opts, :stderr, "pass the address once\n")
              @exit_usage

            flags["address"] in [nil, ""] and flags["lat"] in [nil, ""] ->
              write(opts, :stderr, "usage: jurisdictional juricode ADDRESS\n")
              @exit_usage

            true ->
              get_query(opts, globals, "/api/v1/juricode", flags)
          end
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp curated(opts, globals, cmd, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      if parsed.help do
        write(
          opts,
          :stdout,
          "usage: jurisdictional #{cmd} ...\n\nSee `jurisdictional` for the verbs. Flags become the documented query parameters.\n"
        )

        @exit_ok
      else
        case curated_path(cmd, parsed) do
          {:ok, path, flags} ->
            get_query(opts, globals, path, flags)

          {:error, message} ->
            write(opts, :stderr, message <> "\n")
            @exit_usage
        end
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp curated_path("nearby", parsed) do
    cond do
      parsed.positionals != [] ->
        {:error, "usage: jurisdictional nearby --lat N --lng N"}

      parsed.flags["lat"] in [nil, ""] or parsed.flags["lng"] in [nil, ""] ->
        {:error, "nearby requires --lat and --lng"}

      true ->
        {:ok, "/api/v1/nearby", parsed.flags}
    end
  end

  defp curated_path("jurisdictions", %{positionals: ["autocomplete"], flags: flags}) do
    if blank?(flags["q"]) and blank?(flags["query"]) do
      {:error, "jurisdictions autocomplete requires --q"}
    else
      {:ok, "/api/v1/jurisdictions/autocomplete", flags}
    end
  end

  defp curated_path("jurisdictions", %{positionals: ["at-point"], flags: flags}) do
    if blank?(flags["lat"]) or blank?(flags["lng"]) do
      {:error, "jurisdictions at-point requires --lat and --lng"}
    else
      {:ok, "/api/v1/jurisdictions/at_point", flags}
    end
  end

  defp curated_path("jurisdictions", %{positionals: ["scene", id], flags: flags}) do
    {:ok, "/api/v1/jurisdictions/" <> encode_id(id) <> "/scene", flags}
  end

  defp curated_path("jurisdictions", parsed),
    do: collection_path("/api/v1/jurisdictions", parsed)

  defp curated_path("agencies", parsed) do
    with {:ok, flags} <- alias_flag(parsed.flags, "jurisdiction", "jurisdiction-id") do
      collection_path("/api/v1/agencies", %{parsed | flags: flags})
    end
  end

  defp curated_path("people", %{positionals: ["get", id], flags: flags}) do
    {:ok, "/api/v1/people/" <> URI.encode(id, &URI.char_unreserved?/1), flags}
  end

  defp curated_path("people", _parsed), do: {:error, "usage: jurisdictional people get ID"}

  defp curated_path("bodies", %{positionals: ["positions"], flags: flags}) do
    with {:ok, id, flags} <- one_id(flags, "body", "body-id") do
      {:ok, "/api/v1/bodies/" <> encode_id(id) <> "/positions", flags}
    end
  end

  defp curated_path("bodies", %{positionals: ["list"], flags: flags}) do
    with {:ok, id, flags} <- one_id(flags, "jurisdiction", "jurisdiction-id") do
      {:ok, "/api/v1/jurisdictions/" <> URI.encode(id, &URI.char_unreserved?/1) <> "/bodies",
       flags}
    end
  end

  defp curated_path("bodies", _parsed) do
    {:error, "usage: jurisdictional bodies list --jurisdiction ID"}
  end

  defp curated_path("meetings", %{positionals: ["get", id], flags: flags}) do
    {:ok, "/api/v1/meetings/" <> encode_id(id), flags}
  end

  defp curated_path("meetings", %{positionals: ["list"], flags: flags}) do
    with {:ok, kind, id, flags} <- meeting_scope(flags) do
      {:ok, "/api/v1/#{kind}/" <> URI.encode(id, &URI.char_unreserved?/1) <> "/meetings", flags}
    end
  end

  defp curated_path("meetings", _parsed) do
    {:error, "usage: jurisdictional meetings list --body ID"}
  end

  defp curated_path("activity", %{positionals: [], flags: flags}) do
    {:ok, "/api/v1/activity", flags}
  end

  defp curated_path("activity", _parsed), do: {:error, "usage: jurisdictional activity"}

  defp curated_path("geo", %{positionals: ["layers"], flags: flags}) do
    {:ok, "/geo/base_layers.json", flags}
  end

  defp curated_path("geo", %{positionals: ["jurisdiction", id], flags: flags}) do
    {:ok, "/geo/jurisdictions/" <> encode_id(id) <> "/simplified.json", flags}
  end

  defp curated_path("geo", _parsed) do
    {:error, "usage: jurisdictional geo layers|jurisdiction ID"}
  end

  defp curated_path("well-known", %{positionals: [], flags: flags}) when flags == %{} do
    {:ok, "/.well-known/oauth-authorization-server", flags}
  end

  defp curated_path("well-known", _parsed), do: {:error, "usage: jurisdictional well-known"}

  defp curated_path("health", %{positionals: [], flags: flags}) when flags == %{} do
    {:ok, "/healthz", flags}
  end

  defp curated_path("health", _parsed), do: {:error, "usage: jurisdictional health"}

  defp encode_id(id), do: URI.encode(id, &URI.char_unreserved?/1)

  defp blank?(value), do: value in [nil, ""]

  defp collection_path(base, %{positionals: ["list"], flags: flags}), do: {:ok, base, flags}

  defp collection_path(base, %{positionals: ["get", id], flags: flags}) do
    {:ok, base <> "/" <> URI.encode(id, &URI.char_unreserved?/1), flags}
  end

  defp collection_path(base, _parsed) do
    name = String.trim_leading(base, "/api/v1/")
    {:error, "usage: jurisdictional #{name} list|get ID"}
  end

  defp alias_flag(flags, from, to) do
    case Map.pop(flags, from) do
      {nil, flags} ->
        {:ok, flags}

      {value, flags} ->
        if Map.has_key?(flags, to) do
          {:error, "pass only one of --#{from} and --#{to}"}
        else
          {:ok, Map.put(flags, to, value)}
        end
    end
  end

  defp one_id(flags, short, long) do
    with {:ok, flags} <- alias_flag(flags, short, long) do
      case Map.pop(flags, long) do
        {nil, _} -> {:error, "--#{short} is required"}
        {"", _} -> {:error, "--#{short} is required"}
        {id, flags} -> {:ok, id, flags}
      end
    end
  end

  defp meeting_scope(flags) do
    scopes = [{"body", "bodies"}, {"jurisdiction", "jurisdictions"}, {"agency", "agencies"}]

    found =
      Enum.flat_map(scopes, fn {flag, kind} ->
        case Map.get(flags, flag) do
          nil -> []
          id -> [{kind, id, flag}]
        end
      end)

    case found do
      [{kind, id, flag}] ->
        {:ok, kind, id, Map.delete(flags, flag)}

      [] ->
        {:error, "meetings list requires --body, --jurisdiction, or --agency"}

      _ ->
        {:error, "pass only one of --body, --jurisdiction, --agency"}
    end
  end

  defp get_query(opts, globals, path, flags) do
    query =
      Map.new(flags, fn {key, value} ->
        {wire(key), value}
      end)

    with_session(opts, globals, fn session ->
      raw_finish(opts, Client.request(session, "GET", path, query, nil), globals.json)
    end)
  end

  defp with_session(opts, globals, fun), do: with_open(opts, &Client.open_session/2, globals, fun)
  defp with_host(opts, globals, fun), do: with_open(opts, &Client.open_host/2, globals, fun)

  defp with_open(opts, opener, globals, fun) do
    case opener.(opts, globals) do
      {:ok, session} ->
        fun.(session)

      {:error, code, message} ->
        write(opts, :stderr, message)
        code
    end
  end

  defp load_tools(opts, session) do
    case Client.request(session, "GET", "/api/mcp/tools", %{}, nil) do
      {:ok, session, 200, body, _} ->
        case Jason.decode(body) do
          {:ok, %{"tools" => tools}} when is_list(tools) ->
            {:ok, session, Map.new(tools, fn tool -> {tool["name"], tool} end)}

          _ ->
            write(opts, :stderr, "tools response was not a tool list\n")
            {:error, @exit_response}
        end

      {:ok, _session, 401, body, _} ->
        write_raw(opts, body)
        write(opts, :stderr, "This route needs a token. Run jurisdictional login.\n")
        {:error, @exit_auth}

      {:ok, _session, _status, body, _} ->
        write_raw(opts, body)
        {:error, @exit_response}

      {:network, reason} ->
        write(opts, :stderr, "request failed: #{inspect(reason)}\n")
        {:error, @exit_network}

      {:error, code, message} ->
        write(opts, :stderr, message)
        {:error, code}
    end
  end

  defp tool_arguments(name, flags, schema) do
    with {:ok, object} <- object_from_file(flags) do
      flags = Map.delete(flags, "file")
      props = schema_props(schema[name])

      Enum.reduce_while(flags, {:ok, object}, fn {key, value}, {:ok, acc} ->
        wire_key = wire(key)

        case coerce(wire_key, value, props[wire_key]) do
          {:ok, coerced} -> {:cont, {:ok, Map.put(acc, wire_key, coerced)}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defp schema_props(nil), do: %{}

  defp schema_props(tool) do
    get_in(tool, ["inputSchema", "properties"]) || %{}
  end

  defp coerce(key, value, %{"type" => "integer"}) do
    case Integer.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "--#{String.replace(key, "_", "-")} must be an integer"}
    end
  end

  defp coerce(key, value, %{"type" => "number"}) do
    case Float.parse(value) do
      {n, ""} -> {:ok, n}
      _ -> {:error, "--#{String.replace(key, "_", "-")} must be a number"}
    end
  end

  defp coerce(key, value, %{"type" => "boolean"}) do
    case parse_bool(value) do
      {:ok, bool} -> {:ok, bool}
      :error -> {:error, "--#{String.replace(key, "_", "-")} must be true or false"}
    end
  end

  defp coerce(key, value, %{"type" => type}) when type in ["object", "array"] do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:error, "--#{String.replace(key, "_", "-")} must be JSON"}
    end
  end

  defp coerce(_key, value, _prop), do: {:ok, value}

  defp destructive?(name, _schema) when name in ["delete_entity", "merge_entities"], do: true

  defp destructive?(name, schema) do
    get_in(schema, [name, "annotations", "destructiveHint"]) == true
  end

  defp describe_tool(tool) do
    schema = tool["inputSchema"]
    pretty = if schema, do: "\n" <> Jason.encode!(schema, pretty: true) <> "\n", else: ""
    "#{tool["name"]}\n\n#{String.trim(tool["description"] || "")}\n#{pretty}"
  end

  defp object_from_file(flags) do
    case Map.fetch(flags, "file") do
      :error ->
        {:ok, %{}}

      {:ok, path} ->
        with {:ok, raw} <- File.read(path),
             {:ok, object} when is_map(object) <- Jason.decode(raw) do
          {:ok, object}
        else
          {:ok, _} -> {:error, "#{path}: expected a JSON object"}
          {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
        end
    end
  end

  defp truthy?(value) do
    match?({:ok, true}, parse_bool(value || ""))
  end

  defp parse_bool(value) do
    case String.downcase(value) do
      v when v in ["true", "1", "yes"] -> {:ok, true}
      v when v in ["false", "0", "no"] -> {:ok, false}
      _ -> :error
    end
  end

  defp raw_finish(opts, {:ok, _session, status, body, headers}, force_raw) do
    raw_finish(opts, {:ok, status, body, headers}, force_raw)
  end

  defp raw_finish(opts, {:error, code, message}, _force_raw) do
    write(opts, :stderr, message)
    code
  end

  defp raw_finish(opts, result, force_raw) do
    case result do
      {:network, reason} ->
        write(opts, :stderr, "request failed: #{inspect(reason)}\n")
        @exit_network

      {:ok, status, body, headers} ->
        note_rate_limit(opts, headers)
        write_body(opts, body, force_raw or not opts[:tty?])

        cond do
          status == 401 ->
            write(opts, :stderr, "This route needs a token. Run jurisdictional login.\n")
            @exit_auth

          status in 200..299 ->
            @exit_ok

          true ->
            @exit_response
        end
    end
  end

  defp write_body(opts, body, true), do: write_raw(opts, body)

  defp write_body(opts, body, false) do
    case Present.table(body) do
      {:ok, table} -> write(opts, :stdout, table)
      :error -> write(opts, :stdout, pretty_or_raw(body))
    end
  end

  defp pretty_or_raw(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> Jason.encode!(decoded, pretty: true) <> "\n"
      _ -> ensure_newline(body)
    end
  end

  defp write_raw(opts, body), do: write(opts, :stdout, ensure_newline(body))

  defp ensure_newline(""), do: "\n"
  defp ensure_newline(body), do: if(String.ends_with?(body, "\n"), do: body, else: body <> "\n")

  defp note_rate_limit(opts, headers) do
    limit = header(headers, "x-ratelimit-limit")
    remaining = header(headers, "x-ratelimit-remaining")

    with true <- is_binary(limit) and limit != "" and limit != "unlimited",
         true <- is_binary(remaining) and remaining != "" and remaining != "unlimited",
         {lim, ""} <- Integer.parse(limit),
         {rem, ""} <- Integer.parse(remaining),
         true <- lim > 0 and rem * 10 < lim do
      write(opts, :stderr, "rate limit: #{rem} of #{lim} remaining\n")
    else
      _ -> :ok
    end
  end

  defp header(headers, name) do
    headers
    |> Enum.find(fn {key, _} -> String.downcase(key) == name end)
    |> case do
      {_, value} -> value
      nil -> nil
    end
  end

  defp read_line(opts, prompt) do
    seed_lines(opts)

    if opts[:tty?] do
      write(opts, :stderr, prompt)
    end

    pop_line(opts)
  end

  defp seed_lines(opts) do
    case Process.get(:jurisdictional_cli_seeded) do
      true ->
        :ok

      _ ->
        Process.put(:jurisdictional_cli_lines, opts[:lines] || [])
        Process.put(:jurisdictional_cli_seeded, true)
    end
  end

  defp pop_line(opts) do
    case Process.get(:jurisdictional_cli_lines, []) do
      [line | rest] ->
        Process.put(:jurisdictional_cli_lines, rest)
        String.trim(line)

      [] ->
        if opts[:capture?] do
          nil
        else
          case IO.gets("") do
            :eof -> nil
            line -> String.trim(line)
          end
        end
    end
  end

  defp reset_capture do
    Process.delete(:jurisdictional_cli_out)
    Process.delete(:jurisdictional_cli_err)
    Process.delete(:jurisdictional_cli_lines)
    Process.delete(:jurisdictional_cli_seeded)
  end

  defp write(opts, device, text) do
    cond do
      opts[:capture?] ->
        key = if(device == :stdout, do: :jurisdictional_cli_out, else: :jurisdictional_cli_err)
        Process.put(key, (Process.get(key, "") || "") <> text)

      device == :stdout ->
        IO.write(text)

      true ->
        IO.write(:stderr, text)
    end

    :ok
  end
end
