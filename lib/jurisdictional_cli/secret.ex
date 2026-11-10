defmodule JurisdictionalCli.Secret do
  @moduledoc false

  # Reads a secret without echoing it.
  # `:io.get_password/0` answers `enotsup` inside an escript,
  # and `stty` cannot reach the terminal from a port,
  # so this switches the shell to raw mode (OTP 26+) and reads one character at a time.
  # Piped stdin is not a terminal and reads as an ordinary line.

  @doc """
  Prints `prompt` on stderr and reads a line.
  On a terminal the characters are not shown.
  Returns the trimmed line, `nil` at end of input, or `:interrupted` on Ctrl-C.
  """
  def read(prompt) do
    IO.write(:stderr, prompt)

    if terminal?() and :shell.start_interactive({:noshell, :raw}) == :ok do
      try do
        collect(fn -> IO.getn("", 1) end)
      after
        :shell.start_interactive({:noshell, :cooked})
        IO.write(:stderr, "\n")
      end
    else
      case IO.gets("") do
        :eof -> nil
        {:error, _} -> nil
        line -> String.trim(to_string(line))
      end
    end
  end

  @doc "True when stdin is a terminal."
  def terminal? do
    Keyword.get(:io.getopts(:standard_io), :stdin, false) == true
  end

  @doc """
  Builds a line from characters read in raw mode.
  `next` returns the next character, or `:eof`.
  Enter ends the line, backspace removes a character, Ctrl-C interrupts,
  and Ctrl-D on an empty line is end of input.
  """
  def collect(next, acc \\ "") do
    case next.() do
      c when c in ["\r", "\n"] -> acc
      c when c in ["\d", "\b"] -> collect(next, drop_last(acc))
      "\u0003" -> :interrupted
      "\u0004" when acc == "" -> nil
      "\u0004" -> acc
      :eof -> if acc == "", do: nil, else: acc
      {:error, _} -> if acc == "", do: nil, else: acc
      c when is_binary(c) -> collect(next, acc <> c)
    end
  end

  defp drop_last(""), do: ""
  defp drop_last(acc), do: acc |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
end
