defmodule NervesDataResize.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :nerves_data_resize,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: [],
      name: "NervesDataResize",
      description:
        "First-boot F2FS data-partition grow for Nerves devices (idempotent + safe)",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp package do
    [
      name: :nerves_data_resize,
      licenses: ["Apache-2.0"],
      files: ~w(lib mix.exs README.md LICENSE),
      links: %{"GitHub" => "https://github.com/mlainez/nerves_data_resize"}
    ]
  end
end
