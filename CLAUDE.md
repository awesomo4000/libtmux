# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Zig library (`libtmux`) that wraps tmux operations. Provides a test binary that exercises the library. Nothing else — no TUI, no daemon, no networking. Just enough to programmatically drive tmux for the operations described in `research/plan-remote-tmux-session-manager.md`.

## Language

Zig 0.16.0

## Build Commands

```
zig build           # build library + test binary
zig build run       # run the test binary
zig build test      # run all tests (library + binary)
zig test src/Server.zig  # run a single file's tests
```

## Project Structure

- `src/root.zig` — library root (public API, what consumers `@import("libtmux")`)
- `src/main.zig` — test binary that exercises the library
- `src/Server.zig` — Server struct: init, exec, high-level ops (newSession, capturePane, etc.)
- `src/process.zig` — subprocess runner: `run()` and `runChecked()` using `std.process.run(gpa, io, ...)`
- `src/protocol.zig` — control mode line parser: `%begin`/`%end`/`%error` blocks, all notification types
- `src/snapshot.zig` — state tree parser: `list-panes -a -F` output → Snapshot (sessions > windows > panes)
- `src/which.zig` — find executables on PATH
- `build.zig` — build configuration
- `build.zig.zon` — package metadata (name: `libtmux`)
- `specs/api-design.md` — full API design document

## API Patterns

The library uses a flat API — everything goes through `Server`. Pass target IDs (pane `%N`, window `@N`, session `$N` or name) as strings. No object graph.

`Server.init` takes an `io: std.Io` and an `environ: std.process.Environ` (needed for all I/O and for PATH-based tmux discovery). In `main`, use the "juicy" entry point `pub fn main(init: std.process.Init)` and pass `init.io` / `init.minimal.environ`. In tests, use the `std.testing.io` / `std.testing.environ` globals.

```zig
var server = try libtmux.Server.init(allocator, io, environ, .{ .socket_name = "my-sock" });
defer server.deinit();

const sid = try server.newSession(.{ .name = "work" });
defer allocator.free(sid);

var snap = try server.takeSnapshot();
defer snap.deinit();
```

High-level methods return owned slices (caller must free). Methods that produce no output return `void` or error.

## Zig 0.16.0 Patterns Used

- `Io` threading: all OS-touching calls take `std.Io`. Obtain via juicy main (`init.io`), `std.testing.io`, or a standalone `std.Io.Threaded`.
- ArrayList: `std.ArrayList(T) = .empty` init (the `.{}` empty literal no longer works), `.deinit(allocator)`, `.append(allocator, item)`, `.toOwnedSlice(allocator)`
- Subprocess: `std.process.run(gpa, io, .{ .argv, .stdout_limit = .limited(n), .stderr_limit = .limited(n) })`; `Term` tags are lowercase (`.exited`)
- Args: `init.minimal.args.iterate()` (no `std.process.args()`); env via `environ.getPosix("PATH")` (no `std.posix.getenv`)
- Files: `std.Io.File.stdout().writer(io, &buf)`; executable check via `std.Io.Dir.cwd().access(io, path, .{ .execute = true })` (no `faccessat`)
- Renames: `std.io.Writer` → `std.Io.Writer`, `std.mem.trimRight` → `trimEnd`
- See `~/WORKFLOWS/zig-0.16.0-cheatsheet.md` for full migration reference

## Reference Material (gitignored)

- `x/libtmux/` — Python libtmux library source
- `research/plan-remote-tmux-session-manager.md` — broader system plan that this library supports

## tmux Concepts

```
Server (a tmux server instance, identified by socket name/path)
  └── Session ($0, $1, ...)
        └── Window (@0, @1, ...)
              └── Pane (%0, %1, ...)
```

### Control Mode

`tmux -CC attach` opens a structured channel: stdout emits notifications (`%output %0 ...`, `%window-add @2`, etc.), stdin accepts tmux commands. Responses come in `%begin`/`%end` blocks with command numbers for matching. Control mode support is planned (protocol parser done, Server connection not yet wired).

### Pane Capture

`capture-pane -p` returns visible contents. Without `-e`, ANSI escapes are stripped. `-S -N` gets last N lines.
