# AGENTS.md

memfract is a Windows-only process memory scanner written in Zig (Cheat Engine-style
first/next scans, typed read/write, freeze, watch). It ships a JSON-speaking CLI and a
Win32 GUI.

## Build, test, run

Requires Zig 0.17.0 or newer (`minimum_zig_version` in `build.zig.zon`). Building for a
non-Windows target panics by design. Default optimize mode is `ReleaseSafe`.

```
zig build              # installs memfract.exe and memfract-gui.exe into zig-out/bin
zig build test         # unit tests (src/tests.zig imports the module tests)
zig build smoke        # Windows integration test: tests/smoke.ps1 drives memfract.exe
                       # against tests/fixture.zig (needs PowerShell)
zig build bench        # benchmark over synthetic regions (ReleaseFast)
zig build target       # demo process target.exe (prints its PID and the address of hp)
zig build repl         # legacy interactive REPL, memfract-repl.exe
zig build run -- ps    # run the CLI with arguments
zig build run-gui      # run the GUI
```

Run `zig build test` before every commit, and `zig build smoke` after touching `cli.zig`,
`scan.zig` or `win.zig`. Run `zig build bench` before and after scan-performance changes;
the output is a repeatable MiB/s figure, not a pass/fail check.

## Layout

| File | Role |
|------|------|
| `src/win.zig` | Thin Win32 wrapper: `Process` (open/read/write/regions/modules), process listing, console and file I/O, atomic file write. All `extern` declarations live here. |
| `src/scan.zig` | `Scanner`: `first` / `next`, `Kind` (int32 int64 float32 float64), `Cond`, value encode/format/compare. No I/O, no UI. |
| `src/bench.zig` | Benchmark over synthetic memory regions (`zig build bench`). |
| `src/cli.zig` | One-shot commands and `serve` mode. Command table (`HelpEntry`), arg parsing, JSON responses, session save/load. |
| `src/gui.zig` | Win32 GUI. Scans run on a worker thread. |
| `src/util.zig` | Number normalization, float tolerance, UTF-8 clipping, address-table line format. |
| `src/json.zig` | Minimal JSON writer (`kvStr`, `kvInt`, `kvBool`, ...). |
| `src/version.zig` | `pub const string`, the version shown by the CLI and GUI. |
| `src/main.zig` | Legacy interactive REPL (`zig build repl`), not part of the default build. |
| `src/target.zig` | Demo target: prints its PID and the address of `hp`, subtracts 7 on Enter. |
| `src/tests.zig` | Test root, imports the other modules. |
| `tests/` | `fixture.zig` (target for integration tests) and `smoke.ps1`. |

## CLI contract

- Every command prints exactly one JSON line. Success: `{"ok":true,...}`.
  Failure: `{"ok":false,"error":{"code":"...","message":"..."}}`.
- Commands and flags are declared in the help table in `cli.zig`. When you add a
  command or flag, update the table and the known-flags list near the top: `help` is the
  machine-readable documentation that other tools rely on.
- State persists between one-shot calls in `<name>.session` files (`--session NAME`).
  The file format starts with a magic (`ZCS4`, legacy `ZCS3` and `ZCS2` are still
  readable). Change the layout only together with a new magic and, where possible, a
  decoder for the old one.
- A session stores the target's creation time; a restarted PID must fail with
  `StaleSession`, not silently reuse results.
- `serve` reads one command per line from stdin and keeps state in memory.
  Reset per-command flags (`interrupted`) at the start of each command.
- Addresses are written as fixed-width `0x%016X` (`hexAddr`). Inputs accept `0x...` or
  `module+offset`; `--offsets` follows a pointer chain.

## Scanner invariants

- `matches` is sorted by ascending address with no duplicates. The session decoder
  rejects anything else, and `next` relies on it.
- Scanning is aligned to the value size inside each region. Chunk size is 1 MiB;
  `max_matches` is 16,000,000 and sets `truncated` instead of failing.
- `first` fills a result, `next` only filters it. A read failure in `next` drops that
  match instead of aborting.
- `first` splits the scanned regions into contiguous worker groups and merges them in
  address order, so `matches` stays sorted no matter how many threads run. Workers share
  one `max_matches` budget; the `truncated` flag is set when it runs out.
- `next` reads nearby matches in shared windows of up to 64 KB, bridging gaps of 4 KB or
  less, and falls back to per-match reads when a window read fails.
- `stats` (`regions_scanned`, `bytes_read`, `threads`) is runtime-only and not stored in
  session files.
- Long operations must honor `cancel_flag` (Ctrl+C, `--timeout` watchdog, GUI cancel)
  and report `canceled` rather than an error.
- Writable-only region listing excludes `MEM_MAPPED`; `--all` includes it.
- Float "exact" uses a tolerance derived from the typed text (`util.tolFromText`), not
  bitwise equality.

## GUI rules

- While the scan worker thread runs (`busy`), the UI thread must not touch `sc`,
  the process handle, or the match list. New heavy commands check `busy` first, and
  `syncControls` keeps the scan buttons disabled.
- The worker writes its result fields, then clears `busy`, then posts the completion
  message. Keep that order.
- The worker is joined (`joinScan`) before reading its results, before closing the
  process, and in `WM_CLOSE`/`WM_DESTROY`. Do not rely on the completion message alone.
- The main window paints into a persistent back buffer and blits only the dirty
  rectangle. Release it in `WM_DESTROY`; never keep a bitmap selected in a deleted DC.
- There are no hover or theme animations and no repaint timer. The process filter is
  debounced with `TIMER_FILTER`, and list values are refreshed only when they change.

## Conventions

- Everything in the code is in English: identifiers, string literals, error and log
  messages, test names, comments. The only exception is test data that exists to check
  non-ASCII handling (for example Cyrillic descriptions in `util.zig` tests).
- Write code that explains itself through names and structure, and avoid comments.
  Add a comment only for a non-obvious moment (a Win32 quirk, an ordering requirement,
  a subtle invariant), and keep it to one short line. Do not comment what the code
  plainly does, do not leave commented-out code, and do not add banner or section
  comments. Do not add doc comments to code that is already clear.
- Descriptions and any user text that gets truncated must go through `util.clipUtf8`;
  never slice UTF-8 by bytes. Loading cleans invalid UTF-8 with `cleanUtf8`, which
  drops the whole string.
- Files are written through `win.writeFileAtomic` (temp file + replace). Do not write
  session or table files in place.
- New modules take an allocator as a parameter and free with the same one. Do not add
  new global allocators; the existing entry points use `std.heap.page_allocator`.
- Keep `scan.zig` and `util.zig` free of Win32 UI and console I/O so they stay testable.
- Never read or write another process's memory outside `win.Process`.

## Manual check after touching scan code

1. `zig build target`, run `zig-out\bin\target.exe`, note its PID and `hp` address.
2. `memfract scan first --type int32 --value 100 --pid <PID>`, then `scan list`.
   The `hp` address must be in the list.
3. Press Enter in `target`, run `scan next --cond exact --value 93`.
   One address should remain, equal to `hp`.

## Commits

Every commit has a title and, when the change is not obvious, a description (body).
Write both in English.

**Title:** `type(scope): summary`

- Imperative mood, lowercase after the colon, no trailing period, at most 72 characters.
  Good: `fix(cli): reset Ctrl+C flag before each serve command`.
  Bad: `Fixed stuff`, `updates`, `fix(cli): Fixed the bug.`
- `type` is one of:

| Type | Use for | Version effect |
|------|---------|----------------|
| `feat` | new command, flag, value type, JSON field, GUI feature | iteration +1 |
| `fix` | bug fix | iteration +1 |
| `perf` | speedup with no behavior change | iteration +1 |
| `refactor` | code change with no behavior change | none by itself |
| `test` | adding or fixing tests | none |
| `docs` | README, CHANGELOG, AGENTS.md, comments | none |
| `build` | `build.zig`, `build.zig.zon`, tooling | none |
| `chore` | releases, housekeeping (`chore: release v2.1`) | none |

- `scope` is optional and names the area: `cli`, `scan`, `win`, `gui`, `util`, `json`,
  `build`, `tests`.
- A breaking change adds `!` after the scope (`feat(cli)!: rename --cond to --when`)
  and a `BREAKING CHANGE:` line in the description. It raises DEPTH (see Versioning).

**Description:** separated from the title by a blank line, wrapped at about 72 columns.
Explain why the change is needed and what the observable effect is, not a line-by-line
retelling of the diff. Mention trade-offs and behavior changes (for example, "writable-only
scans now skip MEM_MAPPED; use --all to include it"). Reference issues in the footer:
`Closes #12`.

Example:

```
fix(util): clip table descriptions on a code point boundary

writeTableLine cut descriptions at 128 bytes, which could split a
Cyrillic letter. cleanUtf8 then dropped the whole description on load.
Use clipUtf8 so the cut never lands inside a code point.

Closes #7
```

Rules:

- One logical change per commit. Do not mix a fix with a refactor or a version bump.
- `zig build test` must pass on every commit.
- Do not rewrite history that is already pushed to `main`.

## Versioning ("zoom depth")

Versions have two numbers: `DEPTH.ITERATION`, for example `2.1`.

- **DEPTH** goes up by one when compatibility breaks, and ITERATION resets to `0`.
  Compatibility breaks when:
  - a command or flag is renamed or removed, or its meaning changes;
  - a JSON field is removed, renamed, or changes type;
  - the new version cannot read session files written by the previous one. A new `ZCS`
    magic that keeps a decoder for the old magic (as `ZCS3` does for `ZCS2`) is not a
    break.
- **ITERATION** goes up by one for everything else: bug fixes, speedups, new commands,
  new flags, new JSON fields, GUI changes.
- A script written for depth `N` must keep working on every later `N.y`.
- Pre-releases use a suffix: `3.0-rc1`, `3.0-rc2`. They are published with `--prerelease`.

The version is written in four places and they must always agree. Zig requires a full
semantic version in the build files, so there the patch is always `0`:

| Place | Value for release `2.1` |
|-------|-------------------------|
| `src/version.zig` | `pub const string = "2.1";` |
| `build.zig` | `std.SemanticVersion{ .major = 2, .minor = 1, .patch = 0 }` |
| `build.zig.zon` | `.version = "2.1.0",` |
| Git tag | `v2.1` |

For a pre-release: `3.0-rc1` in `version.zig`, `3.0.0-rc1` in the build files, tag `v3.0-rc1`.

Tests must not hardcode the version string; compare against `version.zig`.

Releasing:

1. Update the version in the places above and add a section to `CHANGELOG.md`.
2. `zig build test` and `zig build smoke` must pass. Release binaries are built with
   `-Dcpu=baseline`; without it the runner's CPU features end up in the binary and it
   crashes on older machines.
3. Commit (`chore: release v2.1`), then
   `gh release create v2.1 --repo alnyx-dev/memfract --title "v2.1" --notes-file <notes>`.
4. Release notes list changes one per line, prefixed `feat:`, `fix:` or `perf:`.
   Put `BREAKING:` first when depth increases.

## Repository and GitHub

- Repository: https://github.com/alnyx-dev/memfract
- All repository work (issues, pull requests, releases, pushes) goes through the GitHub
  CLI (`gh`), authenticated as the `alnyx-dev` account.
- Before any `gh` or `git push` operation, run `gh auth status`. If another account is
  active, run `gh auth switch --user alnyx-dev`. Do not use any other account's
  credentials.
- Pass the repository explicitly so a command never lands in the wrong place:
  `gh issue list --repo alnyx-dev/memfract`,
  `gh pr create --repo alnyx-dev/memfract`,
  `gh release create ... --repo alnyx-dev/memfract`.
- Do not push to or open pull requests against any other repository or fork.