defmodule FwupDataResizeTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:fwup_data_resize, :config) end)
    :ok
  end

  test "run/1 returns :disabled when no partition configured" do
    Application.delete_env(:fwup_data_resize, :config)
    assert :disabled = FwupDataResize.run()
  end

  test "run/1 returns :disabled when config :partition is nil" do
    Application.put_env(:fwup_data_resize, :config, mount_point: "/root")
    assert :disabled = FwupDataResize.run()
  end

  test "run/1 accepts options as keyword args (overrides config)" do
    # No :partition in app config; pass directly. Without a real
    # block device the call returns an error tuple rather than
    # :disabled — exactly what we want to assert (it tried).
    Application.delete_env(:fwup_data_resize, :config)
    result = FwupDataResize.run(partition: "/dev/__does_not_exist", mount_point: "/tmp")
    assert match?({:error, _}, result) or match?(:already_grown, result)
  end
end
