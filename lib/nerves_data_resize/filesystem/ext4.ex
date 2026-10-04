defmodule NervesDataResize.Filesystem.Ext4 do
  @moduledoc "ext2/ext3/ext4 via `resize2fs`, grown online while mounted."

  use NervesDataResize.Filesystem

  @impl true
  def types, do: ["ext4", "ext3", "ext2"]

  @impl true
  def tools, do: ["resize2fs"]

  @impl true
  def offline?, do: false

  @impl true
  def resize_cmds(device, _mount_point), do: [{"resize2fs", [device]}]
end
