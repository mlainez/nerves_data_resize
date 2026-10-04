defmodule NervesDataResize.FilesystemTest do
  use ExUnit.Case, async: true

  alias NervesDataResize.Filesystem
  alias NervesDataResize.Filesystem.{Ext4, F2fs}
  alias NervesDataResize.Mounts

  describe "strategies" do
    test "ext4 grows online with resize2fs on the device" do
      assert Ext4.types() == ["ext4", "ext3", "ext2"]
      assert Ext4.tools() == ["resize2fs"]
      refute Ext4.offline?()
      assert Ext4.resize_cmds("/dev/sda1", "/data") == [{"resize2fs", ["/dev/sda1"]}]
    end

    test "f2fs is offline and uses resize.f2fs on the device" do
      assert F2fs.types() == ["f2fs"]
      assert F2fs.tools() == ["resize.f2fs"]
      assert F2fs.offline?()
      assert F2fs.resize_cmds("/dev/sda1", "/data") == [{"resize.f2fs", ["/dev/sda1"]}]
    end

    test "all strategies read the size with POSIX df" do
      for mod <- [Ext4, F2fs] do
        assert mod.size_cmd("/data") == {"df", ["-P", "-k", "/data"]}
      end
    end

    test "parse_size reads the size column of df -P -k in bytes" do
      out = """
      Filesystem     1024-blocks   Used Available Capacity Mounted on
      /dev/sda1            65536   1024     64512       2% /data
      """

      assert Ext4.parse_size(out) == {:ok, 65_536 * 1024}
    end

    test "parse_size rejects anything else" do
      assert {:error, {:df_parse, _}} = Ext4.parse_size("garbage")
      assert {:error, {:df_parse, _}} = Ext4.parse_size("h\n/dev/sda1 abc")
    end
  end

  describe "for_type/1" do
    test "maps filesystem types to strategies" do
      assert Filesystem.for_type("ext4") == {:ok, Ext4}
      assert Filesystem.for_type("ext3") == {:ok, Ext4}
      assert Filesystem.for_type("ext2") == {:ok, Ext4}
      assert Filesystem.for_type("f2fs") == {:ok, F2fs}
    end

    test "accepts atoms and strategy modules" do
      assert Filesystem.for_type(:f2fs) == {:ok, F2fs}
      assert Filesystem.for_type(Ext4) == {:ok, Ext4}
    end

    test "rejects unsupported types" do
      assert Filesystem.for_type("vfat") == {:error, {:unsupported_filesystem, "vfat"}}
      assert Filesystem.for_type(:ntfs) == {:error, {:unsupported_filesystem, "ntfs"}}
      assert Filesystem.for_type(42) == {:error, {:unsupported_filesystem, 42}}
    end
  end

  describe "Mounts" do
    test "parses /proc/mounts and decodes escapes" do
      text = """
      /dev/root / ext4 rw,relatime 0 0
      /dev/sda1 /my\\040data f2fs rw,nodev 0 0
      broken
      """

      assert Mounts.parse(text) == [
               %{device: "/dev/root", mount_point: "/", type: "ext4", opts: "rw,relatime"},
               %{device: "/dev/sda1", mount_point: "/my data", type: "f2fs", opts: "rw,nodev"}
             ]
    end

    test "find/2 returns the last mount at a path" do
      entries = Mounts.parse("/dev/a /m ext4 rw 0 0\n/dev/b /m f2fs rw 0 0\n")
      assert %{device: "/dev/b"} = Mounts.find(entries, "/m")
      assert Mounts.find(entries, "/other") == nil
    end

    test "normalize/1 cleans paths and refuses /" do
      assert Mounts.normalize("/data/") == {:ok, "/data"}
      assert Mounts.normalize("/") == {:error, {:refused_mount_point, "/"}}
      assert Mounts.normalize("/data/..") == {:error, {:refused_mount_point, "/"}}
      assert Mounts.normalize(nil) == {:error, {:invalid_mount_point, nil}}
    end
  end
end
