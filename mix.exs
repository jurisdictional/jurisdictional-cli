defmodule JurisdictionalCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :jurisdictional_cli,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: [
        main_module: JurisdictionalCli,
        name: "jurisdictional",
        # A crash dump copies process memory, which can hold a password, into the cwd.
        emu_args: "-env ERL_CRASH_DUMP_BYTES 0"
      ],
      releases: [
        jurisdictional_cli: [
          include_executables_for: [:unix],
          include_erts: true,
          strip_beams: true
        ]
      ],
      aliases: [
        precommit: ["format", "test"]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :public_key, :crypto],
      mod: {JurisdictionalCli.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
