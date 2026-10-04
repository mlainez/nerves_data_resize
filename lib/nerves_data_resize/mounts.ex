defmodule NervesDataResize.Mounts do
  @moduledoc false
  # Parsing of /proc/mounts.

  @type entry :: %{
          device: String.t(),
          mount_point: String.t(),
          type: String.t(),
          opts: String.t()
        }

  @spec read(module()) :: {:ok, [entry()]} | {:error, term()}
  def read(sys) do
    with {:ok, text} <- sys.read("/proc/mounts"), do: {:ok, parse(text)}
  end

  @spec parse(String.t()) :: [entry()]
  def parse(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ", trim: true) do
        [device, mount_point, type, opts | _] ->
          [
            %{
              device: unescape(device),
              mount_point: unescape(mount_point),
              type: type,
              opts: opts
            }
          ]

        _ ->
          []
      end
    end)
  end

  # The last entry wins: a later mount hides an earlier one.
  @spec find([entry()], String.t()) :: entry() | nil
  def find(entries, mount_point) do
    entries |> Enum.filter(&(&1.mount_point == mount_point)) |> List.last()
  end

  @spec normalize(term()) :: {:ok, String.t()} | {:error, term()}
  def normalize(path) when is_binary(path) and path != "" do
    case Path.expand(path) do
      "/" -> {:error, {:refused_mount_point, "/"}}
      expanded -> {:ok, expanded}
    end
  end

  def normalize(other), do: {:error, {:invalid_mount_point, other}}

  # The kernel escapes space, tab, newline and backslash as octal.
  defp unescape(s) do
    Regex.replace(~r/\\([0-7]{3})/, s, fn _, octal -> <<String.to_integer(octal, 8)>> end)
  end
end
