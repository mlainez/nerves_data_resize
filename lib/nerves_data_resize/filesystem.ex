defmodule NervesDataResize.Filesystem do
  @moduledoc """
  Behaviour of a per-filesystem grow strategy.

  A strategy names the `/proc/mounts` types it handles, the tools it needs,
  whether the filesystem must be unmounted to grow, and the commands that
  grow it. Reading the current size defaults to `df -P -k` (POSIX flags,
  also understood by busybox); a strategy may override `size_cmd/1` and
  `parse_size/1`.

  Built in: `NervesDataResize.Filesystem.Ext4`, and `.F2fs`, the filesystems Nerves systems use for application data.
  """

  @type command :: {program :: String.t(), args :: [String.t()]}

  @doc "Filesystem types, as written in `/proc/mounts`, handled by the strategy."
  @callback types() :: [String.t()]

  @doc "Executables the resize commands need (on top of `df`, and `mount`/`umount` when offline)."
  @callback tools() :: [String.t()]

  @doc "`true` when the filesystem must be unmounted while it grows."
  @callback offline?() :: boolean()

  @doc "Commands that grow the filesystem to fill its device."
  @callback resize_cmds(device :: String.t(), mount_point :: String.t()) :: [command()]

  @doc "Command that prints the size of the mounted filesystem."
  @callback size_cmd(mount_point :: String.t()) :: command()

  @doc "Extracts the filesystem size in bytes from the output of `size_cmd/1`."
  @callback parse_size(output :: String.t()) :: {:ok, non_neg_integer()} | {:error, term()}

  @strategies [
    NervesDataResize.Filesystem.Ext4,
    NervesDataResize.Filesystem.F2fs
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour NervesDataResize.Filesystem

      @impl true
      def size_cmd(mount_point), do: NervesDataResize.Filesystem.df_cmd(mount_point)

      @impl true
      def parse_size(output), do: NervesDataResize.Filesystem.parse_df(output)

      defoverridable size_cmd: 1, parse_size: 1
    end
  end

  @doc """
  Finds the strategy for a filesystem type, given as a string (`"ext4"`) or
  an atom (`:ext4`). A module implementing this behaviour is returned as is.
  """
  @spec for_type(String.t() | atom()) ::
          {:ok, module()} | {:error, {:unsupported_filesystem, term()}}
  def for_type(type) when is_atom(type) and not is_nil(type) do
    if Code.ensure_loaded?(type) and function_exported?(type, :resize_cmds, 2) do
      {:ok, type}
    else
      for_type(Atom.to_string(type))
    end
  end

  def for_type(type) when is_binary(type) do
    case Enum.find(@strategies, &(type in &1.types())) do
      nil -> {:error, {:unsupported_filesystem, type}}
      module -> {:ok, module}
    end
  end

  def for_type(other), do: {:error, {:unsupported_filesystem, other}}

  @doc false
  @spec df_cmd(String.t()) :: command()
  def df_cmd(mount_point), do: {"df", ["-P", "-k", mount_point]}

  @doc false
  @spec parse_df(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def parse_df(output) do
    with [_header, data | _] <- output |> String.trim() |> String.split("\n"),
         [_fs, size_kb | _] <- String.split(data, ~r/\s+/, trim: true),
         {kb, ""} <- Integer.parse(size_kb) do
      {:ok, kb * 1024}
    else
      other -> {:error, {:df_parse, other}}
    end
  end
end
