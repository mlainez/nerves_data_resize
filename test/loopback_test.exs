defmodule NervesDataResize.LoopbackTest do
  @moduledoc """
  Grows real filesystems on loop devices. Needs root, loop devices and the
  filesystem tools, so it only runs with `mix test --only loopback`, for
  example in a throwaway privileged container.
  """

  use ExUnit.Case, async: false

  @moduletag :loopback
  @moduletag timeout: 120_000

  @mb 1024 * 1024

  # {type, mkfs command, size when formatted (MB), size of the device (MB)}
  @cases [
    {"ext4", ["mkfs.ext4", "-q"], 64, 256},
    {"f2fs", ["mkfs.f2fs", "-q"], 256, 1024},
    {"btrfs", ["mkfs.btrfs", "-q"], 128, 512},
    {"xfs", ["mkfs.xfs", "-q"], 300, 1024}
  ]

  for {type, mkfs, small, large} <- @cases do
    test "grows #{type} on a loop device and stays idempotent" do
      grow_and_verify(unquote(type), unquote(mkfs), unquote(small), unquote(large))
    end
  end

  test "refuses to unmount a busy f2fs and leaves it mounted" do
    mount_point = provision("f2fs", ["mkfs.f2fs", "-q"], 256, 1024)
    file = Path.join(mount_point, "held.bin")
    File.write!(file, "data")
    held = File.open!(file, [:read])

    assert {:error, {:busy, holders}} = NervesDataResize.run(mount_point: mount_point)
    assert Enum.any?(holders, &(&1.path == file))
    assert File.read!(file) == "data"
    File.close(held)

    assert {:ok, _} = NervesDataResize.run(mount_point: mount_point)
  end

  defp grow_and_verify(type, mkfs, small_mb, large_mb) do
    mount_point = provision(type, mkfs, small_mb, large_mb)

    payload = :crypto.strong_rand_bytes(4 * @mb)
    file = Path.join(mount_point, "payload.bin")
    File.write!(file, payload)
    sh!("sync", [])
    hash = :crypto.hash(:sha256, payload)

    # An open descriptor survives only if an online filesystem is never unmounted.
    held = if type == "f2fs", do: nil, else: File.open!(file, [:read])

    before_kb = df_kb(mount_point)
    assert before_kb * 1024 < large_mb * @mb / 2

    assert {:ok, %{before: before, after: after_bytes}} =
             NervesDataResize.run(mount_point: mount_point)

    assert before == before_kb * 1024
    assert after_bytes > before * 2
    assert df_kb(mount_point) * 1024 == after_bytes
    assert after_bytes > large_mb * @mb * 0.8

    if held do
      assert IO.binread(held, :eof) == payload
      File.close(held)
    end

    assert :crypto.hash(:sha256, File.read!(file)) == hash
    assert :already_grown = NervesDataResize.run(mount_point: mount_point)
  end

  # Formats a small filesystem, grows the loop device under it, mounts it and
  # returns the mount point. Everything is torn down when the test exits.
  defp provision(type, mkfs, small_mb, large_mb) do
    dir = Path.join(System.tmp_dir!(), "ndr_loop_#{type}_#{System.unique_integer([:positive])}")
    image = Path.join(dir, "disk.img")
    mount_point = Path.join(dir, "mnt")
    File.mkdir_p!(mount_point)

    sh!("truncate", ["-s", "#{small_mb}M", image])
    loop = sh!("losetup", ["-f", "--show", image]) |> String.trim()

    on_exit(fn ->
      System.cmd("umount", [mount_point], stderr_to_stdout: true)
      System.cmd("losetup", ["-d", loop], stderr_to_stdout: true)
      File.rm_rf(dir)
    end)

    [program | flags] = mkfs
    sh!(program, flags ++ [loop])

    # The filesystem keeps its small size while the device grows underneath it.
    sh!("truncate", ["-s", "#{large_mb}M", image])
    sh!("losetup", ["-c", loop])

    sh!("mount", ["-t", type, loop, mount_point])

    mount_point
  end

  defp df_kb(mount_point) do
    [_header, line] = sh!("df", ["-P", "-k", mount_point]) |> String.trim() |> String.split("\n")
    line |> String.split() |> Enum.at(1) |> String.to_integer()
  end

  defp sh!(program, args) do
    case System.cmd(program, args, stderr_to_stdout: true) do
      {out, 0} -> out
      {out, code} -> flunk("#{program} #{Enum.join(args, " ")} exited #{code}: #{out}")
    end
  end
end
