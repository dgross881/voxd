defmodule Voxd.MixProject do
  use Mix.Project

  def project do
    [
      app: :voxd,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Voxd.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nx, "~> 0.12"},
      {:exla, "~> 0.12"},
      {:bumblebee, "~> 0.7"},
      {:exile, "~> 0.14"},
      {:muontrap, "~> 1.8"},
      {:req, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:mox, "~> 1.2", only: :test}
    ]
  end
end
