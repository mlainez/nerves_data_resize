defmodule NervesDataResize.FakeSystem do
  @moduledoc """
  A `NervesDataResize.System` that simulates one block device with one
  filesystem, and records every command.

  State lives in an `Agent` registered under this module's name, so tests
  using it must not run concurrently.

  `start/1` options:

    * `:device`, `:mount_point`, `:type`, `:mount_opts` - the mounted filesystem
    * `:fs_bytes`, `:part_bytes` - current filesystem and device sizes
    * `:mounted?` - whether the filesystem starts mounted (default `true`)
    * `:missing` - executables absent from the `PATH`
    * `:open_files` - `[%{pid:, name:, path:, kind: :fd | :cwd}]`
    * `:fail` - `%{key => {output, status}}`, returned instead of simulating the
      command; key is the program, or `{program, first_arg}`
    * `:proc_mounts` - `:unreadable` to make `/proc/mounts` unreadable
    * `:df_fail_after` - number of `df` calls that succeed before `df` fails
    * `:sysfs?`- `false` hides `/sys/class/block/<dev>/size` (default `true`)
    * `:disk`, `:disk_sectors`, `:dm_table` - device-mapper partition growing
  """

  @behaviour NervesDataResize.System

  @tools ~w(df mount umount blockdev resize2fs resize.f2fs btrfs xfs_growfs fwup dmsetup)

  def start(opts \\ []) do
    state =
      %{
        device: "/dev/mmcblk0p3",
        mount_point: "/data",
        type: "ext4",
        mount_opts: "rw,relatime",
        fs_bytes: 64 * 1024 * 1024,
        part_bytes: 512 * 1024 * 1024,
        mounted?: true,
        missing: [],
        open_files: [],
        fail: %{},
        proc_mounts: :ok,
        sysfs?: true,
        disk: "mmcblk0",
        disk_sectors: nil,
        dm_table: nil,
        pending_sectors: nil,
        df_fail_after: nil,
        calls: []
      }
      |> Map.merge(Map.new(opts))

    {:ok, _} = Agent.start(fn -> state end, name: __MODULE__)
    :ok
  end

  def stop, do: if(Process.whereis(__MODULE__), do: Agent.stop(__MODULE__))

  def state, do: Agent.get(__MODULE__, & &1)
  def update(fun), do: Agent.update(__MODULE__, fun)

  @doc "Recorded commands as `[\"program arg ...\"]`, oldest first."
  def calls,
    do: state().calls |> Enum.reverse() |> Enum.map(fn {p, a} -> Enum.join([p | a], " ") end)

  @doc "Recorded commands whose program is `program`."
  def calls(program), do: Enum.filter(calls(), &String.starts_with?(&1, program <> " "))

  @impl true
  def find_executable(name) do
    if name in @tools and name not in state().missing, do: "/usr/bin/" <> name
  end

  @impl true
  def read("/proc/mounts") do
    s = state()

    if s.proc_mounts == :unreadable do
      {:error, :enoent}
    else
      noise = "rootfs / rootfs rw 0 0\nproc /proc proc rw,nosuid 0 0\n"

      line =
        if s.mounted?,
          do:
            "#{String.replace(s.device, " ", "\\040")} #{String.replace(s.mount_point, " ", "\\040")} #{s.type} #{s.mount_opts} 0 0\n",
          else: ""

      {:ok, noise <> line}
    end
  end

  def read("/sys/class/block/" <> rest) do
    s = state()
    name = rest |> String.replace_suffix("/size", "")

    cond do
      name == s.disk and s.disk_sectors -> {:ok, "#{s.disk_sectors}\n"}
      name == Path.basename(s.device) and s.sysfs? -> {:ok, "#{div(s.part_bytes, 512)}\n"}
      true -> {:error, :enoent}
    end
  end

  def read("/proc/" <> rest) do
    case String.split(rest, "/") do
      [pid, "comm"] ->
        case Enum.find(state().open_files, &("#{&1.pid}" == pid)) do
          nil -> {:error, :enoent}
          file -> {:ok, file.name <> "\n"}
        end

      _ ->
        {:error, :enoent}
    end
  end

  def read(_), do: {:error, :enoent}

  @impl true
  def ls("/proc") do
    pids = state().open_files |> Enum.map(&"#{&1.pid}") |> Enum.uniq()
    {:ok, ["self", "mounts" | pids]}
  end

  def ls("/proc/" <> rest) do
    case String.split(rest, "/") do
      [pid, "fd"] ->
        {:ok, ["0" | for({_file, i} <- fds(pid), do: "#{i}")]}

      _ ->
        {:error, :enoent}
    end
  end

  def ls(_), do: {:error, :enoent}

  @impl true
  def read_link("/proc/" <> rest) do
    case String.split(rest, "/") do
      [_pid, "fd", "0"] ->
        {:ok, "/dev/null"}

      [pid, "fd", n] ->
        case Enum.find(fds(pid), fn {_, i} -> "#{i}" == n end) do
          {file, _} -> {:ok, file.path}
          nil -> {:error, :enoent}
        end

      [pid, "cwd"] ->
        case Enum.find(state().open_files, &("#{&1.pid}" == pid and &1.kind == :cwd)) do
          nil -> {:error, :enoent}
          file -> {:ok, file.path}
        end

      _ ->
        {:error, :enoent}
    end
  end

  def read_link(_), do: {:error, :enoent}

  defp fds(pid) do
    state().open_files
    |> Enum.filter(&("#{&1.pid}" == pid and &1.kind == :fd))
    |> Enum.with_index(3)
  end

  @impl true
  def cmd(program, args, _opts) do
    Agent.get_and_update(__MODULE__, fn s ->
      s = %{s | calls: [{program, args} | s.calls]}

      case injected(s, program, args) do
        nil ->
          {out, s} = simulate(program, args, s)
          {out, s}

        forced ->
          {forced, s}
      end
    end)
  end

  defp injected(s, program, args) do
    Map.get(s.fail, {program, List.first(args)}) || Map.get(s.fail, program) ||
      df_failure(s, program)
  end

  defp df_failure(%{df_fail_after: n} = s, "df") when is_integer(n) do
    if Enum.count(s.calls, &match?({"df", _}, &1)) > n, do: {"df: gone", 1}
  end

  defp df_failure(_s, _program), do: nil

  defp simulate("df", ["-P", "-k", mp], s) do
    if s.mounted? and mp == s.mount_point do
      out =
        "Filesystem 1024-blocks Used Available Capacity Mounted on\n" <>
          "#{s.device} #{div(s.fs_bytes, 1024)} 100 #{div(s.fs_bytes, 1024)} 1% #{mp}\n"

      {{out, 0}, s}
    else
      {{"df: #{mp}: no such file or directory", 1}, s}
    end
  end

  defp simulate("umount", [mp], s) do
    if s.mounted? and mp == s.mount_point,
      do: {{"", 0}, %{s | mounted?: false}},
      else: {{"umount: #{mp}: not mounted.", 32}, s}
  end

  defp simulate("mount", args, s) do
    {opts, device, mp} =
      case args do
        ["-t", _type, "-o", opts, device, mp] -> {opts, device, mp}
        ["-t", _type, device, mp] -> {s.mount_opts, device, mp}
      end

    if s.mounted?,
      do: {{"mount: #{mp}: already mounted", 32}, s},
      else: {{"", 0}, %{s | mounted?: true, mount_opts: opts, device: device, mount_point: mp}}
  end

  defp simulate("resize.f2fs", [_dev], %{mounted?: true} = s),
    do: {{"Error: Device is mounted", 255}, s}

  defp simulate("resize.f2fs", [_dev], s), do: grown(s)
  defp simulate("resize2fs", [_dev], s), do: grown(s)
  defp simulate("btrfs", ["filesystem", "resize", "max", _mp], s), do: grown(s)
  defp simulate("xfs_growfs", [_mp], s), do: grown(s)

  defp simulate("blockdev", ["--getsize64", _dev], s), do: {{"#{s.part_bytes}\n", 0}, s}

  defp simulate("dmsetup", ["table", _name], s) do
    case s.dm_table do
      nil -> {{"Device does not exist.", 1}, s}
      table -> {{table, 0}, s}
    end
  end

  defp simulate("dmsetup", ["suspend", _], s), do: {{"", 0}, s}

  defp simulate("dmsetup", ["reload", _, "--table", table], s) do
    ["0", sectors | _] = String.split(table)
    {{"", 0}, %{s | pending_sectors: String.to_integer(sectors)}}
  end

  defp simulate("dmsetup", ["resume", _], s) do
    [zero, _old | rest] = String.split(s.dm_table)
    table = Enum.join([zero, s.pending_sectors | rest], " ")
    {{"", 0}, %{s | part_bytes: s.pending_sectors * 512, dm_table: table}}
  end

  defp simulate("fwup", _args, s), do: {{"", 0}, s}

  defp simulate(program, args, s),
    do: {{"fake: unexpected #{program} #{Enum.join(args, " ")}", 99}, s}

  defp grown(s), do: {{"", 0}, %{s | fs_bytes: s.part_bytes}}
end
