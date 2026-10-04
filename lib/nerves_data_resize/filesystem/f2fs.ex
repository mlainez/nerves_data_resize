defmodule NervesDataResize.Filesystem.F2fs do
  @moduledoc """
  F2FS via `resize.f2fs` (f2fs-tools). F2FS cannot be grown while mounted,
  so the filesystem is unmounted, grown and mounted again.
  """

  use NervesDataResize.Filesystem

  @impl true
  def types, do: ["f2fs"]

  @impl true
  def tools, do: ["resize.f2fs"]

  @impl true
  def offline?, do: true

  @impl true
  def resize_cmds(device, _mount_point), do: [{"resize.f2fs", [device]}]
end
