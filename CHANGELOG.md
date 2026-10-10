# Changelog

## 0.2.0 - 2026-10-06

- Support ext2/3/4 (`resize2fs`) and f2fs through the
  `NervesDataResize.Filesystem` behaviour; the type is detected from
  `/proc/mounts` and can be overridden with `:filesystem`.
- Grow ext4 online; f2fs is unmounted and remounted.
- `:partition` is optional: the device mounted at `:mount_point` is used.
- Remount with the options found in `/proc/mounts`; `:mount_opts` overrides
  them and `"nodev"` is only the fallback when `/proc/mounts` is unreadable.
- Refuse `/`, paths that are not mounts and unsupported filesystem types.
- Refuse to unmount while a process holds a path under the mount point:
  `{:error, {:busy, [%{pid:, name:, path:}]}}`.
- Errors after the resize started are `{:error, %{step:, reason:,
  remounted?:}}` (plus `remount_error:` when the remount failed too).
  Failures before anything was modified keep the `{:error, reason}` shape.
- `run/1` returns `:disabled` when nothing is configured (a `:partition` is
  no longer required) or `enabled: false`.
- All system access goes through the injectable `NervesDataResize.System`
  behaviour (`:runner` option or `config :nerves_data_resize, :runner`).
- Add a fake system for tests and a loopback suite
  (`mix test --only loopback`) that grows real filesystems on loop devices.
- Drop the F2FS-specific and workshop framing from the documentation.

## 0.1.0

- Initial F2FS-only offline resize with optional device-mapper partition growth.

- Growth also requires the device to exceed the filesystem by `:min_grow` bytes (default 64 MiB), so `df` metadata overhead on a small, fully grown filesystem is not mistaken for unused space.
