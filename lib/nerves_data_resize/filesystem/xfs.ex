defmodule NervesDataResize.Filesystem.Xfs do
  @moduledoc "XFS via `xfs_growfs`, grown online while mounted."

  use NervesDataResize.Filesystem

  @impl true
  def types, do: ["xfs"]

  @impl true
  def tools, do: ["xfs_growfs"]

  @impl true
  def offline?, do: false

  @impl true
  def resize_cmds(_device, mount_point), do: [{"xfs_growfs", [mount_point]}]
end
