defmodule FwupDataResize.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :fwup_data_resize,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: [],
      name: "FwupDataResize",
      description:
        "First-boot F2FS data-partition grow for Nerves devices (idempotent + safe)",
      package: package(),
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp package do
    [
      name: :fwup_data_resize,
      licenses: ["Apache-2.0"],
      files: ~w(lib mix.exs README.md LICENSE),
      links: %{"GitHub" => "https://github.com/mlainez/fwup_data_resize"}
    ]
  end
end
