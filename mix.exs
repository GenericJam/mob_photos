defmodule MobPhotos.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_photos,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    # Local path deps while the plugin system is dogfooded; switch :mob to the
    # Hex constraint ("~> 0.6") when mob publishes. :mob_dev is test-only (the
    # manifest tests run the real pre-publish validator) and never ships.
    [
      {:mob, path: "../mob"},
      {:mob_dev, path: "../mob_dev", only: [:dev, :test], runtime: false},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false}
    ]
  end
end
