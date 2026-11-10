defmodule JurisdictionalCli.Present do
  @moduledoc false

  @doc """
  A short table from fields the response already has.
  Returns `:error` when the body has no rows to show.
  """
  def table(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> render(decoded)
      _ -> :error
    end
  end

  defp render(decoded) do
    case rows(decoded) do
      {[_ | _] = rows, kind} ->
        case columns(rows, kind) do
          [] -> :error
          cols -> {:ok, format(rows, cols)}
        end

      _ ->
        :error
    end
  end

  defp rows(items) when is_list(items) do
    case maps_of(items) do
      {:ok, rows} -> {rows, :rows}
      :error -> :error
    end
  end

  defp rows(%{} = map) do
    case tool_rows(map) do
      {:ok, rows} -> {rows, :tools}
      :none -> data_rows(map)
    end
  end

  defp rows(_other), do: :error

  defp tool_rows(%{"tools" => tools}) when is_list(tools) do
    case maps_of(tools) do
      {:ok, [first | _] = rows} ->
        if Map.has_key?(first, "name"), do: {:ok, rows}, else: :none

      _ ->
        :none
    end
  end

  defp tool_rows(_other), do: :none

  defp data_rows(%{"data" => %{"jurisdictions" => list}}) when is_list(list) do
    case maps_of(list) do
      {:ok, rows} -> {rows, :rows}
      :error -> {[], :rows}
    end
  end

  defp data_rows(%{"data" => list}) when is_list(list) do
    case maps_of(list) do
      {:ok, rows} -> {rows, :rows}
      :error -> {[], :rows}
    end
  end

  defp data_rows(%{"data" => %{} = data}) do
    if Map.has_key?(data, "id") or Map.has_key?(data, "name") do
      {[data], :rows}
    else
      :error
    end
  end

  defp data_rows(_other), do: :error

  defp maps_of(items) do
    if Enum.all?(items, &is_map/1) do
      {:ok, items}
    else
      :error
    end
  end

  defp columns(_rows, :tools) do
    [
      {"name", &cell(&1, "name")},
      {"description", fn row -> row |> cell("description") |> truncate(72) end}
    ]
  end

  defp columns(rows, :rows) do
    []
    |> maybe_col(rows, "id", "id")
    |> maybe_col(rows, "level", "level")
    |> maybe_col(rows, "name", "name")
    |> maybe_url(rows)
  end

  defp maybe_col(cols, rows, key, header) do
    if any_field?(rows, key) do
      cols ++ [{header, &cell(&1, key)}]
    else
      cols
    end
  end

  defp maybe_url(cols, rows) do
    case Enum.find(["url", "website", "website_url", "online_url"], &any_field?(rows, &1)) do
      nil -> cols
      # A long URL would widen every row; --json prints it in full.
      key -> cols ++ [{"url", fn row -> row |> cell(key) |> truncate(72) end}]
    end
  end

  defp any_field?(rows, key), do: Enum.any?(rows, &Map.has_key?(&1, key))

  defp format(rows, cols) do
    header = Enum.map(cols, &elem(&1, 0))

    body =
      Enum.map(rows, fn row ->
        Enum.map(cols, fn {_header, fun} -> fun.(row) end)
      end)

    widths =
      Enum.zip([header | body])
      |> Enum.map(fn column ->
        column
        |> Tuple.to_list()
        |> Enum.map(&String.length/1)
        |> Enum.max()
      end)

    [header | body]
    |> Enum.map(&write_row(widths, &1))
    |> IO.iodata_to_binary()
  end

  defp write_row(widths, cells) do
    line =
      cells
      |> Enum.zip(widths)
      |> Enum.map_join("  ", fn {cell, width} -> String.pad_trailing(cell, width) end)

    [line, "\n"]
  end

  defp cell(row, key) do
    case Map.get(row, key) do
      nil ->
        ""

      value ->
        value
        |> cell_string()
        |> String.trim()
        |> String.replace("\n", " ")
    end
  end

  defp cell_string(value) when is_binary(value), do: value
  defp cell_string(value) when is_integer(value), do: Integer.to_string(value)
  defp cell_string(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp cell_string(value) when is_atom(value), do: Atom.to_string(value)
  defp cell_string(_value), do: ""

  defp truncate(text, max) do
    chars = String.graphemes(text)

    if length(chars) <= max do
      text
    else
      chars
      |> Enum.take(max - 1)
      |> Enum.join()
      |> Kernel.<>("…")
    end
  end
end
