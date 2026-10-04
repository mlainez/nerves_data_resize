defmodule NervesDataResizeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NervesDataResize.FakeSystem, as: Fake

  @mb 1024 * 1024

  setup do
    Application.delete_env(:nerves_data_resize, :config)
    Application.delete_env(:nerves_data_resize, :runner)

    on_exit(fn ->
      Fake.stop()
      Application.delete_env(:nerves_data_resize, :config)
      Application.delete_env(:nerves_data_resize, :runner)
    end)

    :ok
  end

  defp run(fake_opts, run_opts \\ []) do
    Fake.start(fake_opts)
    opts = Keyword.merge([runner: Fake, mount_point: "/data"], run_opts)
    capture_log(fn -> send(self(), {:result, NervesDataResize.run(opts)}) end)
    assert_received {:result, result}
    result
  end

  defp touched?,
    do: Fake.calls() |> Enum.any?(&String.starts_with?(&1, ~w(umount resize mount)))

  describe "configuration" do
    test "returns :disabled without configuration" do
      assert :disabled = NervesDataResize.run()
    end

    test "returns :disabled when only a runner is given" do
      assert :disabled = NervesDataResize.run(runner: Fake)
    end

    test "returns :disabled when explicitly disabled" do
      Application.put_env(:nerves_data_resize, :config, mount_point: "/data", enabled: false)
      assert :disabled = NervesDataResize.run()
    end

    test "reads app config and the app-env runner" do
      Fake.start()
      Application.put_env(:nerves_data_resize, :config, mount_point: "/data")
      Application.put_env(:nerves_data_resize, :runner, Fake)
      capture_log(fn -> send(self(), {:result, NervesDataResize.run()}) end)
      assert_received {:result, {:ok, _}}
    end

    test "options override app config" do
      Fake.start()
      Application.put_env(:nerves_data_resize, :config, mount_point: "/nowhere", runner: Fake)
      capture_log(fn -> send(self(), {:result, NervesDataResize.run(mount_point: "/data")}) end)
      assert_received {:result, {:ok, _}}
    end
  end

  describe "ext4 (online)" do
    test "grows without unmounting" do
      assert {:ok, %{before: 67_108_864, after: 536_870_912}} = run(type: "ext4")

      assert Fake.calls() == [
               "df -P -k /data",
               "resize2fs /dev/mmcblk0p3",
               "df -P -k /data"
             ]
    end

    test "never unmounts even when files are open under the mount" do
      files = [%{pid: 7, name: "app", path: "/data/log", kind: :fd}]
      assert {:ok, _} = run(open_files: files)
      assert Fake.calls("umount") == []
      assert Fake.state().mounted?
    end

    test "resize failure is reported without remount" do
      fail = %{"resize2fs" => {"resize2fs: bad superblock", 1}}

      assert {:error,
              %{
                step: :resize,
                reason: {:resize_failed, 1, "resize2fs: bad superblock"},
                remounted?: false
              }} = run(fail: fail)

      assert Fake.calls("umount") == [] and Fake.calls("mount") == []
    end

    test "ext2 and ext3 use the same strategy" do
      for type <- ~w(ext2 ext3) do
        Fake.stop()
        assert {:ok, _} = run(type: type)
        assert "resize2fs /dev/mmcblk0p3" in Fake.calls()
      end
    end
  end

  describe "f2fs (offline)" do
    test "unmounts, resizes, remounts with the mount options in use" do
      assert {:ok, %{before: 67_108_864, after: 536_870_912}} =
               run(type: "f2fs", mount_opts: "rw,nodev,noatime")

      assert Fake.calls() == [
               "df -P -k /data",
               "umount /data",
               "resize.f2fs /dev/mmcblk0p3",
               "mount -t f2fs -o rw,nodev,noatime /dev/mmcblk0p3 /data",
               "df -P -k /data"
             ]
    end

    test "umount failure leaves the filesystem mounted and skips the resize" do
      fail = %{"umount" => {"target is busy", 32}}

      assert {:error,
              %{step: :umount, reason: {:umount_failed, 32, "target is busy"}, remounted?: false}} =
               run(type: "f2fs", fail: fail)

      assert Fake.calls("resize.f2fs") == []
      assert Fake.calls("mount") == []
      assert Fake.state().mounted?
    end

    test "resize failure remounts and returns the original error" do
      fail = %{"resize.f2fs" => {"Error: superblock", 255}}

      assert {:error,
              %{
                step: :resize,
                reason: {:resize_failed, 255, "Error: superblock"},
                remounted?: true
              } = error} = run(type: "f2fs", fail: fail)

      refute Map.has_key?(error, :remount_error)
      assert Fake.state().mounted?
      assert List.last(Fake.calls("mount")) =~ "mount -t f2fs -o rw,relatime /dev/mmcblk0p3 /data"
    end

    test "resize failure followed by remount failure reports both" do
      fail = %{"resize.f2fs" => {"nope", 255}, "mount" => {"mount: wrong fs type", 32}}

      assert {:error,
              %{
                step: :resize,
                reason: {:resize_failed, 255, "nope"},
                remounted?: false,
                remount_error: {:mount_failed, 32, "mount: wrong fs type"}
              }} = run(type: "f2fs", fail: fail)

      refute Fake.state().mounted?
    end

    test "remount failure after a successful resize" do
      fail = %{"mount" => {"mount: failed", 32}}

      assert {:error,
              %{
                step: :remount,
                reason: {:mount_failed, 32, "mount: failed"},
                remounted?: false,
                remount_error: {:mount_failed, 32, "mount: failed"}
              }} = run(type: "f2fs", fail: fail)
    end

    test "df failure after the remount is reported with the filesystem mounted" do
      assert {:error, %{step: :df, reason: {:df_failed, 1, "df: gone"}, remounted?: true}} =
               run(type: "f2fs", df_fail_after: 1)

      assert Fake.state().mounted?
    end
  end

  describe "busy mounts" do
    @holders [
      %{pid: 321, name: "beam.smp", path: "/data/.erlang/shell_history/log", kind: :fd},
      %{pid: 400, name: "sh", path: "/data/work", kind: :cwd},
      %{pid: 500, name: "other", path: "/database/x", kind: :fd}
    ]

    test "refuses to unmount and reports the holders" do
      assert {:error, {:busy, holders}} = run(type: "f2fs", open_files: @holders)

      assert holders == [
               %{pid: 321, name: "beam.smp", path: "/data/.erlang/shell_history/log"},
               %{pid: 400, name: "sh", path: "/data/work"}
             ]

      assert Fake.calls("umount") == []
      assert Fake.state().mounted?
    end

    test "ignores files on other paths that merely share the prefix" do
      other = [%{pid: 500, name: "other", path: "/database/x", kind: :fd}]
      assert {:ok, _} = run(type: "f2fs", open_files: other)
    end
  end

  describe "safety checks" do
    test "refuses the root mount point and touches nothing" do
      Fake.start()

      assert {:error, {:refused_mount_point, "/"}} =
               NervesDataResize.run(runner: Fake, mount_point: "/")

      assert Fake.calls() == []
    end

    test "refuses a path that is not a mount" do
      assert {:error, {:not_mounted, "/elsewhere"}} = run([], mount_point: "/elsewhere")
      refute touched?()
    end

    test "refuses a filesystem that is not mounted any more" do
      assert {:error, {:not_mounted, "/data"}} = run(mounted?: false)
    end

    test "rejects an invalid mount point" do
      Fake.start()

      assert {:error, {:invalid_mount_point, 42}} =
               NervesDataResize.run(runner: Fake, mount_point: 42)
    end

    test "unsupported filesystem types fail before anything runs" do
      assert {:error, {:unsupported_filesystem, "vfat"}} = run(type: "vfat")
      assert Fake.calls() == []
    end

    test "unsupported filesystem override" do
      assert {:error, {:unsupported_filesystem, "ntfs"}} = run([], filesystem: "ntfs")
      assert Fake.calls() == []
    end
  end

  describe "missing tools" do
    test "names every missing tool and touches nothing" do
      for {type, missing} <- [
            {"ext4", ["resize2fs"]},
            {"f2fs", ["resize.f2fs", "umount", "mount"]},
            {"ext4", ["df"]}
          ] do
        Fake.stop()
        expected = Enum.sort(missing)

        assert {:error, {:missing_tools, names}} = run(type: type, missing: missing)
        assert Enum.sort(names) == expected
        assert Fake.calls() == []
      end
    end

    test "fwup and dmsetup are required with :grow_partition" do
      grow = [disk: "/dev/mmcblk0", ops_fw: "/ops.fw", task: "grow"]

      assert {:error, {:missing_tools, ["fwup", "dmsetup"]}} =
               run([missing: ["fwup", "dmsetup"]], grow_partition: grow)

      assert Fake.calls() == []
    end

    test "blockdev is required when sysfs has no size" do
      assert {:error, {:missing_tools, ["blockdev"]}} = run(sysfs?: false, missing: ["blockdev"])
    end
  end

  describe "size reading" do
    test "df output that cannot be parsed" do
      assert {:error, {:df_parse, _}} = run(fail: %{"df" => {"garbage", 0}})
      refute touched?()
    end

    test "df failure" do
      assert {:error, {:df_failed, 1, "no"}} = run(fail: %{"df" => {"no", 1}})
      refute touched?()
    end

    test "falls back to blockdev when sysfs has no size" do
      assert {:ok, %{after: 536_870_912}} = run(sysfs?: false)
      assert "blockdev --getsize64 /dev/mmcblk0p3" in Fake.calls()
    end

    test "blockdev failure" do
      fail = %{"blockdev" => {"blockdev: nope", 1}}
      assert {:error, {:blockdev_failed, 1, _}} = run(sysfs?: false, fail: fail)
    end

    test "blockdev output that cannot be parsed" do
      fail = %{"blockdev" => {"x", 0}}
      assert {:error, {:blockdev_parse, "x"}} = run(sysfs?: false, fail: fail)
    end
  end

  describe "threshold and idempotency" do
    test "does nothing when the filesystem fills the partition within the threshold" do
      assert :already_grown = run(fs_bytes: 500 * @mb, part_bytes: 512 * @mb)
      refute touched?()
    end

    test "threshold is configurable" do
      assert :already_grown = run([fs_bytes: 100 * @mb, part_bytes: 512 * @mb], threshold: 6)
      Fake.stop()
      assert {:ok, _} = run([fs_bytes: 100 * @mb, part_bytes: 512 * @mb], threshold: 5)
    end

    test "a small gap is never worth a resize, even above the ratio threshold" do
      # 233 of 256 MB is what df reports for a fully grown small ext4
      assert :already_grown = run(fs_bytes: 200 * @mb, part_bytes: 256 * @mb, threshold: 1.1)
      refute touched?()
    end

    test "min_grow is configurable" do
      assert :already_grown =
               run([fs_bytes: 200 * @mb, part_bytes: 256 * @mb], min_grow: 100 * @mb)

      Fake.stop()
      assert {:ok, _} = run([fs_bytes: 200 * @mb, part_bytes: 256 * @mb], min_grow: 0)
    end

    test "a second run is :already_grown for every filesystem" do
      for type <- ~w(ext4 f2fs) do
        Fake.stop()
        Fake.start(type: type)
        opts = [runner: Fake, mount_point: "/data"]

        capture_log(fn ->
          send(self(), {:first, NervesDataResize.run(opts)})
          send(self(), {:second, NervesDataResize.run(opts)})
        end)

        assert_received {:first, {:ok, _}}
        assert_received {:second, :already_grown}
      end
    end
  end

  describe "auto-detection" do
    test "takes the device from /proc/mounts" do
      assert {:ok, _} = run(device: "/dev/nvme0n1p4", type: "ext4")
      assert "resize2fs /dev/nvme0n1p4" in Fake.calls()
    end

    test "an explicit partition wins" do
      assert {:ok, _} = run([device: "/dev/sda1"], partition: "/dev/sda1")
      assert "resize2fs /dev/sda1" in Fake.calls()
    end

    test "decodes escaped characters in /proc/mounts" do
      assert {:ok, _} = run([mount_point: "/my data"], mount_point: "/my data")
      assert "df -P -k /my data" in Fake.calls()
    end

    test "the filesystem type override replaces the detected type" do
      assert {:ok, _} = run([type: "vfat"], filesystem: :ext4)
      assert "resize2fs /dev/mmcblk0p3" in Fake.calls()
    end

    test "a strategy module can be given as the override" do
      assert {:ok, _} = run([type: "vfat"], filesystem: NervesDataResize.Filesystem.Ext4)
      assert "resize2fs /dev/mmcblk0p3" in Fake.calls()
    end
  end

  describe "mount options" do
    test "reuses the options found in /proc/mounts" do
      assert {:ok, _} = run(type: "f2fs", mount_opts: "rw,noatime,background_gc=on")
      assert "mount -t f2fs -o rw,noatime,background_gc=on /dev/mmcblk0p3 /data" in Fake.calls()
    end

    test ":mount_opts overrides them" do
      assert {:ok, _} = run([type: "f2fs"], mount_opts: "nodev")
      assert "mount -t f2fs -o nodev /dev/mmcblk0p3 /data" in Fake.calls()
    end

    test "falls back to nodev when /proc/mounts is unreadable" do
      assert {:ok, _} =
               run([type: "f2fs", proc_mounts: :unreadable],
                 partition: "/dev/mmcblk0p3",
                 filesystem: :f2fs
               )

      assert "mount -t f2fs -o nodev /dev/mmcblk0p3 /data" in Fake.calls()
    end

    test "an unreadable /proc/mounts without partition and filesystem is an error" do
      assert {:error, {:proc_mounts_unreadable, :enoent}} = run(proc_mounts: :unreadable)
      assert Fake.calls() == []
    end
  end

  describe "device-mapper partition growth" do
    @table "0 524288 linear 259:30 1435664\n"

    defp dm_opts(extra) do
      Keyword.merge(
        [
          device: "/dev/mmcblk0p62p3",
          fs_bytes: 524_288 * 512,
          part_bytes: 524_288 * 512,
          disk: "mmcblk0p62",
          disk_sectors: 102_217_679,
          dm_table: @table
        ],
        extra
      )
    end

    @grow [disk: "/dev/mmcblk0p62", ops_fw: "/usr/share/fwup/ops.fw", task: "grow-app"]

    test "grows the partition with fwup and dmsetup, then the filesystem (offline)" do
      assert {:ok, %{before: 268_435_456, after: after_bytes}} =
               run(dm_opts(type: "f2fs"), grow_partition: @grow)

      assert after_bytes == div(100_782_015 * 512, 1024) * 1024

      assert Fake.calls() == [
               "df -P -k /data",
               "dmsetup table mmcblk0p62p3",
               "umount /data",
               "fwup -a -d /dev/mmcblk0p62 -t grow-app -i /usr/share/fwup/ops.fw",
               "dmsetup suspend mmcblk0p62p3",
               "dmsetup reload mmcblk0p62p3 --table 0 100782015 linear 259:30 1435664",
               "dmsetup resume mmcblk0p62p3",
               "resize.f2fs /dev/mmcblk0p62p3",
               "mount -t f2fs -o rw,relatime /dev/mmcblk0p62p3 /data",
               "df -P -k /data"
             ]
    end

    test "is idempotent: the second run is :already_grown" do
      assert {:ok, _} = run(dm_opts(type: "f2fs"), grow_partition: @grow)

      capture_log(fn ->
        send(
          self(),
          {:again,
           NervesDataResize.run(runner: Fake, mount_point: "/data", grow_partition: @grow)}
        )
      end)

      assert_received {:again, :already_grown}
    end

    test "online filesystems keep their mount while the partition grows" do
      assert {:ok, _} = run(dm_opts(type: "ext4"), grow_partition: @grow)
      assert Fake.calls("umount") == []
      assert Enum.any?(Fake.calls(), &(&1 =~ "dmsetup reload"))
    end

    test "a partition that already reaches its disk is not touched" do
      opts = dm_opts(type: "f2fs", disk_sectors: 524_288 + 1_435_664)
      assert :already_grown = run(opts, grow_partition: @grow)
      assert Fake.calls("fwup") == []
    end

    test "fwup failure remounts an offline filesystem" do
      fail = %{"fwup" => {"fwup: bad task", 1}}

      assert {:error,
              %{
                step: :grow_partition,
                reason: {:fwup_failed, _args, 1, "fwup: bad task"},
                remounted?: true
              }} = run(dm_opts(type: "f2fs", fail: fail), grow_partition: @grow)

      assert Fake.calls("resize.f2fs") == []
      assert Fake.state().mounted?
    end

    test "dmsetup reload failure is reported" do
      fail = %{{"dmsetup", "reload"} => {"device busy", 1}}

      assert {:error, %{step: :grow_partition, reason: {:dmsetup_failed, _, 1, "device busy"}}} =
               run(dm_opts(type: "f2fs", fail: fail), grow_partition: @grow)
    end

    test "dmsetup table failure aborts before anything is touched" do
      fail = %{{"dmsetup", "table"} => {"no such device", 1}}

      assert {:error, {:dmsetup_table_failed, 1, "no such device"}} =
               run(dm_opts(type: "f2fs", fail: fail), grow_partition: @grow)

      assert Fake.calls("umount") == []
    end

    test "missing disk size aborts" do
      assert {:error, {:no_disk_size, "/dev/mmcblk0p62", :enoent}} =
               run(dm_opts(type: "f2fs", disk_sectors: nil), grow_partition: @grow)
    end

    test "an unsupported table aborts" do
      assert {:error, {:unsupported_dm_table, _}} =
               run(dm_opts(dm_table: "0 100 striped 2 64 8:0 0 8:16 0"), grow_partition: @grow)
    end
  end

  describe "dm table helpers" do
    test "parse_dm_table/1 reads a single linear target" do
      assert NervesDataResize.parse_dm_table("0 524288 linear 259:30 1435664\n") ==
               {:ok, %{sectors: 524_288, device: "259:30", start: 1_435_664}}

      assert {:error, {:unsupported_dm_table, _}} =
               NervesDataResize.parse_dm_table("0 100 striped 2 64 8:0 0 8:16 0")
    end

    test "grow_plan/3 grows a partition that ends before its disk" do
      table = %{sectors: 524_288, device: "259:30", start: 1_435_664}

      assert NervesDataResize.grow_plan("p3", table, 102_217_679) ==
               %{name: "p3", device: "259:30", start: 1_435_664, new_sectors: 100_782_015}
    end

    test "grow_plan/3 leaves a partition that already reaches its disk" do
      table = %{sectors: 100_782_015, device: "259:30", start: 1_435_664}
      assert NervesDataResize.grow_plan("p3", table, 102_217_679) == nil
    end

    test "grow_plan/3 ignores growth under 1 MiB" do
      table = %{sectors: 100_000, device: "259:30", start: 0}
      assert NervesDataResize.grow_plan("p3", table, 101_000) == nil
    end
  end
end
