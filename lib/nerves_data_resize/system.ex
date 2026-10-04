defmodule NervesDataResize.System do
  @moduledoc """
  The only door from `NervesDataResize` to the operating system.

  Everything the library reads (`/proc`, `/sys`), lists, runs or looks up
  goes through an implementation of this behaviour. The default is
  `NervesDataResize.System.Native`; tests inject a fake with the `:runner`
  option of `NervesDataResize.run/1` (or `config :nerves_data_resize, :runner`).
  """

  @doc "Runs `program` with `args`; returns merged stdout/stderr and the exit status."
  @callback cmd(program :: String.t(), args :: [String.t()], opts :: keyword()) ::
              {String.t(), non_neg_integer()}

  @doc "Reads a file."
  @callback read(path :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc "Lists a directory."
  @callback ls(path :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc "Reads the target of a symbolic link."
  @callback read_link(path :: String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Resolves an executable on the `PATH`; `nil` when absent."
  @callback find_executable(name :: String.t()) :: String.t() | nil
end
