defmodule NervesDataResize.DeviceMapper do
  @moduledoc false
  # Optional partition growth for a device-mapper partition (kpartx style):
  # an fwup task rewrites the partition table of the disk, then the linear
  # mapping is reloaded with the new length.

  require Logger

  @type table :: %{sectors: non_neg_integer(), device: String.t(), start: non_neg_integer()}
  @type plan :: %{
          name: String.t(),
          device: String.t(),
          start: non_neg_integer(),
          new_sectors: non_neg_integer()
        }

  @doc "Returns the new mapping when the partition ends before its disk does, `nil` otherwise."
  @spec plan(module(), String.t(), keyword()) :: {:ok, plan() | nil} | {:error, term()}
  def plan(sys, partition, grow) do
    name = Path.basename(partition)

    with {:ok, disk_sectors} <- sysfs_sectors(sys, Keyword.fetch!(grow, :disk)),
         {:ok, out} <- dmsetup_table(sys, name),
         {:ok, table} <- parse_table(out) do
      {:ok, grow_plan(name, table, disk_sectors)}
    end
  end

  defp dmsetup_table(sys, name) do
    case sys.cmd("dmsetup", ["table", name], []) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:dmsetup_table_failed, code, out}}
    end
  end

  @doc "Parses `0 <sectors> linear <major:minor> <start>`; only a single linear target is supported."
  @spec parse_table(String.t()) :: {:ok, table()} | {:error, term()}
  def parse_table(out) do
    case String.split(String.trim(out)) do
      ["0", sectors, "linear", device, start] ->
        {:ok,
         %{sectors: String.to_integer(sectors), device: device, start: String.to_integer(start)}}

      _ ->
        {:error, {:unsupported_dm_table, out}}
    end
  end

  # Sectors are always 512 bytes for dmsetup/fwup purposes.
  @sectors_per_mib div(1024 * 1024, 512)

  @spec grow_plan(String.t(), table(), non_neg_integer()) :: plan() | nil
  def grow_plan(name, %{sectors: sectors, device: device, start: start}, disk_sectors) do
    new_sectors = disk_sectors - start
    growth = new_sectors - sectors

    # Growing by less than 1 MiB is not worth the disturbance.
    if growth >= @sectors_per_mib do
      %{name: name, device: device, start: start, new_sectors: new_sectors}
    end
  end

  @spec grow(module(), plan() | nil, keyword() | nil) :: :ok | {:error, term()}
  def grow(_sys, nil, _grow), do: :ok

  def grow(sys, plan, grow) do
    table = "0 #{plan.new_sectors} linear #{plan.device} #{plan.start}"

    fwup_args = [
      "-a",
      "-d",
      Keyword.fetch!(grow, :disk),
      "-t",
      Keyword.fetch!(grow, :task),
      "-i",
      Keyword.fetch!(grow, :ops_fw)
    ]

    # fwup rewrites the partition table on disk; dmsetup then has to be told
    # about the new length in its own three-step dance: a mapping can only be
    # reloaded while suspended, and must be resumed afterwards to take effect.
    with :ok <- run(sys, :fwup_failed, "fwup", fwup_args),
         :ok <- run(sys, :dmsetup_failed, "dmsetup", ["suspend", plan.name]),
         :ok <- run(sys, :dmsetup_failed, "dmsetup", ["reload", plan.name, "--table", table]),
         :ok <- run(sys, :dmsetup_failed, "dmsetup", ["resume", plan.name]) do
      Logger.info(
        "[nerves_data_resize] partition #{plan.name} grown to #{div(plan.new_sectors, 2048)} MB"
      )

      :ok
    end
  end

  defp run(sys, tag, program, args) do
    case sys.cmd(program, args, []) do
      {_, 0} -> :ok
      {out, code} -> {:error, {tag, args, code, out}}
    end
  end

  defp sysfs_sectors(sys, device) do
    case sys.read("/sys/class/block/" <> Path.basename(device) <> "/size") do
      {:ok, s} ->
        case Integer.parse(String.trim(s)) do
          {n, ""} -> {:ok, n}
          _ -> {:error, {:no_disk_size, device, :parse}}
        end

      {:error, reason} ->
        {:error, {:no_disk_size, device, reason}}
    end
  end
end
