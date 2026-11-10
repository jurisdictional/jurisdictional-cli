defmodule JurisdictionalCli do
  @moduledoc """
  Draft client for the Jurisdictional HTTP API.

  Public reads go to `/api/v1`.
  Tool calls go to `POST /api/mcp/execute`.
  The command prints the upstream body.
  """

  alias JurisdictionalCli.Client
  alias JurisdictionalCli.Present
  alias JurisdictionalCli.Secret
  alias JurisdictionalCli.Store

  @exit_ok 0
  @exit_response 1
  @exit_usage 2
  @exit_network 3
  @exit_auth 4

  # Registered public client for the browser sign-in (RFC 8628).
  @client_id "jurisdictional-cli"
  @device_grant "urn:ietf:params:oauth:grant-type:device_code"

  @usage """
  jurisdictional — client for the Jurisdictional HTTP API

  Usage:
    jurisdictional <command> [flags]
    jurisdictional --help | --version

  Public records:
    juricode ADDRESS               GET /api/v1/juricode
    jurisdictions list|get ID|autocomplete|at-point|scene ID
    agencies list|get ID
    services list|get ID           --jurisdiction ID, --agency ID, --service-type, --action, --q
    bodies list|positions
    meetings list|get ID
    people get ID
    nearby --lat N --lng N
    geo layers|jurisdiction ID

  This app, not the public record:
    activity                       search and contribution counts for the heatmap
    login                          sign in with a browser
    logout                         DELETE /api/v1/auth/token and drop stored credentials
    me [jurisdictions|officials|contributions|feed|notifications]
    devices list|add|remove ID
    sync jurisdictions|officials
    contributions quick [--photo PATH]
    gather submit
    tax import
    sourcing next|stats|results|generate
    images get ID|person ID|jurisdiction ID   (--image PATH attaches a file)
    tools                          GET /api/mcp/tools
    tool NAME                      POST /api/mcp/execute
    message
    api METHOD PATH                call /api/v1 (or an absolute /api path)
    well-known
    health

  Flags:
    --host URL       API origin (default https://jurisdictional.org, or JURISDICTIONAL_HOST)
    --token TOKEN    bearer token for this invocation (or JURISDICTIONAL_TOKEN)
    --json           print the upstream body
    --profile NAME   send Accept: application/json; profile="NAME"
    --save DIR       write the response body and an index entry into DIR
    --yes            skip the confirmation prompt on a destructive tool

  A flag uses hyphens. The wire parameter uses underscores.
  juricode works with no token. login writes ~/.jurisdictional/credentials.json
  and leaves ~/.jurisdictional/token untouched.
  login opens the browser and prints a short code.
  --paste redeems the refresh token the approval page shows once.
  """

  @version Mix.Project.config()[:version]

  # tty?: stdout is a terminal, so print a table instead of raw JSON.
  # stdin_tty?: someone can answer a [y/N] prompt.
  @spec main([String.t()]) :: no_return()
  def main(args) do
    args
    |> run(tty?: Secret.terminal?(:stdout), stdin_tty?: Secret.terminal?(:stdin))
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
      opts = Keyword.put(opts, :command, command_name(rest))

      case rest do
        [] ->
          write(opts, :stdout, @usage)
          @exit_ok

        [help | _] when help in ["help", "--help", "-h"] ->
          write(opts, :stdout, @usage)
          @exit_ok

        [version] when version in ["version", "--version", "-V"] ->
          write(opts, :stdout, "jurisdictional #{@version}\n")
          @exit_ok

        ["login" | cmd] ->
          login(opts, globals, cmd)

        ["logout" | cmd] ->
          logout(opts, globals, cmd)

        ["api" | cmd] ->
          api(opts, globals, cmd)

        ["tools" | cmd] ->
          tools(opts, globals, cmd)

        ["tool" | cmd] ->
          tool(opts, globals, cmd)

        ["juricode" | cmd] ->
          juricode(opts, globals, cmd)

        [cmd | cmd_args]
        when cmd in ~w(jurisdictions agencies services bodies meetings people nearby activity geo well-known health me devices sync contributions gather tax sourcing images message) ->
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

  @commands ~w(juricode jurisdictions agencies services bodies meetings people nearby geo
               activity login logout me devices sync contributions gather tax sourcing images
               tools tool message api well-known health)
  @subcommands ~w(list get autocomplete at-point scene positions layers jurisdiction person
                  quick submit import next stats results generate add remove officials
                  contributions feed notifications)

  # Only names from the lists above, so an argument such as an address never leaves as a command.
  defp command_name([cmd | rest]) when cmd in @commands do
    case rest do
      [sub | _] when sub in @subcommands and cmd not in ~w(tool api juricode) -> cmd <> " " <> sub
      _ -> cmd
    end
  end

  defp command_name(_rest), do: nil

  defp normalize_opts(opts) do
    home = opts[:home] || System.get_env("HOME") || System.user_home!()
    now = opts[:now] || DateTime.utc_now()

    opts
    |> Keyword.put_new(:stdout, "")
    |> Keyword.put(:home, home)
    |> Keyword.put(:now, now)
    |> Keyword.put_new(:tty?, false)
    |> Keyword.put_new(:stdin_tty?, false)
    |> Keyword.put_new(:lines, [])
    |> Keyword.put(:captured, opts[:capture?] == true)
  end

  defp split_globals(args, globals \\ empty_globals(), acc \\ [])

  defp split_globals([], globals, acc), do: {:ok, globals, Enum.reverse(acc)}

  defp split_globals([flag, value | rest], globals, acc)
       when flag in ["--host", "--token", "--profile", "--save"] do
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
       when flag in ["--host", "--token", "--profile", "--save"] do
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
    %{host: nil, token: nil, profile: nil, json: false, yes: false, save: nil}
  end

  defp put_global(globals, "--host", value), do: {:ok, %{globals | host: value}}
  defp put_global(globals, "--token", value), do: {:ok, %{globals | token: value}}
  defp put_global(globals, "--save", value), do: {:ok, %{globals | save: value}}

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
    if is_binary(globals.token) and globals.token != "" do
      write(opts, :stderr, """
      login does not take --token.
      --token is a bearer for one command.
      The approval page shows a refresh token. Run jurisdictional login --paste.
      """)

      @exit_usage
    else
      start_login(opts, globals, args)
    end
  end

  defp start_login(opts, globals, args) do
    with {:ok, parsed} <- parse_login(args) do
      cond do
        parsed.help ->
          write(opts, :stdout, login_help())
          @exit_ok

        parsed.positionals != [] ->
          write(opts, :stderr, "login takes no positional arguments\n")
          @exit_usage

        parsed.paste ->
          do_paste_login(opts, globals, parsed)

        true ->
          do_device_login(opts, globals, parsed)
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp login_help do
    """
    usage: jurisdictional login [--no-browser]
           jurisdictional login --paste

    Opens the browser and prints a short code.
    You approve at /device while signed in.
    The command checks back every few seconds and stores the access token and the refresh token.
    --paste redeems the refresh token the approval page shows once.
    That is for a terminal that cannot wait.
    Type the token at the prompt, where it is not shown, or pipe it on stdin.
    Whichever redeems the token first wins.
    This does not write ~/.jurisdictional/token.
    The device code and the tokens are not printed.
    """
  end

  defp parse_login(args, parsed \\ empty_login())

  defp parse_login([], parsed), do: {:ok, parsed}

  defp parse_login(["--" | rest], parsed) do
    {:ok, %{parsed | positionals: parsed.positionals ++ rest}}
  end

  defp parse_login([flag | rest], parsed) when flag in ["--help", "-h"] do
    parse_login(rest, %{parsed | help: true})
  end

  defp parse_login(["--no-browser" | _], %{no_browser: true}),
    do: {:error, "--no-browser given twice"}

  defp parse_login(["--no-browser" | rest], parsed) do
    parse_login(rest, %{parsed | no_browser: true})
  end

  defp parse_login(["--paste" | _], %{paste: true}), do: {:error, "--paste given twice"}

  defp parse_login(["--paste" | rest], parsed) do
    case rest do
      [value | _] when value != "--" ->
        if flag?(value) do
          parse_login(rest, %{parsed | paste: true})
        else
          {:error,
           "--paste takes no value. A token on the command line stays in shell history.
" <>
             "Type it at the prompt, or pipe it on stdin."}
        end

      _ ->
        parse_login(rest, %{parsed | paste: true})
    end
  end

  defp parse_login(["--" <> name | _], _parsed), do: {:error, "unknown flag --#{name}"}

  defp parse_login(["-" <> _ = flag | _], _parsed), do: {:error, "unknown flag #{flag}"}

  defp parse_login([arg | rest], parsed) do
    parse_login(rest, %{parsed | positionals: parsed.positionals ++ [arg]})
  end

  defp empty_login do
    %{
      positionals: [],
      help: false,
      paste: false,
      no_browser: false
    }
  end

  defp do_device_login(opts, globals, parsed) do
    name = device_name(opts)

    with_host(opts, globals, fn session ->
      case Client.post(
             session,
             "/api/v1/auth/device",
             %{
               "client_id" => @client_id,
               "device_name" => name
             }
           ) do
        {:ok, _session, 200, body, _headers} ->
          begin_device_wait(opts, globals, session, parsed, name, body)

        {:ok, _session, 404, _body, _} ->
          write(
            opts,
            :stderr,
            "This server does not offer browser sign-in yet. Pass --token, or set JURISDICTIONAL_TOKEN, on each command.\n"
          )

          @exit_response

        {:ok, _session, _status, body, _} ->
          write(opts, :stderr, device_error_text(body))
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

  # Prints the page and the user code, then polls.
  # The device code stays in memory and is never written to the terminal.
  defp begin_device_wait(opts, globals, session, parsed, name, body) do
    case Jason.decode(body) do
      {:ok,
       %{
         "device_code" => device_code,
         "user_code" => user_code,
         "verification_uri" => uri
       } = data}
      when is_binary(device_code) and device_code != "" and is_binary(user_code) and
             user_code != "" and is_binary(uri) and uri != "" ->
        write(opts, :stderr, "Sign in at #{uri}\nCode: #{user_code}\nDevice: #{name}\n\n")
        open_device_page(opts, parsed, data)
        write(opts, :stderr, "Waiting for approval.\n")

        device_code
        |> poll_device(opts, session, interval_of(data), expires_of(data), 0, 0)
        |> finish_device(opts, globals)

      _ ->
        write(opts, :stderr, "sign-in response had no code\n")
        @exit_response
    end
  end

  defp open_device_page(opts, parsed, data) do
    if parsed.no_browser do
      :ok
    else
      url = data["verification_uri_complete"] || data["verification_uri"]

      case open_browser(opts, url) do
        :ok ->
          :ok

        :error ->
          write(opts, :stderr, "Could not open a browser. Use the page and code above.\n")
      end
    end
  end

  defp poll_device(device_code, opts, session, interval, expires_in, waited, polls) do
    if waited >= expires_in or polls > expires_in do
      {:expired, nil}
    else
      case Client.post(
             session,
             "/api/v1/auth/token",
             %{
               "grant_type" => @device_grant,
               "device_code" => device_code,
               "client_id" => @client_id
             }
           ) do
        {:ok, _session, 200, body, _headers} ->
          {:approved, body}

        {:ok, _session, _status, body, _} ->
          error = device_error_code(body)

          case retry_interval(error, interval) do
            {:retry, interval} ->
              wait(opts, interval)
              waited = waited + max(interval, 1)
              poll_device(device_code, opts, session, interval, expires_in, waited, polls + 1)

            :stop ->
              device_failure(error, body)
          end

        {:network, reason} ->
          {:network, reason}

        {:error, code, message} ->
          {:client, code, message}
      end
    end
  end

  # RFC 8628 §3.5: keep polling while pending, and add 5 seconds on slow_down.
  defp retry_interval("authorization_pending", interval), do: {:retry, interval}
  defp retry_interval("slow_down", interval), do: {:retry, interval + 5}
  defp retry_interval(_error, _interval), do: :stop

  defp device_failure("access_denied", body), do: {:denied, body}
  defp device_failure("expired_token", body), do: {:expired, body}
  defp device_failure("invalid_grant", body), do: {:used, body}
  defp device_failure(_error, body), do: {:error, body}

  defp finish_device({:approved, body}, opts, globals) do
    opts
    |> store_login(nil, body)
    |> refuse_token_save(opts, globals)
  end

  defp finish_device({:denied, _body}, opts, _globals) do
    write(opts, :stderr, "The sign-in was denied.\n")
    @exit_response
  end

  defp finish_device({:expired, _body}, opts, _globals) do
    write(opts, :stderr, "The sign-in expired. Run jurisdictional login again.\n")
    @exit_response
  end

  defp finish_device({:used, _body}, opts, _globals) do
    write(opts, :stderr, "That sign-in was already used.\n")
    @exit_response
  end

  defp finish_device({:error, body}, opts, _globals) do
    write(opts, :stderr, device_error_text(body))
    @exit_response
  end

  defp finish_device({:network, reason}, opts, _globals) do
    write(opts, :stderr, "request failed: #{inspect(reason)}\n")
    @exit_network
  end

  defp finish_device({:client, code, message}, opts, _globals) do
    write(opts, :stderr, message)
    code
  end

  defp do_paste_login(opts, globals, _parsed) do
    case read_secret(opts, "paste the token: ") do
      :interrupted ->
        write(opts, :stderr, "cancelled\n")
        @exit_usage

      token when token in [nil, ""] ->
        write(opts, :stderr, "token is required\n")
        @exit_usage

      token ->
        redeem_pasted_token(opts, globals, token)
    end
  end

  defp redeem_pasted_token(opts, globals, token) do
    write(opts, :stderr, "signing in\n")

    with_host(opts, globals, fn session ->
      case Client.post(session, "/api/v1/auth/refresh", %{
             "refresh_token" => token
           }) do
        {:ok, _session, 200, body, _headers} ->
          opts
          |> store_login(nil, body)
          |> refuse_token_save(opts, globals)

        {:ok, _session, 401, body, _} ->
          write(opts, :stderr, "That token was not accepted.\n")
          write_raw(opts, body)
          @exit_auth

        {:ok, _session, _status, body, _} ->
          write(opts, :stderr, device_error_text(body))
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
            write(opts, :stdout, credential_notice(email))
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

  defp credential_notice(email) when is_binary(email) and email != "" do
    "stored credentials for #{email}\n"
  end

  defp credential_notice(_email), do: "stored credentials\n"

  defp device_name(opts) do
    case opts[:device_name] do
      name when is_binary(name) and name != "" -> String.slice(name, 0, 64)
      _ -> hostname()
    end
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    name = name |> List.to_string() |> String.trim() |> String.slice(0, 64)

    if name != "" and String.match?(name, ~r/\A[[:print:]]+\z/u),
      do: name,
      else: "Jurisdictional CLI"
  end

  defp interval_of(data), do: positive_int(data["interval"]) || 5

  defp expires_of(data), do: positive_int(data["expires_in"]) || 600

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(n) when is_float(n) and n > 0, do: trunc(n)
  defp positive_int(_n), do: nil

  defp wait(opts, seconds) do
    case opts[:sleep] do
      fun when is_function(fun, 1) -> fun.(seconds)
      _ -> Process.sleep(seconds * 1_000)
    end
  end

  defp open_browser(opts, url) when is_binary(url) and url != "" do
    cond do
      is_function(opts[:open], 1) ->
        case opts[:open].(url) do
          :error -> :error
          _ -> :ok
        end

      opts[:capture?] ->
        :ok

      true ->
        open_browser_os(url)
    end
  end

  defp open_browser(_opts, _url), do: :error

  defp open_browser_os(url) do
    {cmd, args} =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:unix, _} -> {"xdg-open", [url]}
        {:win32, _} -> {"cmd", ["/c", "start", "", url]}
      end

    case System.cmd(cmd, args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> :error
    end
  rescue
    _error -> :error
  end

  defp device_error_code(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => code}} when is_binary(code) -> code
      _ -> nil
    end
  end

  defp device_error_text(body) do
    case Jason.decode(body) do
      {:ok, %{"error_description" => text}} when is_binary(text) and text != "" ->
        text <> "\n"

      {:ok, %{"error" => %{"message" => text}}} when is_binary(text) and text != "" ->
        text <> "\n"

      _ ->
        "sign-in failed\n"
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
                %{globals | json: true},
                %{method: method, path: path, query: query}
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
              globals,
              %{method: "GET", path: "/api/mcp/tools", query: %{}}
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
    if opts[:stdin_tty?] do
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

    raw_finish(
      opts,
      Client.request(session, "POST", "/api/mcp/execute", %{}, body),
      globals,
      %{method: "POST", path: "/api/mcp/execute", query: %{}}
    )
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
        case route(cmd, parsed) do
          :skip ->
            case curated_path(cmd, parsed) do
              {:ok, path, flags} ->
                get_query(opts, globals, path, flags)

              {:error, message} ->
                write(opts, :stderr, message <> "\n")
                @exit_usage
            end

          {:ok, method, path, flags, body} ->
            send_route(opts, globals, method, path, flags, body)

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

  defp logout(opts, globals, args) do
    with {:ok, parsed} <- parse_cmd(args) do
      cond do
        parsed.help ->
          write(
            opts,
            :stdout,
            "usage: jurisdictional logout\n\nRevokes the refresh token and deletes credentials.json.\nThe long-lived token file is left in place.\n"
          )

          @exit_ok

        parsed.positionals != [] ->
          write(opts, :stderr, "logout takes no positional arguments\n")
          @exit_usage

        true ->
          body =
            case Client.stored_refresh_token(opts) do
              nil -> nil
              token -> Jason.encode!(%{"refresh_token" => token})
            end

          code = send_route(opts, globals, "DELETE", "/api/v1/auth/token", %{}, body)

          if code == @exit_ok do
            case Client.delete_credentials(opts) do
              :ok ->
                write(opts, :stderr, "removed stored credentials\n")

              {:error, reason} ->
                write(opts, :stderr, "removing credentials: #{inspect(reason)}\n")
            end
          end

          code
      end
    else
      {:error, message} ->
        write(opts, :stderr, message <> "\n")
        @exit_usage
    end
  end

  defp route(cmd, parsed) do
    case account_route(cmd, parsed) do
      :skip -> write_route(cmd, parsed)
      other -> other
    end
  end

  defp account_route("me", %{positionals: [], flags: flags}),
    do: {:ok, "GET", "/api/v1/me", flags, nil}

  defp account_route("me", %{positionals: ["jurisdictions"], flags: flags}) do
    {:ok, "GET", "/api/v1/me/jurisdictions", flags, nil}
  end

  defp account_route("me", %{positionals: ["officials"], flags: flags}) do
    {:ok, "GET", "/api/v1/me/officials", flags, nil}
  end

  defp account_route("me", %{positionals: ["contributions"], flags: flags}) do
    {:ok, "GET", "/api/v1/me/contributions", flags, nil}
  end

  defp account_route("me", %{positionals: ["feed"], flags: flags}) do
    {:ok, "GET", "/api/v1/me/feed", flags, nil}
  end

  defp account_route("me", %{positionals: ["notifications"], flags: flags}) do
    {:ok, "GET", "/api/v1/me/notification-preferences", flags, nil}
  end

  defp account_route("me", %{positionals: ["notifications", "set"], flags: flags}) do
    with {:ok, body} <- json_body(flags) do
      {:ok, "PUT", "/api/v1/me/notification-preferences", %{}, body}
    end
  end

  defp account_route("me", _parsed) do
    {:error,
     "usage: jurisdictional me [jurisdictions|officials|contributions|feed|notifications]"}
  end

  defp account_route("devices", %{positionals: ["list"], flags: flags}) do
    {:ok, "GET", "/api/v1/devices", flags, nil}
  end

  defp account_route("devices", %{positionals: ["add"], flags: flags}) do
    with {:ok, body} <- json_body(flags) do
      {:ok, "POST", "/api/v1/devices", %{}, body}
    end
  end

  defp account_route("devices", %{positionals: ["remove", id], flags: flags}) do
    {:ok, "DELETE", "/api/v1/devices/" <> encode_id(id), flags, nil}
  end

  defp account_route("devices", _parsed) do
    {:error, "usage: jurisdictional devices list|add|remove ID"}
  end

  defp account_route("sync", %{positionals: ["jurisdictions"], flags: flags}) do
    {:ok, "GET", "/api/v1/sync/jurisdictions", flags, nil}
  end

  defp account_route("sync", %{positionals: ["officials"], flags: flags}) do
    {:ok, "GET", "/api/v1/sync/officials", flags, nil}
  end

  defp account_route("sync", _parsed) do
    {:error, "usage: jurisdictional sync jurisdictions|officials"}
  end

  defp account_route(_cmd, _parsed), do: :skip

  defp write_route("contributions", %{positionals: ["quick"], flags: flags}) do
    with {:ok, body} <- upload_body(flags, "photo") do
      {:ok, "POST", "/api/v1/contributions/quick", %{}, body}
    end
  end

  defp write_route("contributions", _parsed) do
    {:error, "usage: jurisdictional contributions quick [--photo PATH]"}
  end

  defp write_route("gather", %{positionals: ["submit"], flags: flags}) do
    with {:ok, body} <- file_body(flags) do
      {:ok, "POST", "/api/v1/gather/submissions", %{}, body}
    end
  end

  defp write_route("gather", _parsed),
    do: {:error, "usage: jurisdictional gather submit --file page.json"}

  defp write_route("tax", %{positionals: ["import"], flags: flags}) do
    with {:ok, body} <- file_body(flags) do
      {:ok, "POST", "/api/v1/tax/import", %{}, body}
    end
  end

  defp write_route("tax", _parsed),
    do: {:error, "usage: jurisdictional tax import --file doc.json"}

  defp write_route("sourcing", %{positionals: ["next"], flags: flags}) do
    {:ok, "GET", "/api/v1/sourcing/next", flags, nil}
  end

  defp write_route("sourcing", %{positionals: ["stats"], flags: flags}) do
    {:ok, "GET", "/api/v1/sourcing/stats", flags, nil}
  end

  defp write_route("sourcing", %{positionals: ["results"], flags: flags}) do
    with {:ok, body} <- file_body(flags) do
      {:ok, "POST", "/api/v1/sourcing/results", %{}, body}
    end
  end

  defp write_route("sourcing", %{positionals: ["generate"], flags: flags}) do
    with {:ok, body} <- file_body(flags) do
      {:ok, "POST", "/api/v1/sourcing/generate", %{}, body}
    end
  end

  defp write_route("sourcing", _parsed) do
    {:error, "usage: jurisdictional sourcing next|stats|results|generate"}
  end

  defp write_route("images", %{positionals: ["get", id], flags: flags}) do
    {:ok, "GET", "/api/v1/images/" <> encode_id(id), flags, nil}
  end

  defp write_route("images", %{positionals: ["person", id], flags: flags}) do
    with {:ok, body} <- upload_body(flags, "image") do
      {:ok, "POST", "/api/v1/people/" <> encode_id(id) <> "/images", %{}, body}
    end
  end

  defp write_route("images", %{positionals: ["jurisdiction", id], flags: flags}) do
    with {:ok, body} <- upload_body(flags, "image") do
      {:ok, "POST", "/api/v1/jurisdictions/" <> encode_id(id) <> "/images", %{}, body}
    end
  end

  defp write_route("images", _parsed) do
    {:error,
     "usage: jurisdictional images get ID|person ID [--image PATH]|jurisdiction ID [--image PATH]"}
  end

  defp write_route("message", %{positionals: [], flags: flags}) do
    case Map.pop(flags, "file") do
      {nil, _} ->
        {:error, "message requires --file"}

      {path, extra} when extra == %{} ->
        case File.read(path) do
          {:ok, raw} -> {:ok, "POST", "/api/mcp/message", %{}, raw}
          {:error, reason} -> {:error, "#{path}: #{inspect(reason)}"}
        end

      {_path, _extra} ->
        {:error, "message takes only --file"}
    end
  end

  defp write_route("message", _parsed),
    do: {:error, "usage: jurisdictional message --file rpc.json"}

  defp write_route(_cmd, _parsed), do: :skip

  defp file_body(flags) do
    if Map.has_key?(flags, "file") do
      json_body(flags)
    else
      {:error, "this command requires --file"}
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

  defp curated_path("services", parsed) do
    with {:ok, flags} <- alias_flag(parsed.flags, "jurisdiction", "jurisdiction-id"),
         {:ok, flags} <- alias_flag(flags, "agency", "agency-id") do
      collection_path("/api/v1/services", %{parsed | flags: flags})
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
    send_route(opts, globals, "GET", path, flags, nil)
  end

  defp send_route(opts, globals, method, path, flags, body) do
    query = Map.new(flags, fn {key, value} -> {wire(key), value} end)

    with_session(opts, globals, fn session ->
      raw_finish(
        opts,
        Client.request(session, method, path, query, body),
        globals,
        %{method: method, path: path, query: query}
      )
    end)
  end

  defp json_body(flags) do
    with {:ok, object} <- object_from_file(flags) do
      flags = Map.delete(flags, "file")

      object =
        Enum.reduce(flags, object, fn {key, value}, acc ->
          Map.put(acc, wire(key), json_value(value))
        end)

      {:ok, Jason.encode!(object)}
    end
  end

  # With --image or --photo the body is multipart/form-data: the file part
  # plus every other flag as a text field. Without it, the body stays JSON.
  defp upload_body(flags, part) do
    case Map.pop(flags, part) do
      {nil, _flags} ->
        json_body(flags)

      {path, flags} ->
        with {:ok, path} <- upload_path(part, path),
             {:ok, object} <- object_from_file(flags) do
          fields =
            flags
            |> Map.delete("file")
            |> Enum.reduce(object, fn {key, value}, acc -> Map.put(acc, wire(key), value) end)
            |> put_upload_digest(part, path)
            |> Enum.sort()
            |> Enum.map(fn {key, value} -> {key, form_value(value)} end)

          {:ok, {:multipart, fields ++ [{part, File.stream!(path, 65_536)}]}}
        end
    end
  end

  defp upload_path(part, path) when is_binary(path) and path != "" do
    if File.regular?(path),
      do: {:ok, path},
      else: {:error, "--#{part}: no file at #{path}"}
  end

  defp upload_path(part, _path), do: {:error, "--#{part} needs a file path"}

  # The server checks image_sha256 against the bytes it receives.
  defp put_upload_digest(fields, "image", path) do
    Map.put_new_lazy(fields, "image_sha256", fn ->
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end)
  end

  defp put_upload_digest(fields, _part, _path), do: fields

  defp form_value(value) when is_binary(value), do: value
  defp form_value(value), do: Jason.encode!(value)

  defp json_value("true"), do: true
  defp json_value("false"), do: false
  defp json_value("0"), do: 0

  defp json_value(<<c, _rest::binary>> = value) when c in ?1..?9 do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> value
    end
  end

  defp json_value(value), do: value

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

  defp raw_finish(opts, {:ok, _session, status, body, headers}, globals, request) do
    raw_finish(opts, {:ok, status, body, headers}, globals, request)
  end

  defp raw_finish(opts, {:error, code, message}, _globals, _request) do
    write(opts, :stderr, message)
    code
  end

  defp raw_finish(opts, result, globals, request) do
    case result do
      {:network, reason} ->
        write(opts, :stderr, "request failed: #{inspect(reason)}\n")
        @exit_network

      {:ok, status, body, headers} ->
        note_rate_limit(opts, headers)
        write_body(opts, body, globals.json or not opts[:tty?])
        saved = save_response(opts, globals, request, {status, body, headers})

        cond do
          status == 401 ->
            write(opts, :stderr, "This route needs a token. Run jurisdictional login.\n")
            @exit_auth

          status in 200..299 and saved == :ok ->
            @exit_ok

          true ->
            @exit_response
        end
    end
  end

  defp refuse_token_save(code, opts, %{save: dir}) when is_binary(dir) do
    write(opts, :stderr, "not saving a response that contains a token\n")
    if code == @exit_ok, do: @exit_response, else: code
  end

  defp refuse_token_save(code, _opts, _globals), do: code

  defp save_response(_opts, %{save: nil}, _request, _response), do: :ok

  defp save_response(opts, %{save: dir} = globals, request, {status, body, headers}) do
    {:ok, host} = Client.resolve_host(opts, globals)
    url = Client.request_url(host, request.path, request.query)

    license =
      case Store.license_link(headers, url) do
        {:ok, target} ->
          target

        :none ->
          nil

        :ambiguous ->
          write(opts, :stderr, "the response names more than one license; not recording one\n")
          nil
      end

    saved =
      Store.put(dir, %{
        method: request.method,
        path: request.path,
        query: request.query,
        status: status,
        body: body,
        captured_at: DateTime.to_iso8601(opts[:now]),
        url: url,
        license: license
      })

    case saved do
      {:ok, file} ->
        write(opts, :stderr, "saved #{file}\n")
        :ok

      {:error, :token} ->
        write(opts, :stderr, "not saving a response that contains a token\n")
        :error

      {:error, reason} ->
        write(opts, :stderr, "saving response: #{inspect(reason)}\n")
        :error
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

    case Process.get(:jurisdictional_cli_lines, []) do
      [line | rest] ->
        if opts[:tty?], do: write(opts, :stderr, prompt)
        Process.put(:jurisdictional_cli_lines, rest)
        String.trim(line)

      [] ->
        if opts[:capture?] do
          nil
        else
          # stderr is unbuffered, so the prompt is on screen before the read waits.
          IO.write(:stderr, prompt)

          case IO.gets("") do
            :eof -> nil
            line -> String.trim(to_string(line))
          end
        end
    end
  end

  # Like read_line, but a terminal does not show what is typed.
  # Lines seeded by a test, and piped stdin, read as they do for read_line.
  defp read_secret(opts, prompt) do
    seed_lines(opts)

    case Process.get(:jurisdictional_cli_lines, []) do
      [_ | _] -> read_line(opts, prompt)
      [] -> if opts[:capture?], do: nil, else: Secret.read(prompt)
    end
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
