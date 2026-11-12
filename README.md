# Memfract

A Windows x64 memory scanner written in Zig: a JSON CLI for automation and a Fluent-style GUI for manual work.

> **Intended use.** This tool is meant for single-player games, modding, and debugging your own programs.
> Do not use it against online games, anti-cheat protected, or third-party processes: it may violate rules and law.
> The author accepts no liability for misuse.

## Features

- List processes, loaded modules, and memory regions.
- Scan for `int8`, `int16`, `int32`, `int64`, `uint8`, `uint16`, `uint32`, `uint64`, `float32`, and `float64` values.
- Scan for `string` values (UTF-8 or UTF-16LE via `--encoding`) and for `bytes` patterns with wildcards such as `48 8B ?? ?? 89`.
- Integer values accept decimal, hex (`0x..`), octal, and binary literals.
- Limit a first scan to a module or an address range (`--module`, `--start`, `--end`) and choose the address alignment (`--align`, use `1` for unaligned values).
- First scans run on all CPU cores (`--threads N` to override) and compare integer `exact` values with SIMD; responses report `regions_scanned`, `bytes_read`, and `elapsed_ms`.
- Conditions: exact, greater/less, between, changed/unchanged, increased/decreased, unknown initial value. `string` and `bytes` scans support exact, changed, and unchanged.
- Pointer chains (`module+offset`, `--offsets`) and stable addresses.
- Address table with descriptions, save/load in a GUI-compatible text format.
- Two CLI modes: one-shot commands with a file-backed session, and `serve` with line-by-line JSON over stdin/stdout.
- GUI with a built-in scanner, a table with value freezing, and light/dark themes.

## Download

Prebuilt Windows x64 binaries are attached to the
[latest release](https://github.com/alnyx-dev/memfract/releases/latest):

- `memfract.exe` — JSON CLI.
- `memfract-gui.exe` — GUI.

Put both files in the same directory and run them as administrator. To build
from source instead, see below.

## Requirements

- Windows x64.
- Zig **0.17.0** (tested with this version).
- Administrator rights are required to access most processes.

## Build

```powershell
git clone <repo>
cd memfract
zig build
```

Output:

```
zig-out/bin/memfract.exe       # JSON CLI
zig-out/bin/memfract-gui.exe   # GUI
```

Useful build steps:

| Command | Description |
|---|---|
| `zig build` | build and install the CLI and GUI |
| `zig build --release=safe` | release build (ReleaseSafe) |
| `zig build test` | unit tests (`scan`, `json`, `cli`, `util`) |
| `zig build smoke` | integration test: attach, scan, write, table, detach |
| `zig build bench` | benchmark scans over synthetic regions (ReleaseFast) |
| `zig build target` | build `target.exe`, a demo target for experiments |
| `zig build run -- version` | run the CLI with arguments |
| `zig build run-gui` | run the GUI |
| `zig build repl` | build the legacy interactive REPL (`memfract-repl.exe`) |

## CLI quick start

```powershell
# run as administrator
.\zig-out\bin\memfract.exe ps --filter notepad
.\zig-out\bin\memfract.exe attach --process notepad.exe

# find the value 100 and narrow the results after it changes
.\zig-out\bin\memfract.exe scan first --type int32 --value 100
.\zig-out\bin\memfract.exe scan next --cond exact --value 93
.\zig-out\bin\memfract.exe scan list

# text and byte-pattern scans
.\zig-out\bin\memfract.exe scan first --type string --value "player health"
.\zig-out\bin\memfract.exe scan first --type bytes --value "48 8B ?? ?? 89"

# write and verify
.\zig-out\bin\memfract.exe write --addr 0x... --value 9999
.\zig-out\bin\memfract.exe read --addr 0x... --type int32

.\zig-out\bin\memfract.exe detach
```

Responses are one JSON object per line; state is kept in `%TEMP%\memfract\<session>.session`.
Session files are written atomically. If a saved session is corrupt, it is moved to
`<name>.session.corrupt`, a fresh session starts, and the response includes a `notice` field.
Run `memfract help` for the full machine-readable command reference.

Long-running commands (`scan`, `freeze`, `watch`) stop on `Ctrl+C` and still return a valid
JSON response. `freeze` and `watch` also accept `--timeout MS` as an upper bound and set
`"canceled": true` when they stop before finishing normally.

For a series of commands, use `serve`:

```powershell
@('attach --pid 4242', 'scan first --type int32 --value 100', 'exit') | .\zig-out\bin\memfract.exe serve
```

## GUI

Run `zig-out\bin\memfract-gui.exe` as administrator. The scanner and address table share one window
with three areas: a results list, a scan panel, and a saved-address table. Pick a process at the top,
enter a value, and press First Scan, then refine with Next. Double-click a result to add it to the
table; double-click a table row to freeze it. `Save` and `Load` in the table header use
`memfract_table.txt` next to the executable or in the current directory, and `Theme` switches
light/dark instantly. Closing the window during a scan cancels it and exits cleanly.

## Project layout

```
src/
  cli.zig       JSON CLI (primary automation interface)
  gui.zig       Win32/GDI+ GUI
  scan.zig      scanning and value comparison engine
  bench.zig     benchmark over synthetic memory regions
  util.zig      shared helpers (number parsing, UTF-8, table file format)
  json.zig      minimal JSON writer
  win.zig       WinAPI wrappers (processes, memory, modules, files)
  version.zig   single source of the version string
  main.zig      legacy REPL (build with `zig build repl` only)
  target.zig    demo target process
  tests.zig     unit-test root
tests/
  fixture.zig   smoke-test target
  smoke.ps1     integration scenario
```

## Limitations

- Windows x64 only; other platforms are not supported.
- No support for 32-bit (WOW64) target processes or protected processes.
- Scanning reads readable regions only; inaccessible pages are skipped.
- Absolute addresses change when the target process restarts; use `module+offset`.

## Author

alnyx

## License

MIT, see [LICENSE](LICENSE).
