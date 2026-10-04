defmodule NervesDataResize.System.NativeTest do
  use ExUnit.Case, async: true

  alias NervesDataResize.{Busy, System.Native}

  test "cmd/3 runs a program and merges stderr" do
    assert {"hi\n", 0} = Native.cmd("echo", ["hi"], [])
    assert {_, code} = Native.cmd("sh", ["-c", "echo err >&2; exit 3"], [])
    assert code == 3
  end

  test "cmd/3 reports a missing program with status 127" do
    assert {out, 127} = Native.cmd("__no_such_tool__", [], [])
    assert out =~ "not found"
  end

  test "find_executable/1, read/1, ls/1 and read_link/1 reach the machine" do
    assert Native.find_executable("sh")
    assert Native.find_executable("__no_such_tool__") == nil
    assert {:ok, _} = Native.read("/proc/self/stat")
    assert {:ok, entries} = Native.ls("/proc/self/fd")
    assert is_list(entries)
    assert {:ok, _} = Native.read_link("/proc/self/cwd")
  end

  @tag :tmp_dir
  test "Busy.holders/2 finds this process holding a file and its cwd", %{tmp_dir: dir} do
    path = Path.join(dir, "held")
    File.write!(path, "x")
    {:ok, io} = File.open(path, [:read])

    holders = Busy.holders(Native, dir)
    assert Enum.any?(holders, &(&1.pid == os_pid() and &1.path == path))

    File.close(io)
    refute Enum.any?(Busy.holders(Native, dir), &(&1.pid == os_pid() and &1.path == path))
  end

  defp os_pid, do: System.pid() |> String.to_integer()
end
