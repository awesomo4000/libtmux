# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Zig library (`libtmux`) that wraps tmux operations. Provides a test binary that exercises the library. Nothing else — no TUI, no daemon, no networking. Just enough to programmatically drive tmux for the operations described in `research/plan-remote-tmux-session-manager.md`.

## Language

Zig 0.15.2

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
- `src/process.zig` — subprocess runner: `run()` and `runChecked()` using `process.Child.run()`
- `src/protocol.zig` — control mode line parser: `%begin`/`%end`/`%error` blocks, all notification types
- `src/snapshot.zig` — state tree parser: `list-panes -a -F` output → Snapshot (sessions > windows > panes)
- `src/which.zig` — find executables on PATH
- `build.zig` — build configuration
- `build.zig.zon` — package metadata (name: `libtmux`)
- `specs/api-design.md` — full API design document

## API Patterns

The library uses a flat API — everything goes through `Server`. Pass target IDs (pane `%N`, window `@N`, session `$N` or name) as strings. No object graph.

```zig
var server = try libtmux.Server.init(allocator, .{ .socket_name = "my-sock" });
defer server.deinit();

const sid = try server.newSession(.{ .name = "work" });
defer allocator.free(sid);

var snap = try server.takeSnapshot();
defer snap.deinit();
```

High-level methods return owned slices (caller must free). Methods that produce no output return `void` or error.

## Zig 0.15.2 Patterns Used

- ArrayList: `std.ArrayList(T){}` init, `.deinit(allocator)`, `.append(allocator, item)`, `.toOwnedSlice(allocator)`
- No `std.time.sleep` — use `std.Thread.sleep`
- No `posix.stat` — use `std.c.faccessat()` for execute checks
- `process.Child.run()` for subprocess execution
- See `~/WORKFLOWS/zig-0.15.2-cheatsheet.md` for migration reference

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
