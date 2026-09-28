defmodule FwupDataResizeTest do
  use ExUnit.Case, async: false

  setup do
    on_exit(fn -> Application.delete_env(:nerves_data_resize, :config) end)
    :ok
  end

  test "run/1 returns :disabled when no partition configured" do
    Application.delete_env(:nerves_data_resize, :config)
    assert :disabled = NervesDataResize.run()
  end

  test "run/1 returns :disabled when config :partition is nil" do
    Application.put_env(:nerves_data_resize, :config, mount_point: "/root")
    assert :disabled = NervesDataResize.run()
  end

  test "run/1 accepts options as keyword args (overrides config)" do
    # No :partition in app config; pass directly. Without a real
    # block device the call returns an error tuple rather than
    # :disabled — exactly what we want to assert (it tried).
    Application.delete_env(:nerves_data_resize, :config)
    result = NervesDataResize.run(partition: "/dev/__does_not_exist", mount_point: "/tmp")
    assert match?({:error, _}, result) or match?(:already_grown, result)
  end

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
end
