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
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
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
end
