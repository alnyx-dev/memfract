# Changelog

Notable changes to the project. The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and versions follow the `DEPTH.ITERATION` scheme described in `AGENTS.md`.

## [Unreleased]

## [1.5] — 2026-11-12

### Added

- `scan first --threads N` sets the worker count (default: the CPU count).
- Scan responses include `regions_scanned` and `bytes_read` next to `elapsed_ms`, so
  scripts can measure how much memory a filter actually touched.
- `zig build bench` runs a benchmark over synthetic regions: aligned and unaligned
  scans, `scan next`, throughput in MiB/s, and a match-count check against a scalar
  reference pass.

### Changed

- First scans split the scanned address range into contiguous groups, read memory on
  all CPU cores, and merge the groups back in address order. Results stay sorted and
  identical to a single-threaded scan; the worker count only affects speed.
- Workers share one match budget (16,000,000 matches), so `truncated` still keeps
  memory use bounded on very dense scans.
- `scan next` reads nearby matches through shared windows of up to 64 KB instead of one
  4 KB page per call, which cuts `ReadProcessMemory` calls on dense result sets.

### Performance

- Aligned `exact` scans for integer types compare 16 bytes at a time with SIMD; unaligned
  scans keep the byte-by-byte path.

## [1.4] — 2026-11-11

### Added

- `string` scans (UTF-8 or UTF-16LE via `--encoding`) and `bytes` scans with
  wildcards such as `48 8B ?? ?? 89`, for `scan first`, `scan next`, and `scan list`.
  Both support the `exact`, `changed`, and `unchanged` conditions.
- A redesigned GUI: new dark and light palettes, Segoe UI Variable Display and
  Cascadia Mono, larger corner radii, and dropdowns with a description for every
  entry and a check mark on the current one.

### Changed

- The session format is `ZCS4`: it stores variable-length values and the string
  encoding. `ZCS3` and `ZCS2` files still load.
- `read`, `write`, `freeze`, `watch`, and the address table reject `string` and
  `bytes`, which are scan-only types.

## [1.3] — 2026-11-11

### Added

- `uint8`, `uint16`, `uint32`, and `uint64` value types for scans, read/write, and the
  address table.
- `scan first --align N` sets the address alignment (a power of two, default the value
  size). `--align 1` finds values at arbitrary, unaligned addresses.
- Integer `--value` accepts hex (`0x..`), octal, and binary literals in scans, writes,
  `freeze`, and table writes.

### Changed

- Unaligned scans read across chunk and page boundaries so values that straddle them are
  not missed. Session files stay `ZCS3`: existing type ids are unchanged.

## [1.2] — 2026-11-11

### Fixed

- Release binaries are built for baseline x86_64, so they no longer crash with an
  illegal instruction on CPUs without AVX-512.

## [1.1] — 2026-11-11

### Added

- `int8` and `int16` value types for scans, read/write, and the address table.
- `scan first --module NAME`, `--start A`, and `--end A` to limit a scan to a module or an address range.

## [1.0] — 2026-11-11

First release.

### Added

- `memfract` JSON CLI: processes, modules, regions, attach/detach, read/write, scanning, address table.
- `serve` mode: line-by-line JSON protocol over stdin/stdout for agents and scripts.
- File-backed sessions (`%TEMP%\memfract\<name>.session`) with process identity validation.
- Scan conditions: `exact`, `greater`, `less`, `between`, `changed`, `unchanged`, `increased`, `decreased`, `unknown`.
- Pointer chains and `module+offset` addresses.
- Win32/GDI+ GUI with a scanner, table, value freezing, and themes.
- Unified `zig build`: CLI and GUI, with `test`, `smoke`, `target`, `run`, `run-gui`, and `repl` steps.
- `Ctrl+C` stops scanning, `freeze`, and `watch`, which then return a normal JSON response. `freeze` and `watch` also accept `--timeout MS` as an upper bound and report `"canceled": true` when stopped early.
- A corrupt session file is moved to `<name>.session.corrupt`, a fresh session is started, and the response contains a `notice` field.
- Unit tests for `scan`, `json`, `cli`, session round-trip, truncation, ordering, legacy `ZCS2` compatibility, the table file format, and an integration smoke test.

### Changed

- Scanning is resilient to inaccessible pages: a failed block read falls back to 4 KB pages.
- `scan next` reads each 4 KB page once instead of issuing one `ReadProcessMemory` per address, which makes filtering large result sets much faster.
- Session files are written atomically (temp file + `MoveFileEx`), so a crash during a save can no longer leave a half-written session behind.
- The `ZCS3` session format stores only the bytes that matter for the value type and validates strictly ascending addresses. `ZCS2` files are still accepted.
- Re-opening the same process no longer marks the session dirty, so read-only commands (`read`, `scan list`, `table list`, ...) stop rewriting the session file.
- Writable-only scans (the default) skip `MEM_MAPPED` regions such as large shared sections; `--all` still includes them.
- The GUI no longer reads target memory while painting: result and table values are sampled by timers into a small cache.
- The GUI tracks "a first scan has completed" separately from the match count, so Next, Reset, and the scan-type lock keep working when a scan finds zero addresses.
- The GUI description limit was raised from 40 to 120 characters, matching the CLI and the table file format.
- Number parsing, UTF-8 clipping, and the table file format live in a shared `src/util.zig` used by both front ends.
- Version moved to `src/version.zig` and shared by the CLI and GUI.
- The JSON writer enforces a nesting depth limit (`DepthLimit`).
- Descriptions from sessions and table files are validated as UTF-8.
- Added `--help`/`-h` and `--version`/`-V` aliases.
- `table write` returns the value actually read back after writing.

### Fixed

- Fixed a data race where the GUI repaint could read the match list while the scanner thread was still appending to it.
- Table descriptions are clipped at a UTF-8 code point boundary, so `table save` can no longer write an invalid table file.
- `serve` clears the Ctrl+C flag before each command, so one canceled command no longer cancels every command that follows.
- Zig 0.17 compatibility: `std.meta.intToEnum` replaced with `std.enums.fromInt`.
- Restored missing WinAPI wrappers (modules, process creation time, file operations).

### Removed

- The legacy REPL is no longer installed by default; use `zig build repl`.
