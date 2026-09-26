# nerves_data_resize

> ### ⚠️ Very early work — built for a workshop, not for production
>
> This package was written for the **Goatmire Elixir workshop** on running
> Nerves on Fairphone 3 hardware. It exists for tinkering and teaching.
>
> There are no stability guarantees and APIs will change without notice.
>
> See [`nerves_ai`](https://github.com/mlainez/nerves_ai) for the full
> stack and the workshop context.

First-boot F2FS data-partition grow for devices flashed via
[fwup](https://github.com/fwup-home/fwup) (Nerves, Buildroot-fwup,
etc.).

## The problem

Some firmware images ship a small, pre-built F2FS filesystem inside a
much larger data partition. The Fairphone 3 system, for example, writes
a 256 MB filesystem into a 51 GB partition. fwup grows the partition
entry (`expand = true`), but the filesystem inside stays at its original
size and the rest of the disk is wasted.

At boot this library compares the filesystem size with the partition
size. If the filesystem is materially smaller, it unmounts it, runs
`resize.f2fs`, and remounts it. Once the filesystem fills the partition,
later boots return `:already_grown` immediately.

Official Nerves systems format the whole application partition on first
boot, so they don't need this.

## Usage

Configure once:

```elixir
# config/target.exs
config :nerves_data_resize, :config,
  partition: "/dev/mmcblk0p62p3",
  mount_point: "/root",
  mount_opts: "nodev",
  threshold: 1.1   # skip if partition ≤ FS × 1.1
```

Then call once at app start, before anything writes to the partition
(`nerves_ai` does this for you):

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    _ = NervesDataResize.run()
    Supervisor.start_link(children(), strategy: :one_for_one)
  end
end
```

Or skip the config entirely and pass keys directly:

```elixir
NervesDataResize.run(partition: "/dev/mmcblk0p1", mount_point: "/data")
```

## What it returns

- `:already_grown` — FS already fills the partition
- `:disabled` — no partition specified
- `{:ok, %{before: bytes, after: bytes}}` — actually grew the FS
- `{:error, reason}` — failed (logged but not raised — the BEAM
  keeps running)

## Requirements

The firmware image must provide `df`, `mount`, `umount` and `resize.f2fs`
(from f2fs-tools) on the `PATH`. If any of them is missing, `run/1`
returns `{:error, {:missing_tools, names}}` before touching the
partition. The partition size is read from `/sys/class/block/<dev>/size`,
falling back to `blockdev --getsize64` for device-mapper partitions.

## Toolchain

Built and tested with Erlang/OTP 29.1.1 and Elixir 1.20.4, matching the
official Nerves systems (see `.tool-versions`).

## License

Apache-2.0.
