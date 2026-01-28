defmodule Youtrack.MixProject do
  use Mix.Project

  def project do
    [
      app: :youtrack,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:yaml_elixir, "~> 2.9"}
    ]
  end
end
