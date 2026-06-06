# XLA_TARGET cannot be inferred on this machine (no nvcc on PATH) and xla
# silently falls back to the CPU archive, swapping out the CUDA build.
# Pin it here so every mix invocation links exla against cuda13.
System.put_env("XLA_TARGET", System.get_env("XLA_TARGET", "cuda13"))

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
      # runtime: false in test — the cuda13-linked NIF cannot dlopen the pip
      # CUDA libs without bin/gpu-env, and tests must run with no GPU at all.
      {:exla, "~> 0.12", runtime: Mix.env() != :test},
      {:bumblebee, "~> 0.7"},
      {:exile, "~> 0.14"},
      {:muontrap, "~> 1.8"},
      {:req, "~> 0.5"},
      {:toml, "~> 0.7"},
      {:mox, "~> 1.2", only: :test},
      # Req.Test's plug-stub mode needs Plug present; test-only.
      {:plug, "~> 1.0", only: :test}
    ]
  end
end
