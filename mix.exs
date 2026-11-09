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
        name: "jurisdictional"
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
