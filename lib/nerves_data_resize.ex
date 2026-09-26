defmodule NervesDataResize do
  @moduledoc """
  First-boot expansion of the F2FS application data partition.

  Some firmware images (such as the Fairphone 3 system) ship a small,
  pre-built F2FS inside a much bigger data partition. fwup grows the
  *partition* via `expand = true`, but the F2FS inside stays at its
  original size, so `df` reports the small size and the rest of the
  disk is wasted.

  This module compares filesystem size vs partition size at app
  start. If the FS is materially smaller, it:

    1. Unmounts the target.
    2. Runs `resize.f2fs` to grow the FS to the partition size.
    3. Remounts the target.

  All while the BEAM keeps running (it lives on `/srv/erlang` on
  squashfs, not on the target partition). Anything that wrote to
  the target before this ran stays in place; the resize preserves data.

  The resize is idempotent — once the FS fills the partition,
  subsequent boots short-circuit.

  ## Configuration

  Either at app-config time:

      config :nerves_data_resize, :config,
        partition: "/dev/mmcblk0p62p3",
        mount_point: "/root",
        mount_opts: "nodev",
        # Skip resize when partition <= fs * threshold (default 1.1).
        # Avoids no-op resizes for negligible differences.
        threshold: 1.1

  …or pass the same keys directly to `run/1`:

      NervesDataResize.run(partition: "/dev/mmcblk0p62p3")

  Empty config (no `:partition` key) disables the resizer.

  ## Requirements

  The firmware image must provide `df`, `mount`, `umount` and
  `resize.f2fs` (from f2fs-tools) on the `PATH`. If any is missing,
  `run/1` returns `{:error, {:missing_tools, names}}` before touching
  the partition. Official Nerves systems format the whole application
  partition at first boot, so this is only needed on images that ship a
  pre-built, smaller F2FS filesystem (such as the Fairphone 3 system).
  """

  require Logger

  @doc """
  Run the resize check + grow once. Safe to call at any boot point
  before significant writes to the target partition. Returns one of:

    * `:already_grown` — FS already fills the partition
    * `:disabled` — no config / no partition specified
    * `{:ok, %{before: bytes, after: bytes}}` — grew the FS
    * `{:error, reason}` — failed (logged but not raised)
  """
  @spec run(keyword()) ::
          :already_grown
          | :disabled
          | {:ok, %{before: non_neg_integer(), after: non_neg_integer()}}
          | {:error, term()}
  def run(opts \\ []) do
    config = opts ++ (Application.get_env(:nerves_data_resize, :config) || [])

    partition = Keyword.get(config, :partition)
    mount_point = Keyword.get(config, :mount_point, "/root")
    mount_opts = Keyword.get(config, :mount_opts, "nodev")
    threshold = Keyword.get(config, :threshold, 1.1)

    if partition == nil do
      :disabled
    else
      do_resize(partition, mount_point, mount_opts, threshold)
    end
  end

  defp do_resize(partition, mount_point, mount_opts, threshold) do
    with :ok <- tools_present(),
         {:ok, fs_bytes} <- fs_bytes(mount_point),
         {:ok, part_bytes} <- partition_bytes(partition),
         true <- part_bytes / max(fs_bytes, 1) >= threshold || :already_grown do
      Logger.info(
        "[nerves_data_resize] resizing #{partition}: FS=#{mb(fs_bytes)} MB → partition=#{mb(part_bytes)} MB"
      )

      with :ok <- unmount(mount_point),
           :ok <- resize_f2fs(partition),
           :ok <- mount_f2fs(partition, mount_point, mount_opts),
           {:ok, after_bytes} <- fs_bytes(mount_point) do
        Logger.info("[nerves_data_resize] resize ok: FS now #{mb(after_bytes)} MB")
        {:ok, %{before: fs_bytes, after: after_bytes}}
      else
        {:error, reason} = err ->
          Logger.error("[nerves_data_resize] resize failed at step: #{inspect(reason)}; attempting remount")
          _ = mount_f2fs(partition, mount_point, mount_opts)
          err
      end
    else
      :already_grown ->
        :already_grown

      {:error, _} = err ->
        Logger.warning("[nerves_data_resize] storage resizer skipping: #{inspect(err)}")
        err
    end
  end

  # Check every external tool up front: failing after the unmount would
  # leave the data partition unmounted until the fallback remount.
  @tools ~w(df umount mount resize.f2fs)
  defp tools_present do
    case Enum.reject(@tools, &System.find_executable/1) do
      [] -> :ok
      missing -> {:error, {:missing_tools, missing}}
    end
  end

  defp fs_bytes(mount_point) do
    case File.stat(mount_point) do
      {:ok, _} ->
        # Use POSIX -P + -k flags; works on busybox and full coreutils.
        case System.cmd("df", ["-P", "-k", mount_point], stderr_to_stdout: true) do
          {out, 0} ->
            with [_header, data | _] <- out |> String.trim() |> String.split("\n"),
                 [_fs, size_kb | _] <- data |> String.split(~r/\s+/, trim: true),
                 {kb, ""} <- Integer.parse(size_kb) do
              {:ok, kb * 1024}
            else
              other -> {:error, {:df_parse, other}}
            end

          {out, code} ->
            {:error, {:df_failed, code, out}}
        end

      _ ->
        {:error, :mount_point_missing}
    end
  end

  defp partition_bytes(partition) do
    # sysfs path works for plain block devices; for kpartx /
    # device-mapper subpartitions on Nerves boards (e.g. FP3 where
    # the userdata partition is split via dm into p62p1..p62p3) we
    # have to fall back to `blockdev --getsize64`.
    sysfs_size = "/sys/class/block/" <> Path.basename(partition) <> "/size"

    case File.read(sysfs_size) do
      {:ok, blocks_str} ->
        blocks = blocks_str |> String.trim() |> String.to_integer()
        {:ok, blocks * 512}

      {:error, _} ->
        case System.cmd("blockdev", ["--getsize64", partition], stderr_to_stdout: true) do
          {out, 0} ->
            case Integer.parse(String.trim(out)) do
              {n, _} -> {:ok, n}
              :error -> {:error, {:blockdev_parse, out}}
            end

          {out, code} ->
            {:error, {:blockdev_failed, code, out}}
        end
    end
  end

  defp unmount(mount_point) do
    case System.cmd("umount", [mount_point], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:umount_failed, code, out}}
    end
  end

  defp resize_f2fs(partition) do
    case System.cmd("resize.f2fs", [partition], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:resize_failed, code, out}}
    end
  end

  defp mount_f2fs(partition, mount_point, opts) do
    case System.cmd("mount", ["-t", "f2fs", "-o", opts, partition, mount_point],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {out, code} -> {:error, {:mount_failed, code, out}}
    end
  end

  defp mb(bytes), do: div(bytes, 1024 * 1024)
end
