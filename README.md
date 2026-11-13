<div align="center">

# memfract

**A memory scanner for Windows x64, built for scripts first.**

Find a value, narrow it down, and keep it where you want it — from a JSON CLI
or a native Win32 GUI.

[![Latest release](https://img.shields.io/github/v/release/alnyx-dev/memfract?style=flat-square&label=release)](https://github.com/alnyx-dev/memfract/releases/latest)
[![CI](https://img.shields.io/github/actions/workflow/status/alnyx-dev/memfract/ci.yml?branch=main&style=flat-square&label=tests)](https://github.com/alnyx-dev/memfract/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-Windows%20x64-0078D4?style=flat-square&logo=windows&logoColor=white)
![Zig](https://img.shields.io/badge/zig-0.17.0-F7A41D?style=flat-square&logo=zig&logoColor=black)
[![License](https://img.shields.io/badge/license-MIT-2EA44F?style=flat-square)](LICENSE)

</div>

> [!WARNING]
> memfract is for single-player games, modding, and debugging your own programs.
> Do not use it against online games, anti-cheat-protected software, or processes you
> do not own. Misuse may violate rules or law; the author accepts no liability.

## Highlights

- **Script-first.** Every command answers with exactly one JSON line, so an agent or a
  PowerShell script can drive the whole workflow without parsing prose.
- **Fast first scans.** Memory is read on all CPU cores, aligned integer `exact` scans use
  SIMD, and `scan next` filters nearby results through shared read windows.
- **The types you need.** Signed and unsigned integers from 8 to 64 bits, floats, UTF-8
  and UTF-16LE strings, and wildcard byte patterns.
- **Real workflow tools.** Undo, snapshots, delta scans, pointer chains, an address table,
  blocking freeze/watch, and background jobs in `serve`.
- **Two front ends, one engine.** The same scanner powers the automation CLI and the
  native GUI.

## Install

Prebuilt Windows x64 binaries are attached to the
[latest release](https://github.com/alnyx-dev/memfract/releases/latest):

| File | What it is |
|---|---|
| `memfract.exe` | JSON command-line interface |
| `memfract-gui.exe` | Native Win32 GUI |

Download both files into the same directory and run them as administrator. Most
processes cannot be opened without elevation.

To build from source, see [Build and test](#build-and-test).

## First scan

The examples assume `memfract` is on `PATH`. From a source build, use
`.\zig-out\bin\memfract.exe` or add `zig-out\bin` to `PATH`.

```powershell
# 1. Find the target process
memfract ps --filter notepad

# 2. Attach and scan for an int32 value
memfract attach --process notepad.exe
memfract scan first --type int32 --value 100

# 3. Change the value in the game, then narrow the result set
memfract scan next --cond exact --value 93
memfract scan list

# 4. Read, write, and keep the value pinned
memfract read --addr 0x0000000000123456 --type int32
memfract write --addr 0x0000000000123456 --value 9999
memfract freeze --addr 0x0000000000123456 --value 9999 --for 5000

# 5. Stop when done
memfract detach
```

`scan list` returns the current value next to the value remembered by the scanner:

```json
{"ok":true,"count":1,"offset":0,"type":"int32","results":[{"index":0,"address":"0x0000000000123456","value":93,"previous":100}]}
```

String and byte-pattern scans work the same way:

```powershell
memfract scan first --type string --value "player health"
memfract scan first --type string --value "player health" --encoding utf16le
memfract scan first --type bytes --value "48 8B ?? ?? 89"
```

## Command map

| Area | Commands |
|---|---|
| Processes | `ps`, `modules`, `regions`, `attach`, `detach` |
| Memory | `read`, `write` |
| Scanning | `scan first`, `scan next`, `scan list`, `scan status`, `scan reset`, `scan undo`, `scan snapshot` |
| Live values | `freeze`, `watch` |
| Address table | `table add`, `table list`, `table write`, `table remove`, `table clear`, `table save`, `table load` |
| Sessions | `help`, `version`, `serve` |

Run `memfract help` for the full machine-readable command reference, including flags and
response fields. Scan responses also report `regions_scanned`, `bytes_read`, and
`elapsed_ms`, so you can measure what a filter actually touched.

## Types and conditions

| Family | Types |
|---|---|
| Integers | `int8`, `int16`, `int32`, `int64`, `uint8`, `uint16`, `uint32`, `uint64` |
| Floats | `float32`, `float64` |
| Text | `string` with `--encoding utf8` (default) or `utf16le` |
| Bytes | `bytes` with wildcards such as `48 8B ?? ?? 89` |

Integer values accept decimal, hex (`0x`), octal (`0o`), and binary (`0b`) literals.

| Condition | Keeps matches that are |
|---|---|
| `exact` | equal to `--value` |
| `greater` / `less` | above or below `--value` |
| `between` | inside `--value` and `--value2` |
| `changed` / `unchanged` | different from or equal to the previous value |
| `increased` / `decreased` | higher or lower than the previous value |
| `delta` | changed by exactly `--value` |
| `unknown` | not yet known (`scan first` only) |

`string` and `bytes` scans support `exact`, `changed`, and `unchanged`. Float `exact`
comparisons use a tolerance derived from the digits you typed; `--tol 0` makes them
bit-exact.

## Scans and sessions

A first scan walks writable memory unless you pass `--all`; `--module`, `--start`, and
`--end` limit the address range, and `--align 1` finds unaligned values. Results are kept
sorted by address, and a full match budget sets `truncated` instead of failing.

Every scan step can be undone:

```powershell
memfract scan undo
memfract scan snapshot save --file hp.zsn
memfract scan snapshot load --file hp.zsn
```

One-shot commands keep their state in `%TEMP%\memfract\<session>.session`. Use
`--session NAME` for separate projects or `--no-session` for a clean run. Session files
are written atomically; a corrupt file is moved to `<name>.session.corrupt`, a fresh
session starts, and the response includes a `notice` field.

Long-running commands (`scan`, `freeze`, `watch`) stop on `Ctrl+C` and still return a
normal JSON response. `freeze` and `watch` also accept `--timeout MS` and report
`"canceled": true` when stopped early.

## Serve mode

`serve` reads one command per line from stdin and answers one JSON line per command,
without touching session files:

```powershell
@('attach --pid 4242', 'scan first --type int32 --value 100', 'exit') |
    .\zig-out\bin\memfract.exe serve
```

Inside `serve`, freeze and watch jobs run on background threads. A frozen value is
rewritten while other commands run, and `watch poll` returns the samples collected since
the previous poll:

```powershell
@(
    'attach --pid 4242',
    'freeze start --addr game.exe+0x1A2B3C --value 100 --type int32',
    'watch start --addr game.exe+0x1A2B3C --type int32 --changes-only',
    'scan first --type int32 --value 100',
    'watch poll --id 2',
    'freeze stop --id 1',
    'exit'
) | .\zig-out\bin\memfract.exe serve
```

| Command | Purpose |
|---|---|
| `freeze start` | Rewrite a value in the background until stopped |
| `freeze list` | Show jobs, addresses, and write counters |
| `freeze stop` | Stop the job named by `--id`, or every job with `--all` |
| `watch start` | Sample a value in the background |
| `watch poll` | Return and clear the samples collected since the last poll |
| `watch stop` | Stop one job with `--id` (returning unpolled samples) or all with `--all` |
| `watch list` | Show jobs and pending sample counts |

`watch start` accepts `--interval`, `--count`, `--timeout`, and `--changes-only`.
Background watches keep up to 10 000 pending samples and report overflow in `dropped`.
Each job owns its process handle; detaching, switching to another PID, or exiting `serve`
stops and joins every worker.

## GUI

Run `zig-out\bin\memfract-gui.exe` as administrator. The scanner and address table share
one window:

- Pick a process at the top, enter a value, and press **First Scan**, then refine with
  **Next**.
- **Undo** restores the result set from before the last scan or reset.
- Double-click a result to add it to the table; double-click a table row to freeze it.
- **Save** and **Load** use `memfract_table.txt` next to the executable or in the current
  directory.
- **Theme** switches between light and dark instantly.

Closing the window during a scan cancels the scan and exits cleanly.

## Build and test

Requirements:

- Windows x64
- [Zig](https://ziglang.org/) **0.17.0** or newer
- Administrator rights to access most target processes

```powershell
git clone https://github.com/alnyx-dev/memfract.git
cd memfract
zig build
```

The binaries land in `zig-out\bin`:

```text
zig-out\bin\memfract.exe       JSON CLI
zig-out\bin\memfract-gui.exe   GUI
```

| Command | What it does |
|---|---|
| `zig build` | Build and install the CLI and GUI |
| `zig build --release=safe` | Optimized release build |
| `zig build test` | Unit tests for scanning, JSON, CLI, and utilities |
| `zig build smoke` | End-to-end test: attach, scan, write, table, snapshot, serve |
| `zig build bench` | Benchmark scans over synthetic memory regions |
| `zig build target` | Build `target.exe`, a demo process for experiments |
| `zig build run -- version` | Run the CLI with arguments |
| `zig build run-gui` | Run the GUI |
| `zig build repl` | Build the legacy interactive REPL |

Release artifacts are built with `-Dcpu=baseline`, so they do not depend on CPU features
that may be missing on older machines.

## Under the hood

- First scans split the address space into contiguous groups, read 1 MiB chunks on every
  CPU core, and merge the groups back in address order.
- `scan next` batches nearby matches into read windows of up to 64 KiB, falling back to
  per-match reads only when a window fails.
- A failed block read falls back to 4 KiB pages, so one inaccessible page does not abort a
  scan.
- Matches are strictly ascending and duplicate-free; the session decoder rejects anything
  else because filtering depends on that invariant.

<details>
<summary>Project layout</summary>

```text
src/
  cli.zig       JSON CLI, serve mode, sessions, address table
  gui.zig       Win32/GDI+ GUI
  scan.zig      scanning and value comparison engine
  bench.zig     benchmark over synthetic memory regions
  util.zig      number parsing, UTF-8 handling, table file format
  json.zig      minimal JSON writer
  win.zig       WinAPI wrappers for processes, memory, modules, and files
  version.zig   single source of the version string
  main.zig      legacy REPL (built only by `zig build repl`)
  target.zig    demo target process
  tests.zig     unit-test root
tests/
  fixture.zig   smoke-test target
  smoke.ps1     end-to-end scenario
```

</details>

## Limitations

- Windows x64 only. 32-bit (WOW64) targets are not supported yet.
- Protected processes and anti-cheat-protected games are out of scope.
- Only readable memory is scanned; inaccessible pages are skipped.
- Absolute addresses change when the target restarts. Prefer `module+offset` and pointer
  chains for values you want to keep.

## Author

[alnyx](https://github.com/alnyx-dev)

## License

MIT — see [LICENSE](LICENSE).
