defmodule JurisdictionalCli.Release do
  @moduledoc false

  # Entry point for the bundled release. bin/jurisdictional calls
  # `bin/jurisdictional_cli eval "JurisdictionalCli.Release.main()" ARGS`,
  # and eval does not start applications, so this starts them first.
  def main do
    {:ok, _} = Application.ensure_all_started(:jurisdictional_cli)
    JurisdictionalCli.main(System.argv())
  end
end
