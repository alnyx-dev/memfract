# Roadmap

Planned releases after **1.2**. Versions follow `DEPTH.ITERATION` as described in
`AGENTS.md`: new commands, flags and JSON fields bump the iteration; changes that break
scripts or session files bump the depth.

| Version | Theme |
|---------|-------|
| 1.3 | Unsigned types and unaligned scans |
| 1.4 | String and byte-pattern scans |
| 1.5 | Scan performance |
| 1.6 | Undo and snapshots |
| 1.7 | Background freeze and watch in `serve` |
| 1.8 | Pointer scanner |
| 2.0 | Contract cleanup (breaking) |
| 2.1 | CLI usability and JSON schema |
| 2.2 | 32-bit targets and memory protection |
| 2.3 | Table 2.0 and hardening |

## 1.3: unsigned types and unaligned scans

- `uint8`, `uint16`, `uint32`, `uint64` in `--type`, read/write and the table.
- `scan first --align N` for values at unaligned addresses.
- Hex literals (`0x...`) accepted as integer `--value`.

## 1.4: string and byte-pattern scans

- `string` type (UTF-8 and UTF-16LE).
- `bytes` type with wildcard patterns such as `48 8B ?? ?? 89`.
- `scan next` on these types supports `exact`, `changed` and `unchanged`.
- Session format `ZCS4` with a decoder for `ZCS3`.

## 1.5: scan performance

- Benchmark over synthetic regions, so every change is measured.
- Multi-threaded region scanning with address-ordered merge.
- Vectorized `exact` comparison for integer types.
- Fewer `ReadProcessMemory` calls in `scan next`.
- `regions_scanned`, `bytes_read` and `elapsed_ms` in scan responses.

## 1.6: undo and snapshots

- `scan undo` restores the previous result set.
- `scan snapshot save|load --file PATH`.
- `scan next --cond delta --value N`: keep matches that changed by exactly N.
- Undo button in the GUI.

## 1.7: background freeze and watch in `serve`

- `freeze start|stop|list` keeps values written while other commands run.
- `watch start|poll|stop` accumulates changes and returns them on `poll`.
- One-shot `freeze` and `watch` stay blocking.

## 1.8: pointer scanner

- `pointer scan --addr A [--max-depth N] [--max-offset X] [--module NAME]` finds chains
  ending at `A`, in the form `--offsets` accepts.
- `table add --from-pointer INDEX` saves a found chain.
- Result and time limits with a `truncated` flag; honors `--timeout` and cancel.

## 2.0: contract cleanup (breaking)

- Remove the legacy REPL (`src/main.zig`, `zig build repl`).
- Drop the `ZCS2` decoder.
- Consistent flag names (for example `--value2` becomes `--to`).
- Stable list of error codes in `help`, plus `schema_version`.
- Addresses are `0x%016X` strings everywhere in JSON.
- Migration guide in `CHANGELOG.md`, preceded by `2.0-rc1`.

## 2.1: CLI usability and JSON schema

- `help --json-schema` describes every command's response.
- `--format table` for human-readable output; JSON stays the default.
- `doctor` command: elevation, `SeDebugPrivilege`, Windows version, process access.
- Win32 error codes in access-failure messages.

## 2.2: 32-bit targets and memory protection

- WOW64 targets: 4-byte pointers, 32-bit module lists, `--ptr-size` override.
- `regions` filters by protection and type (`image`, `private`, `mapped`).
- `protect --addr A --size N --prot RWX`.

## 2.3: table 2.0 and hardening

- Table format with groups and notes; old tables still load.
- Pointer-chain and `module+offset` entries survive target restarts.
- Table import and export as CSV and JSON.
- GUI hotkeys for freeze and write.
- Fuzz tests for the session and table decoders.
- Smoke test covers every command added since 1.2.

## Out of scope

Memfract is for single-player games, modding and debugging your own programs.

- Anti-cheat evasion, driver-based access, hiding from other software.
- Code injection, debugger, breakpoints, disassembler.
- Non-Windows platforms.
