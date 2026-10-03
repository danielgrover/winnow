defmodule Winnow.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/danielgrover/winnow"

  def project do
    [
      app: :winnow,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Winnow",
      description: "Priority-based prompt composition with token budgeting for Elixir",
      source_url: @source_url,
      docs: docs(),
      package: package(),
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp deps do
    [
      # Optional
      {:tiktoken, "~> 0.4", optional: true},

      # Dev/test
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Winnow",
      extras: ["README.md", "LICENSE"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp aliases do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end
