defmodule JurisdictionalCli.Store do
  @moduledoc """
  Writes one raw response body and one index entry.

  Other apps read `index.json`, then the file it names.
  A body that contains an access token or a refresh token is refused.
  """

  @description "Raw response bodies. Each entry is the request that produced the file."

  def put(dir, %{
        method: method,
        path: path,
        query: query,
        status: status,
        body: body,
        captured_at: captured_at
      })
      when is_binary(dir) and is_binary(body) do
    method = String.upcase(method)
    query = stringify(query)

    if token_body?(body) do
      {:error, :token}
    else
      relative = relative_path(method, path, query)

      with :ok <- File.mkdir_p(dir),
           {:ok, entries} <- read_index(Path.join(dir, "index.json")),
           :ok <- write_body(Path.join(dir, relative), body) do
        entry = %{
          "method" => method,
          "path" => path,
          "query" => query,
          "status" => status,
          "file" => relative,
          "captured_at" => captured_at
        }

        entries =
          entries
          |> Enum.reject(fn existing ->
            {existing["method"], existing["path"], existing["query"]} == {method, path, query}
          end)
          |> then(&[entry | &1])
          |> Enum.sort_by(& &1["file"])

        case write_index(dir, entries) do
          :ok -> {:ok, relative}
          {:error, _} = error -> error
        end
      end
    end
  end

  def relative_path(method, path, query) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.map(&visible_segment/1)

    segments = if segments == [], do: ["response"], else: segments
    {file, dirs} = List.pop_at(segments, -1)
    file = String.replace_suffix(file, ".json", "")

    file =
      case query_slug(query) do
        "" -> file
        slug -> file <> "__" <> slug
      end

    Path.join([String.downcase(method) | dirs] ++ [file <> ".json"])
  end

  defp stringify(query) do
    Map.new(query, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  @doc """
  True when the body is JSON with an `access_token` or `refresh_token` key at any depth.
  """
  def token_body?(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> holds_token?(decoded)
      _ -> false
    end
  end

  defp holds_token?(map) when is_map(map) do
    Map.has_key?(map, "access_token") or Map.has_key?(map, "refresh_token") or
      Enum.any?(map, fn {_key, value} -> holds_token?(value) end)
  end

  defp holds_token?(list) when is_list(list), do: Enum.any?(list, &holds_token?/1)
  defp holds_token?(_value), do: false

  defp visible_segment(segment) do
    case String.trim_leading(segment, ".") do
      "" -> "index"
      visible -> visible
    end
  end

  defp query_slug(query) when query == %{}, do: ""

  defp query_slug(query) do
    query
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.map_join("__", fn {key, value} ->
      slug(to_string(key)) <> "_" <> slug(to_string(value))
    end)
  end

  defp slug(value) do
    negative = String.starts_with?(value, "-")

    body =
      value
      |> String.downcase()
      |> String.trim_leading("-")
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim("-")

    if negative and body != "" do
      "-" <> body
    else
      body
    end
  end

  defp read_index(path) do
    case File.read(path) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, %{"entries" => entries}} when is_list(entries) -> {:ok, entries}
          _ -> {:error, "index.json is not a catalog"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_body(path, body) do
    File.mkdir_p!(Path.dirname(path))

    body =
      case Jason.decode(body) do
        {:ok, decoded} -> Jason.encode!(decoded, pretty: true) <> "\n"
        _ -> ensure_newline(body)
      end

    atomic_write(path, body)
  end

  defp write_index(dir, entries) do
    raw =
      Jason.encode!(
        %{
          "description" => @description,
          "entries" => entries
        },
        pretty: true
      ) <> "\n"

    atomic_write(Path.join(dir, "index.json"), raw)
  end

  defp atomic_write(path, contents) do
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, contents),
         :ok <- File.rename(tmp, path) do
      File.chmod(path, 0o644)
    end
  end

  defp ensure_newline(body) do
    if String.ends_with?(body, "\n"), do: body, else: body <> "\n"
  end
end
