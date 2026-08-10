# nerves_data_resize

> ### ⚠️ Very early work — built for a workshop, not for production
>
> This package was written for the **Goatmire Elixir workshop** on running
> Nerves on Fairphone 3 hardware. It exists for tinkering and teaching.
>
> It is **not an actively maintained project** (yet). There are no
> stability guarantees, APIs will change without notice, and parts of it
> are wired-but-unproven. Treat it as a starting point to hack on, not as
> a dependency to build a product on.
>
> See [`nerves_ai`](https://github.com/mlainez/nerves_ai) for the full
> stack and the workshop context.

First-boot F2FS data-partition grow for devices flashed via
[fwup](https://github.com/fwup-home/fwup) (Nerves, Buildroot-fwup,
etc.).

## The problem

`fwup` ships small initial filesystems inside large raw partitions:
mkfs.f2fs writes a 256 MB FS into a 51 GB partition, and the rest
of the disk is wasted until you grow the FS. The fwup config
already expands the partition entry — but the F2FS *inside* stays
at its mkfs size.

This library fills the gap. At app boot, compare FS size vs
partition size; if the FS is materially smaller, unmount, run
`resize.f2fs`, remount. Idempotent — once the FS fills the
partition, subsequent boots short-circuit.

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

Then call once at app start:

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

## Requirements on the device

- `df` for FS size reading (POSIX flags, busybox-compatible)
- `blockdev` (or `/sys/class/block/<dev>/size`) for partition size
- `umount` / `mount` (POSIX)
- `resize.f2fs` (typically in the F2FS userspace tools)

All are present in default Nerves Buildroot rootfs. For non-Nerves
fwup deployments verify these are in your image.

## License

Apache-2.0.
