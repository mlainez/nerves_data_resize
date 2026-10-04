defmodule NervesDataResize do
  @moduledoc """
  Grows a mounted filesystem to fill the block device behind it.

  Images that ship a small pre-built filesystem inside a larger partition,
  or a filesystem that was not grown after its partition was, report the
  small size until something resizes them. `run/1` compares the filesystem
  size with the size of its device and, when the device is materially
  larger, grows the filesystem with the standard tool for its type:

  | Filesystem | Tool                          | While growing             |
  |------------|-------------------------------|---------------------------|
  | ext2/3/4   | `resize2fs`                   | mounted (online)          |
  | f2fs       | `resize.f2fs`                 | unmounted, then remounted |

  The filesystem type, backing device and mount options are read from
  `/proc/mounts`. Once the filesystem fills the device, later calls return
  `:already_grown` without touching anything.

  ## Configuration

  Application config, or the same keys passed to `run/1` (which win):

      config :nerves_data_resize, :config,
        mount_point: "/data",
        threshold: 1.1

    * `:mount_point` - mount to grow; any distinct mount except `/`
      (default `"/root"`).
    * `:partition` - block device to grow into. Default: the device mounted
      at `:mount_point`.
    * `:filesystem` - type override (`:ext4`, `"f2fs"`, or a module
      implementing `NervesDataResize.Filesystem`). Default: the type mounted
      at `:mount_point`.
    * `:mount_opts` - options for remounting an offline filesystem. Default:
      the options it is mounted with; `"nodev"` only when `/proc/mounts`
      cannot be read (which also requires `:partition` and `:filesystem`).
    * `:threshold` - grow only when `device_size / fs_size >= threshold`
      (default `1.1`).
    * `:min_grow` - and only when the device is at least this many bytes
      larger than the filesystem (default 64 MiB). Filesystem metadata makes
      `df` report less than the device size even when the filesystem fills it;
      without a minimum, a small partition could look "not grown" on every
      boot.
    * `:grow_partition` - `[disk:, ops_fw:, task:]`, see below.
    * `:runner` - module implementing `NervesDataResize.System`, for tests.
    * `:enabled` - `false` disables the library.

  Without any configuration `run/1` returns `:disabled`.

  ## Growing a device-mapper partition

  An image flashed raw keeps the partition size it was built with. With
  `:grow_partition`, a device-mapper partition (as created by `kpartx`) is
  first grown to the end of its disk: `fwup -a -d <disk> -t <task> -i <ops_fw>`
  rewrites the partition table, then the mapping is reloaded with `dmsetup`.
  `:partition` must then name the mapper device, for example
  `"/dev/mmcblk0p62p3"`.

  ## Requirements

  `df` is always required, `mount` and `umount` for offline filesystems, the
  resize tool of the filesystem, and `fwup` plus `dmsetup` with
  `:grow_partition`. A missing tool returns `{:error, {:missing_tools, names}}`
  before anything is touched.

  ## Safety

    * `/` and anything that is not a mount point listed in `/proc/mounts`
      are refused.
    * Online filesystems are never unmounted.
    * Before unmounting, `/proc/*/{fd,cwd,exe,root}` are scanned; if a process
      holds a path under the mount point, nothing is unmounted and
      `{:error, {:busy, holders}}` is returned. For example, IEx shell
      history (`-kernel shell_history enabled`) keeps a file open.
    * If a step fails after the unmount, the filesystem is mounted again
      before returning.
    * A filesystem that already fills its device is left alone.

  ## Return values

    * `:disabled`
    * `:already_grown`
    * `{:ok, %{before: bytes, after: bytes}}`
    * `{:error, reason}` for failures before anything was modified:
      `{:missing_tools, [String.t()]}`, `{:unsupported_filesystem, type}`,
      `{:not_mounted, path}`, `{:refused_mount_point, "/"}`,
      `{:invalid_mount_point, term}`, `{:proc_mounts_unreadable, reason}`,
      `{:df_failed, code, output}`, `{:df_parse, term}`,
      `{:blockdev_failed, code, output}`, `{:blockdev_parse, output}`,
      `{:no_disk_size, disk, reason}`, `{:dmsetup_table_failed, code, output}`,
      `{:unsupported_dm_table, output}`
    * `{:error, {:busy, [%{pid:, name:, path:}]}}` when an offline
      filesystem is held open; nothing was unmounted.
    * `{:error, %{step: step, reason: reason, remounted?: boolean}}` for
      failures once the resize started. `step` is one of `:umount`,
      `:grow_partition`, `:resize`, `:remount`, `:df`. `remounted?` is `true`
      when an offline filesystem was unmounted and is mounted again. When the
      remount itself failed, the map also carries `remount_error: reason`.
      `reason` is `{:umount_failed, code, output}`,
      `{:resize_failed, code, output}`, `{:mount_failed, code, output}`,
      `{:fwup_failed | :dmsetup_failed, args, code, output}` or a `df` error.

  Errors are logged, never raised.
  """

  require Logger

  alias NervesDataResize.{Busy, DeviceMapper, Filesystem, Mounts}

  @type result ::
          :already_grown
          | :disabled
          | {:ok, %{before: non_neg_integer(), after: non_neg_integer()}}
          | {:error, term()}

  @doc """
  Grows the filesystem once if it is materially smaller than its device.

  Safe to call early at boot, before significant writes to the target.
  See the module documentation for options and return values.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    config = opts ++ (Application.get_env(:nerves_data_resize, :config) || [])

    if Keyword.get(config, :enabled, true) and Keyword.drop(config, [:runner, :enabled]) != [] do
      do_run(config)
    else
      :disabled
    end
  end

  # Filesystem metadata makes `df` report less than the device size even when
  # the filesystem fills it, so a small gap is never worth a resize.
  @min_grow 64 * 1024 * 1024

  defp worth_growing?(fs_bytes, device_bytes, threshold, min_grow) do
    device_bytes / max(fs_bytes, 1) >= threshold and device_bytes - fs_bytes >= min_grow
  end

  @doc false
  defdelegate parse_dm_table(out), to: DeviceMapper, as: :parse_table

  @doc false
  defdelegate grow_plan(name, table, disk_sectors), to: DeviceMapper

  defp do_run(config) do
    sys =
      Keyword.get(config, :runner) || Application.get_env(:nerves_data_resize, :runner) ||
        NervesDataResize.System.Native

    threshold = Keyword.get(config, :threshold, 1.1)
    min_grow = Keyword.get(config, :min_grow, @min_grow)
    grow = Keyword.get(config, :grow_partition)

    with {:ok, mount_point} <- Mounts.normalize(Keyword.get(config, :mount_point, "/root")),
         {:ok, ctx} <- context(sys, mount_point, config),
         ctx = Map.put(ctx, :grow, grow),
         :ok <- tools_present(ctx),
         {:ok, fs_bytes} <- fs_bytes(ctx),
         {:ok, part_bytes} <- partition_bytes(ctx),
         {:ok, dm_grow} <- plan_partition_grow(ctx),
         target_bytes = if(dm_grow, do: dm_grow.new_sectors * 512, else: part_bytes),
         true <- worth_growing?(fs_bytes, target_bytes, threshold, min_grow) || :already_grown do
      Logger.info(
        "[nerves_data_resize] growing #{ctx.type} on #{ctx.device}: " <>
          "FS=#{mb(fs_bytes)} MB, device=#{mb(target_bytes)} MB"
      )

      ctx
      |> grow_filesystem(dm_grow, fs_bytes)
      |> log_result()
    else
      :already_grown ->
        :already_grown

      {:error, _} = err ->
        Logger.warning("[nerves_data_resize] skipping: #{inspect(err)}")
        err
    end
  end

  # Resolves device, type and mount options from /proc/mounts and the config.
  defp context(sys, mount_point, config) do
    partition = Keyword.get(config, :partition)
    override = Keyword.get(config, :filesystem)
    mount_opts = Keyword.get(config, :mount_opts)

    case Mounts.read(sys) do
      {:ok, entries} ->
        case Mounts.find(entries, mount_point) do
          nil ->
            {:error, {:not_mounted, mount_point}}

          entry ->
            if partition && partition != entry.device do
              Logger.warning(
                "[nerves_data_resize] #{mount_point} is mounted from #{entry.device}, " <>
                  "resizing #{partition}"
              )
            end

            build(
              sys,
              mount_point,
              partition || entry.device,
              override || entry.type,
              mount_opts || entry.opts
            )
        end

      {:error, reason} ->
        if partition && override do
          build(sys, mount_point, partition, override, mount_opts || "nodev")
        else
          {:error, {:proc_mounts_unreadable, reason}}
        end
    end
  end

  defp build(sys, mount_point, device, type, mount_opts) do
    with {:ok, strategy} <- Filesystem.for_type(type) do
      {:ok,
       %{
         sys: sys,
         mount_point: mount_point,
         device: device,
         strategy: strategy,
         type: if(is_binary(type), do: type, else: hd(strategy.types())),
         mount_opts: mount_opts
       }}
    end
  end

  # Every external tool is checked up front: a tool found missing after the
  # unmount would leave the filesystem unmounted until the fallback remount.
  defp tools_present(ctx) do
    tools =
      ["df"] ++
        ctx.strategy.tools() ++
        if(ctx.strategy.offline?(), do: ["mount", "umount"], else: []) ++
        if(ctx.grow, do: ["fwup", "dmsetup"], else: [])

    case tools |> Enum.uniq() |> Enum.reject(&ctx.sys.find_executable/1) do
      [] -> :ok
      missing -> {:error, {:missing_tools, missing}}
    end
  end

  defp fs_bytes(ctx) do
    {program, args} = ctx.strategy.size_cmd(ctx.mount_point)

    case ctx.sys.cmd(program, args, []) do
      {out, 0} -> ctx.strategy.parse_size(out)
      {out, code} -> {:error, {:df_failed, code, out}}
    end
  end

  # sysfs covers plain block devices; device-mapper partitions have no
  # /sys/class/block entry under their mapper name, hence the blockdev fallback.
  defp partition_bytes(ctx) do
    sysfs = "/sys/class/block/" <> Path.basename(ctx.device) <> "/size"

    with {:ok, text} <- ctx.sys.read(sysfs),
         {sectors, ""} <- Integer.parse(String.trim(text)) do
      {:ok, sectors * 512}
    else
      _ -> blockdev_bytes(ctx)
    end
  end

  defp blockdev_bytes(ctx) do
    if ctx.sys.find_executable("blockdev") do
      case ctx.sys.cmd("blockdev", ["--getsize64", ctx.device], []) do
        {out, 0} ->
          case Integer.parse(String.trim(out)) do
            {n, _} -> {:ok, n}
            :error -> {:error, {:blockdev_parse, out}}
          end

        {out, code} ->
          {:error, {:blockdev_failed, code, out}}
      end
    else
      {:error, {:missing_tools, ["blockdev"]}}
    end
  end

  defp plan_partition_grow(%{grow: nil}), do: {:ok, nil}
  defp plan_partition_grow(ctx), do: DeviceMapper.plan(ctx.sys, ctx.device, ctx.grow)

  defp grow_filesystem(ctx, dm_grow, before) do
    if ctx.strategy.offline?() do
      grow_offline(ctx, dm_grow, before)
    else
      grow_online(ctx, dm_grow, before)
    end
  end

  defp grow_online(ctx, dm_grow, before) do
    with :ok <- step(:grow_partition, DeviceMapper.grow(ctx.sys, dm_grow, ctx.grow)),
         :ok <- step(:resize, resize(ctx)),
         {:ok, after_bytes} <- step(:df, fs_bytes(ctx)) do
      {:ok, %{before: before, after: after_bytes}}
    else
      {:error, step, reason} -> failure(step, reason, false, nil)
    end
  end

  defp grow_offline(ctx, dm_grow, before) do
    case Busy.holders(ctx.sys, ctx.mount_point) do
      [] -> unmount_and_grow(ctx, dm_grow, before)
      holders -> {:error, {:busy, holders}}
    end
  end

  defp unmount_and_grow(ctx, dm_grow, before) do
    case run_cmd(ctx.sys, "umount", [ctx.mount_point], :umount_failed) do
      :ok ->
        with :ok <- step(:grow_partition, DeviceMapper.grow(ctx.sys, dm_grow, ctx.grow)),
             :ok <- step(:resize, resize(ctx)) do
          remount_and_measure(ctx, before)
        else
          {:error, step, reason} ->
            case remount(ctx) do
              :ok -> failure(step, reason, true, nil)
              {:error, remount_error} -> failure(step, reason, false, remount_error)
            end
        end

      {:error, reason} ->
        failure(:umount, reason, false, nil)
    end
  end

  defp remount_and_measure(ctx, before) do
    case remount(ctx) do
      :ok ->
        case fs_bytes(ctx) do
          {:ok, after_bytes} -> {:ok, %{before: before, after: after_bytes}}
          {:error, reason} -> failure(:df, reason, true, nil)
        end

      {:error, reason} ->
        failure(:remount, reason, false, reason)
    end
  end

  defp resize(ctx) do
    ctx.strategy.resize_cmds(ctx.device, ctx.mount_point)
    |> Enum.reduce_while(:ok, fn {program, args}, :ok ->
      case run_cmd(ctx.sys, program, args, :resize_failed) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remount(ctx) do
    opts = if ctx.mount_opts in [nil, ""], do: [], else: ["-o", ctx.mount_opts]
    args = ["-t", ctx.type] ++ opts ++ [ctx.device, ctx.mount_point]
    run_cmd(ctx.sys, "mount", args, :mount_failed)
  end

  defp run_cmd(sys, program, args, tag) do
    case sys.cmd(program, args, []) do
      {_, 0} -> :ok
      {out, code} -> {:error, {tag, code, out}}
    end
  end

  defp step(_name, :ok), do: :ok
  defp step(_name, {:ok, value}), do: {:ok, value}
  defp step(name, {:error, reason}), do: {:error, name, reason}

  defp failure(step, reason, remounted?, remount_error) do
    error = %{step: step, reason: reason, remounted?: remounted?}
    {:error, if(remount_error, do: Map.put(error, :remount_error, remount_error), else: error)}
  end

  defp log_result({:ok, %{after: bytes}} = ok) do
    Logger.info("[nerves_data_resize] resize ok: FS now #{mb(bytes)} MB")
    ok
  end

  defp log_result({:error, reason} = err) do
    Logger.error("[nerves_data_resize] resize failed: #{inspect(reason)}")
    err
  end

  defp mb(bytes), do: div(bytes, 1024 * 1024)
end
