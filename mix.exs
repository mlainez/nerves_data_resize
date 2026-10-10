defmodule NervesDataResize.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/mlainez/nerves_data_resize"

  def project do
    [
      app: :nerves_data_resize,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "NervesDataResize",
      description:
        "Grows a mounted ext4 or f2fs filesystem to fill its partition. " <>
          "Idempotent, with the standard resize tools and no extra runtime dependencies.",
      source_url: @source_url,
      package: package(),
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: :nerves_data_resize,
      licenses: ["Apache-2.0"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{"GitHub" => @source_url}
    ]
  end
end
