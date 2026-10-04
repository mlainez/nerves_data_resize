defmodule NervesDataResize.Busy do
  @moduledoc false
  # Finds processes that hold a path under a mount point open, by reading
  # the /proc/<pid>/{fd,cwd,exe,root} symlinks.

  @type holder :: %{pid: pos_integer(), name: String.t(), path: String.t()}

  @spec holders(module(), String.t()) :: [holder()]
  def holders(sys, mount_point) do
    case sys.ls("/proc") do
      {:ok, entries} ->
        entries
        |> Enum.filter(&match?({_, ""}, Integer.parse(&1)))
        |> Enum.map(&String.to_integer/1)
        |> Enum.sort()
        |> Enum.flat_map(&process_holders(sys, &1, mount_point))

      {:error, _} ->
        []
    end
  end

  defp process_holders(sys, pid, mount_point) do
    base = "/proc/#{pid}"

    fds =
      case sys.ls(base <> "/fd") do
        {:ok, names} -> Enum.map(names, &(base <> "/fd/" <> &1))
        {:error, _} -> []
      end

    paths =
      (fds ++ Enum.map(~w(cwd exe root), &(base <> "/" <> &1)))
      |> Enum.flat_map(fn link ->
        case sys.read_link(link) do
          {:ok, target} -> [String.replace_suffix(target, " (deleted)", "")]
          {:error, _} -> []
        end
      end)
      |> Enum.filter(&under?(&1, mount_point))
      |> Enum.uniq()

    case paths do
      [] -> []
      _ -> Enum.map(paths, &%{pid: pid, name: name(sys, pid), path: &1})
    end
  end

  defp name(sys, pid) do
    case sys.read("/proc/#{pid}/comm") do
      {:ok, comm} -> String.trim(comm)
      {:error, _} -> "?"
    end
  end

  defp under?(path, mount_point) do
    path == mount_point or String.starts_with?(path, mount_point <> "/")
  end
end
