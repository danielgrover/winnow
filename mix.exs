defmodule Winnow.MixProject do
  use Mix.Project

  def project do
    [
      app: :winnow,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Winnow",
      description: "Priority-based prompt composition with token budgeting",
      source_url: "https://github.com/danielgrover/winnow",
      docs: docs()
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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp docs do
    [
      main: "Winnow"
    ]
  end
end
