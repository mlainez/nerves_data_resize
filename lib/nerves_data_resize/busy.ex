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
        # /proc holds non-PID entries too ("self", "cpuinfo", ...); keep only
        # names that are entirely digits.
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

    # Besides each open file descriptor in fd/, a process can also hold the
    # mount point as its current directory, its running executable, or (in a
    # chroot) its root -- each is a symlink the kernel exposes the same way.
    links = fds ++ Enum.map(~w(cwd exe root), &(base <> "/" <> &1))

    paths =
      links
      |> Enum.flat_map(fn link ->
        case sys.read_link(link) do
          # The kernel appends " (deleted)" to the target of a symlink whose
          # file was unlinked while still open; strip it to compare paths.
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
