# nerves_data_resize

Grows a mounted filesystem to fill the block device behind it on a Nerves device. YOU LIKELY DON'T NEED THIS.
Works for ext4 and f2fs. On a regular Nerves device, this is done by fwup when using `expand = true` 
but on a device where a disk image is flashed with fastboot in an existing partition, this must be done on the
first device boot. That's what this lib is about.

## Install

```elixir
def deps do
  [
    {:nerves_data_resize, github: "mlainez/nerves_data_resize"}
  ]
end
```

## Usage

Call it once at application start, before anything writes to the target:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    _ = NervesDataResize.run(mount_point: "/root")
    Supervisor.start_link(children(), strategy: :one_for_one)
  end
end
```

or configure it and call `NervesDataResize.run()`:

```elixir
config :nerves_data_resize, :config,
  mount_point: "/root",
  threshold: 1.1
```

The filesystem type, device and mount options are read from
`/proc/mounts`. `mount_point` defaults to `"/root"`, he mount point `erlinit`
actually creates; `/data` is commonly just a symlink to it, not a
mount point itself, so passing `"/data"` here will not match `/proc/mounts`
unless your system genuinely mounts a partition there directly. Any distinct
mount other than `/` works. With no configuration at all, `run/1` returns
`:disabled`.

| Option            | Meaning                                                            |
|-------------------|--------------------------------------------------------------------|
| `:mount_point`    | Mount to grow (default `"/root"`).                                 |
| `:partition`      | Device to grow into (default: the device mounted at `:mount_point`). |
| `:filesystem`     | Type override: `:ext4`, `"f2fs"`, or a `NervesDataResize.Filesystem` module. |
| `:mount_opts`     | Options for remounting an offline filesystem (default: those in use). |
| `:threshold`      | Grow when `device / filesystem >= threshold` (default `1.1`).      |
| `:min_grow`       | ...and the device is this many bytes larger (default 64 MiB).      |
| `:grow_partition` | Device-mapper partition growth, see below.                         |
| `:runner`         | A `NervesDataResize.System` implementation, for tests.             |
| `:enabled`        | `false` disables the library.                                      |

Return values: `:disabled`, `:already_grown`, `{:ok, %{before: bytes, after:
bytes}}`, or `{:error, reason}`. Errors are logged and never raised. See
`NervesDataResize` for every error shape.

## Supported filesystems

| Filesystem | Tool needed                   | While growing             |
|------------|-------------------------------|---------------------------|
| ext2/3/4   | `resize2fs`                   | mounted (online)          |
| f2fs       | `resize.f2fs`                 | unmounted, then remounted |

`df`, plus `mount` and `umount` for f2fs, must also be on the `PATH`. A missing
tool returns `{:error, {:missing_tools, names}}` before anything is touched.
Other filesystems return `{:error, {:unsupported_filesystem, type}}`.
A custom filesystem can be supported by implementing the
`NervesDataResize.Filesystem` behaviour and passing the module as `:filesystem`.

## Safety

- `/` and anything that is not a mount in `/proc/mounts` are refused.
- Online filesystems are never unmounted.
- Before unmounting, `/proc/*/fd`, `cwd`, `exe` and `root` are scanned. If a
  process holds anything under the mount point, nothing is unmounted and
  `{:error, {:busy, [%{pid:, name:, path:}]}}` names the offenders.
- If a step fails after an unmount, the filesystem is mounted again before
  `run/1` returns: `{:error, %{step:, reason:, remounted?:}}`.
- A filesystem that already fills its device is left alone, so repeated boots
  don't trigger anything.

## Growing a device-mapper partition (advanced)

An image flashed raw keeps the partition size it was built with. For a
device-mapper partition (as created by `kpartx`), `:grow_partition` first
extends the partition to the end of its disk: an fwup task rewrites the
partition table, then the mapping is reloaded with `dmsetup`:

```elixir
config :nerves_data_resize, :config,
  partition: "/dev/mapper/disk-part3",
  mount_point: "/root",
  grow_partition: [
    disk: "/dev/mmcblk0",
    ops_fw: "/usr/share/fwup/ops.fw",
    task: "grow-data"
  ]
```

This needs `fwup` and `dmsetup`, a single-linear-target mapping, and an fwup
task (typically an `mbr_write` of an `expand = true` partition).

## Testing

All system access (`/proc`, `/sys`, commands, executable lookup) goes through
the `NervesDataResize.System` behaviour. `test/support/fake_system.ex` is a
fake that simulates one device and filesystem, records commands and injects
failures; the suite uses it for every strategy and failure path:

```
mix test
```

The loopback suite grows real ext4 and f2fs filesystems on loop
devices. It needs root, loop devices and the filesystem tools, so it is
excluded by default. Run it in a throwaway privileged container, for example:

```
docker run --rm --privileged -v "$PWD":/src:ro elixir:1.18-otp-27 bash -c '
  apt-get update -qq && apt-get install -y -qq e2fsprogs f2fs-tools util-linux
  for i in $(seq 0 31); do [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i; done
  cp -r /src /work && cd /work && MIX_ENV=test mix test --only loopback'
```

## Example: Fairphone 3

The Fairphone 3 firmware ships a 256 MB F2FS inside a 51 GB partition that is
a device-mapper partition of the raw-flashed userdata disk:

```elixir
config :nerves_data_resize, :config,
  partition: "/dev/mmcblk0p62p3",
  mount_point: "/root",
  grow_partition: [
    disk: "/dev/mmcblk0p62",
    ops_fw: "/usr/share/fwup/ops.fw",
    task: "grow-app"
  ]
```

## License

Apache-2.0.
