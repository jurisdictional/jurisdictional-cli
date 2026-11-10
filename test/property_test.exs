defmodule JurisdictionalCli.PropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias JurisdictionalCli.Secret
  alias JurisdictionalCli.Store

  # --save -------------------------------------------------------------------

  defp segment do
    one_of([constant(".."), constant("."), constant(""), string(:printable, max_length: 12)])
  end

  defp request_path do
    gen all(segments <- list_of(segment(), max_length: 6)) do
      "/" <> Enum.join(segments, "/")
    end
  end

  defp query do
    map_of(
      string(:alphanumeric, min_length: 1, max_length: 8),
      string(:printable, max_length: 12),
      max_length: 3
    )
  end

  property "a saved response path never leaves the save folder" do
    dir = Path.join(System.tmp_dir!(), "jcli-save-root")

    check all(
            method <- member_of(~w(GET POST PUT PATCH DELETE)),
            path <- request_path(),
            query <- query()
          ) do
      relative = Store.relative_path(method, path, query)
      segments = Path.split(relative)

      assert Path.type(relative) == :relative
      refute ".." in segments
      assert hd(segments) == String.downcase(method)
      assert String.ends_with?(relative, ".json")
      assert String.starts_with?(Path.expand(relative, dir), dir <> "/")
    end
  end

  defp json_value(depth \\ 3)
  defp json_value(0), do: one_of([integer(), boolean(), string(:printable, max_length: 8)])

  defp json_value(depth) do
    one_of([
      json_value(0),
      list_of(json_value(depth - 1), max_length: 3),
      map_of(string(:alphanumeric, max_length: 6), json_value(depth - 1), max_length: 3)
    ])
  end

  property "a body with a token at any depth is refused, and other bodies are not" do
    check all(
            value <- json_value(),
            key <- member_of(["access_token", "refresh_token"]),
            path <- list_of(member_of([:list, "data", "auth"]), max_length: 3)
          ) do
      clean = Jason.encode!(%{"data" => value})
      refute Store.token_body?(clean)

      nested =
        Enum.reduce(path, %{key => "jur_secret"}, fn
          :list, acc -> [acc]
          name, acc -> %{name => acc}
        end)

      assert Store.token_body?(Jason.encode!(%{"data" => value, "x" => nested}))
    end
  end

  # Secret input --------------------------------------------------------------

  defp feed(chars) do
    {:ok, agent} = Agent.start_link(fn -> chars end)

    fn ->
      Agent.get_and_update(agent, fn
        [c | rest] -> {c, rest}
        [] -> {:eof, []}
      end)
    end
  end

  property "typed characters and backspaces give the same line a terminal would" do
    check all(keys <- list_of(one_of([string(:ascii, length: 1), constant("\d")]), min_length: 1)) do
      expected =
        Enum.reduce(keys, "", fn
          "\d", acc -> String.slice(acc, 0..-2//1)
          c, acc -> acc <> c
        end)

      assert Secret.collect(feed(keys ++ ["\r"])) == expected
    end
  end
end
