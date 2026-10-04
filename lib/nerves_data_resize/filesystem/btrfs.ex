defmodule NervesDataResize.Filesystem.Btrfs do
  @moduledoc "Btrfs via `btrfs filesystem resize max`, grown online while mounted."

  use NervesDataResize.Filesystem

  @impl true
  def types, do: ["btrfs"]

  @impl true
  def tools, do: ["btrfs"]

  @impl true
  def offline?, do: false

  @impl true
  def resize_cmds(_device, mount_point),
    do: [{"btrfs", ["filesystem", "resize", "max", mount_point]}]
end
