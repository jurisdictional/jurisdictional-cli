defmodule JurisdictionalCli.SecretTest do
  use ExUnit.Case, async: true

  alias JurisdictionalCli.Secret

  defp feed(chars) do
    {:ok, agent} = Agent.start_link(fn -> chars end)

    fn ->
      Agent.get_and_update(agent, fn
        [c | rest] -> {c, rest}
        [] -> {:eof, []}
      end)
    end
  end

  test "enter ends the line" do
    assert Secret.collect(feed(~w(h u n t e r 2) ++ ["\r", "x"])) == "hunter2"
    assert Secret.collect(feed(["a", "b", "\n"])) == "ab"
  end

  test "backspace removes the last character" do
    assert Secret.collect(feed(["a", "b", "X", "\d", "c", "\r"])) == "abc"
    assert Secret.collect(feed(["\b", "\b", "a", "\r"])) == "a"
    assert Secret.collect(feed(["é", "\d", "e", "\r"])) == "e"
  end

  test "ctrl-c interrupts and ctrl-d on an empty line is end of input" do
    assert Secret.collect(feed(["a", "\u0003"])) == :interrupted
    assert Secret.collect(feed(["\u0004"])) == nil
    assert Secret.collect(feed(["a", "\u0004"])) == "a"
    assert Secret.collect(feed([])) == nil
  end

  test "stdin under the test runner is not a terminal" do
    refute Secret.terminal?()
  end

  # Runs the real reader under a pseudo-terminal and checks the screen.
  @tag :pty
  test "a person at a terminal does not see the secret they type" do
    script = System.find_executable("script")
    elixir = System.find_executable("elixir")

    if is_nil(script) or is_nil(elixir) do
      IO.puts("skipped: needs script(1) and elixir on PATH")
    else
      dir = Path.join(System.tmp_dir!(), "jcli-pty-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      screen = Path.join(dir, "screen.txt")
      ebin = Application.app_dir(:jurisdictional_cli, "ebin")

      code =
        ~s|IO.write(:stderr, "result=" <> inspect(JurisdictionalCli.Secret.read("secret: ")) <> "\\n")|

      cmd = [elixir, "-pa", ebin, "-e", code] |> Enum.map_join(" ", &shell_quote/1)

      run =
        case :os.type() do
          {:unix, :darwin} -> "script -q #{shell_quote(screen)} #{cmd}"
          _ -> "script -qec #{shell_quote(cmd)} #{shell_quote(screen)}"
        end

      System.cmd("sh", ["-c", "(sleep 2; printf 'hunter2\\r'; sleep 2) | #{run} > /dev/null 2>&1"])

      output = File.read!(screen)
      File.rm_rf!(dir)

      assert output =~ "secret: "
      assert output =~ ~s(result="hunter2")
      [before_result | _] = String.split(output, "result=")
      refute before_result =~ "hunter2", "the secret was echoed:\n#{output}"
    end
  end

  defp shell_quote(s), do: "'" <> String.replace(s, "'", "'\\''") <> "'"
end
