defmodule JurisdictionalCli.Client do
  @moduledoc false

  @user_agent "jurisdictional-cli/0.1.0"

  def open_session(opts, globals), do: open(opts, globals, true)
  def open_host(opts, globals), do: open(opts, globals, false)

  def post(session, path, payload) when is_map(payload) do
    request(session, "POST", path, %{}, Jason.encode!(payload))
  end

  def request(session, method, path, query, body) do
    do_request(session, method, path, query, body, true)
  end

  def stored_refresh_token(opts) do
    case read_credentials(opts) do
      {:ok, %{"refresh_token" => token}} when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  def delete_credentials(opts) do
    path = Path.join(config_dir(opts), "credentials.json")

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Writes `~/.jurisdictional/credentials.json` at mode 600.
  Does not write `~/.jurisdictional/token`.
  """
  def write_credentials(opts, creds) when is_map(creds) do
    dir = config_dir(opts)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700) do
      path = Path.join(dir, "credentials.json")
      tmp = path <> ".tmp"
      json = credential_json(creds)

      with :ok <- File.write(tmp, json),
           :ok <- File.chmod(tmp, 0o600),
           :ok <- File.rename(tmp, path),
           :ok <- File.chmod(path, 0o600) do
        :ok
      end
    end
  end

  defp open(opts, globals, load?) do
    with {:ok, host} <- host(opts, globals) do
      session = %{
        host: host,
        token: nil,
        refresh: nil,
        from_file: false,
        opts: opts,
        globals: globals
      }

      if load?, do: load_token(session), else: {:ok, session}
    end
  end

  defp host(opts, globals) do
    raw = chosen_host(opts, globals)
    host = String.trim_trailing(raw, "/")

    case URI.parse(host) do
      %URI{scheme: scheme, host: name}
      when scheme in ["http", "https"] and is_binary(name) and name != "" ->
        {:ok, host}

      _ ->
        {:error, 2, "bad host #{inspect(host)}\n"}
    end
  end

  defp chosen_host(opts, globals) do
    cond do
      is_binary(globals.host) and globals.host != "" ->
        globals.host

      true ->
        case env(opts, "JURISDICTIONAL_HOST") do
          host when is_binary(host) and host != "" -> host
          _ -> default_host()
        end
    end
  end

  defp default_host, do: "https://jurisdictional.org"

  defp load_token(session) do
    flag = session.globals.token
    env_token = env(session.opts, "JURISDICTIONAL_TOKEN")

    cond do
      is_binary(flag) and flag != "" ->
        {:ok, %{session | token: flag}}

      is_binary(env_token) and env_token != "" ->
        {:ok, %{session | token: env_token}}

      true ->
        load_stored(session)
    end
  end

  defp load_stored(session) do
    case read_credentials(session.opts) do
      {:error, reason} ->
        {:error, 2, "reading credentials: #{inspect(reason)}\n"}

      {:ok, creds} ->
        apply_credentials(session, creds)
    end
  end

  defp apply_credentials(session, nil), do: read_token(session)

  defp apply_credentials(session, creds) do
    now = session.opts[:now] || DateTime.utc_now()
    access = creds["access_token"]
    refresh = creds["refresh_token"]

    cond do
      is_binary(access) and access != "" and not expired?(creds, now) ->
        {:ok, %{session | token: access, refresh: refresh, from_file: true}}

      is_binary(refresh) and refresh != "" ->
        session = %{session | token: nil, refresh: refresh, from_file: true}

        case refresh_token(session) do
          {:ok, session} ->
            {:ok, session}

          {:network, reason} ->
            {:error, 3, "request failed: #{inspect(reason)}\n"}

          {:error, _code, _message} = error ->
            error

          :rejected ->
            read_token(%{session | token: nil, refresh: nil, from_file: false})
        end

      true ->
        read_token(session)
    end
  end

  # A rejected refresh falls through to the long-lived token file.
  # A network failure does not. The token file is never written.
  defp read_token(session) do
    case read_token_file(session.opts) do
      {:ok, ""} ->
        {:ok, %{session | token: nil, from_file: false}}

      {:ok, token} ->
        {:ok, %{session | token: token, refresh: nil, from_file: false}}

      {:error, reason} ->
        {:error, 2, "reading token: #{inspect(reason)}\n"}
    end
  end

  defp expired?(creds, now) do
    case creds["expires_at"] do
      nil ->
        false

      "" ->
        false

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, expires, _offset} -> DateTime.compare(expires, now) != :gt
          _ -> true
        end

      _ ->
        true
    end
  end

  defp do_request(session, method, path, query, body, allow_refresh?) do
    case round_trip(session, method, path, query, body) do
      {:ok, 401, raw, headers}
      when allow_refresh? and session.from_file and is_binary(session.refresh) and
             session.refresh != "" ->
        case refresh_token(session) do
          {:ok, session} ->
            do_request(session, method, path, query, body, false)

          {:network, reason} ->
            {:network, reason}

          :rejected ->
            {:ok, session, 401, raw, headers}

          {:error, _code, _message} = error ->
            error
        end

      {:ok, status, raw, headers} ->
        {:ok, session, status, raw, headers}

      other ->
        other
    end
  end

  defp refresh_token(session) do
    body = Jason.encode!(%{"refresh_token" => session.refresh})
    silent = %{session | token: nil}

    case round_trip(silent, "POST", "/api/v1/auth/refresh", %{}, body) do
      {:network, _} = network ->
        network

      {:ok, 200, raw, _headers} ->
        store_refresh(session, raw)

      {:ok, _status, _raw, _headers} ->
        :rejected
    end
  end

  defp store_refresh(session, raw) do
    case Jason.decode(raw) do
      {:ok, %{"access_token" => token} = parsed} when is_binary(token) and token != "" ->
        refresh = blank_as(parsed["refresh_token"], session.refresh)
        email = previous_email(session.opts)
        expires_in = parsed["expires_in"] || 0
        now = session.opts[:now] || DateTime.utc_now()

        creds =
          %{
            "access_token" => token,
            "refresh_token" => refresh,
            "email" => email
          }
          |> put_expiry(now, expires_in)

        case write_credentials(session.opts, creds) do
          :ok ->
            {:ok, %{session | token: token, refresh: refresh, from_file: true}}

          {:error, reason} ->
            {:error, 2, "storing credentials: #{inspect(reason)}\n"}
        end

      _ ->
        {:error, 1, "refresh response had no access_token\n"}
    end
  end

  defp previous_email(opts) do
    case read_credentials(opts) do
      {:ok, %{"email" => email}} when is_binary(email) and email != "" -> email
      _ -> nil
    end
  end

  defp put_expiry(creds, now, expires_in) when is_integer(expires_in) and expires_in > 0 do
    Map.put(
      creds,
      "expires_at",
      now |> DateTime.add(expires_in, :second) |> DateTime.to_iso8601()
    )
  end

  defp put_expiry(creds, _now, _expires_in), do: creds

  defp blank_as(value, _fallback) when is_binary(value) and value != "", do: value
  defp blank_as(_value, fallback), do: fallback

  defp round_trip(session, method, path, query, body) do
    headers =
      [{"user-agent", @user_agent}, {"accept", accept_header(session.globals.profile)}]

    headers =
      if is_binary(body) do
        [{"content-type", "application/json"} | headers]
      else
        headers
      end

    headers =
      if is_binary(session.token) and session.token != "" do
        [{"authorization", "Bearer " <> session.token} | headers]
      else
        headers
      end

    options =
      [
        method: method,
        url: session.host <> path,
        headers: headers,
        decode_body: false,
        retry: false,
        receive_timeout: 60_000,
        connect_options: [timeout: 5_000]
      ]
      |> maybe_params(query)
      |> maybe_body(body)

    case Req.request(options) do
      {:ok, response} ->
        {:ok, response.status, body_binary(response.body), header_list(response.headers)}

      {:error, exception} ->
        {:network, exception_reason(exception)}
    end
  rescue
    error ->
      {:network, Exception.message(error)}
  end

  defp maybe_params(options, query) when query in [nil, %{}], do: options

  defp maybe_params(options, query) do
    params = Map.new(query, fn {key, value} -> {to_string(key), to_string(value)} end)
    Keyword.put(options, :params, params)
  end

  defp maybe_body(options, body) when is_binary(body), do: Keyword.put(options, :body, body)

  # Req sets the multipart content-type and boundary itself.
  defp maybe_body(options, {:multipart, fields}),
    do: Keyword.put(options, :form_multipart, fields)

  defp maybe_body(options, _body), do: options

  defp accept_header(profile) when profile in [nil, ""], do: "application/json"
  defp accept_header(profile), do: ~s(application/json; profile="#{profile}")

  defp body_binary(body) when is_binary(body), do: body
  defp body_binary(nil), do: ""
  defp body_binary(body) when is_map(body) or is_list(body), do: Jason.encode!(body)
  defp body_binary(body), do: to_string(body)

  defp header_list(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      value
      |> List.wrap()
      |> Enum.map(fn item -> {to_string(key), to_string(item)} end)
    end)
  end

  defp header_list(headers) when is_list(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp exception_reason(%{reason: reason}), do: reason
  defp exception_reason(other), do: other

  defp env(opts, key) do
    case Keyword.fetch(opts, :env) do
      {:ok, env} when is_map(env) -> Map.get(env, key)
      _ -> System.get_env(key)
    end
  end

  defp config_dir(opts) do
    home = opts[:home]

    if is_binary(home) and home != "" do
      Path.join(home, ".jurisdictional")
    else
      raise "jurisdictional CLI home is required"
    end
  end

  defp read_credentials(opts) do
    path = Path.join(config_dir(opts), "credentials.json")

    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> {:ok, map}
          _ -> {:error, :invalid_credentials}
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_token_file(opts) do
    path = Path.join(config_dir(opts), "token")

    case File.read(path) do
      {:ok, raw} -> {:ok, String.trim(raw)}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp credential_json(creds) do
    creds
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end
end
