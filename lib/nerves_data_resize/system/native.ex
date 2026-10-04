defmodule NervesDataResize.System.Native do
  @moduledoc "The real `NervesDataResize.System`: files, processes and the `PATH` of this machine."

  @behaviour NervesDataResize.System

  @impl true
  def cmd(program, args, opts) do
    opts = Keyword.put_new(opts, :stderr_to_stdout, true)

    case System.find_executable(program) do
      nil -> {"#{program}: command not found", 127}
      path -> System.cmd(path, args, opts)
    end
  rescue
    e in ErlangError -> {"#{program}: #{Exception.message(e)}", 126}
  end

  @impl true
  def read(path), do: File.read(path)

  @impl true
  def ls(path), do: File.ls(path)

  @impl true
  def read_link(path), do: File.read_link(path)

  @impl true
  def find_executable(name), do: System.find_executable(name)
end
