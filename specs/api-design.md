# libtmux Zig API Design

## Overview

A Zig library wrapping tmux. Two modes of operation:

1. **Control mode** (primary) — persistent `tmux -CC` connection over stdin/stdout. Send commands, get structured responses in `%begin`/`%end` blocks, receive async notifications. This is what the daemon will use.
2. **One-shot** (fallback) — spawn `tmux <command>`, collect output, done. Useful for simple scripts or when you don't need streaming.

Both go through the same `Server` struct. Control mode is just `server.connect()` before issuing commands.

## Feature List

### P0 — Foundation
1. Find tmux binary on system
2. One-shot command execution (spawn tmux, get stdout/stderr/exit code)
3. Server struct with socket name/path
4. Control mode connection (spawn `tmux -CC`, manage stdin/stdout pipes)
5. Control mode command/response (send command, parse `%begin`/`%end` response)
6. Control mode notification parsing (`%output`, `%window-add`, `%session-changed`, etc.)

### P1 — Operations via either mode
7. State snapshot — `list-panes -a -F '...'` parsed into tree
8. Send keys to a pane
9. Capture pane contents
10. Create sessions, windows, split panes
11. Set pane titles
12. Kill session/window/pane

### P2 — Streaming
13. Callback/poll interface for async notifications
14. `%output` accumulation per pane (live output tracking)

## Control Mode Protocol

Reference: `man tmux` CONTROL MODE section.

### Command/Response

Send a command on stdin (newline-terminated), get a response block:

```
→  list-sessions
←  %begin 1363006971 2 1
←  0: main* (1 panes) [80x24] [layout b25f,80x24,0,0,2] @2 (active)
←  %end 1363006971 2 1
```

Error case uses `%error` instead of `%end`:
```
←  %begin 1363006971 3 1
←  session not found: nosuch
←  %error 1363006971 3 1
```

The three args are: epoch timestamp, command number, flags (currently unused).

### Async Notifications

Arrive between response blocks, never inside one:

```
%output %0 hello world\n
%window-add @3
%window-close @2
%session-changed $1 work
%layout-change @1 80x24,0,0,2 80x24,0,0,2 *
%sessions-changed
%session-renamed newname
%window-renamed @1 mywindow
%window-pane-changed @1 %3
%pane-mode-changed %0
%exit
%exit reason text
```

`%output` value uses octal escapes (`\xxx`) for non-printable characters and backslash.

## Structs

### TmuxResult

Returned by one-shot commands.

```zig
pub const TmuxResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    exit_code: u8,
};
```

### CommandResponse

Returned by control mode commands.

```zig
pub const CommandResponse = struct {
    output: []const u8,     // lines between %begin and %end/%error
    success: bool,          // true = %end, false = %error
    time: i64,              // epoch seconds
    command_number: u32,
};
```

### Notification

Tagged union for all async notifications.

```zig
pub const Notification = union(enum) {
    output: struct { pane_id: []const u8, data: []const u8 },
    window_add: struct { window_id: []const u8 },
    window_close: struct { window_id: []const u8 },
    window_renamed: struct { window_id: []const u8, name: []const u8 },
    window_pane_changed: struct { window_id: []const u8, pane_id: []const u8 },
    session_changed: struct { session_id: []const u8, name: []const u8 },
    session_renamed: struct { name: []const u8 },
    session_window_changed: struct { session_id: []const u8, window_id: []const u8 },
    sessions_changed: void,
    layout_change: struct { window_id: []const u8, layout: []const u8 },
    pane_mode_changed: struct { pane_id: []const u8 },
    client_detached: struct { client: []const u8 },
    client_session_changed: struct { client: []const u8, session_id: []const u8, name: []const u8 },
    exit: struct { reason: ?[]const u8 },
    unlinked_window_add: struct { window_id: []const u8 },
    unlinked_window_close: struct { window_id: []const u8 },
    unlinked_window_renamed: struct { window_id: []const u8 },
    paste_buffer_changed: struct { name: []const u8 },
    paste_buffer_deleted: struct { name: []const u8 },
    @"continue": struct { pane_id: []const u8 },
    pause: struct { pane_id: []const u8 },
    message: struct { text: []const u8 },
    config_error: struct { error_text: []const u8 },
};
```

### Server

```zig
pub const Server = struct {
    allocator: Allocator,
    tmux_bin: []const u8,
    socket_name: ?[]const u8,
    socket_path: ?[]const u8,

    // Control mode state (null when not connected)
    control: ?ControlConnection,

    pub fn init(allocator: Allocator, opts: ServerOptions) !Server { ... }
    pub fn deinit(self: *Server) void { ... }

    // --- Control mode ---

    /// Start a control mode connection (tmux -CC new-session or attach).
    pub fn connect(self: *Server, opts: ConnectOptions) !void { ... }

    /// Disconnect (close pipes, wait for child).
    pub fn disconnect(self: *Server) void { ... }

    /// Send a command via control mode, wait for %begin/%end response.
    pub fn command(self: *Server, cmd_str: []const u8) !CommandResponse { ... }

    /// Poll for pending notifications. Non-blocking.
    /// Returns null if no notification available.
    pub fn poll(self: *Server) !?Notification { ... }

    // --- One-shot mode ---

    /// Execute a tmux command as a subprocess. Works without connect().
    pub fn exec(self: *Server, args: []const []const u8) !TmuxResult { ... }

    // --- High-level operations (use control mode if connected, one-shot otherwise) ---

    pub fn snapshot(self: *Server) !Snapshot { ... }
    pub fn new_session(self: *Server, opts: NewSessionOptions) ![]const u8 { ... }     // returns session_id
    pub fn kill_session(self: *Server, target: []const u8) !void { ... }
    pub fn new_window(self: *Server, target: []const u8, opts: NewWindowOptions) ![]const u8 { ... }  // returns window_id
    pub fn kill_window(self: *Server, target: []const u8) !void { ... }
    pub fn split_window(self: *Server, target: []const u8, opts: SplitWindowOptions) ![]const u8 { ... } // returns pane_id
    pub fn kill_pane(self: *Server, target: []const u8) !void { ... }
    pub fn send_keys(self: *Server, target: []const u8, keys: []const u8, opts: SendKeysOptions) !void { ... }
    pub fn capture_pane(self: *Server, target: []const u8, opts: CapturePaneOptions) ![]const u8 { ... }
    pub fn set_pane_title(self: *Server, target: []const u8, title: []const u8) !void { ... }
};
```

### ControlConnection

Internal state for a control mode session.

```zig
const ControlConnection = struct {
    child: std.process.Child,         // tmux -CC process
    stdin: std.fs.File,               // pipe to tmux stdin
    stdout: std.fs.File,              // pipe from tmux stdout
    read_buf: [8192]u8,               // line read buffer
    next_cmd_num: u32,                // for matching responses
};
```

### Options structs

```zig
pub const ServerOptions = struct {
    socket_name: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
    tmux_bin: ?[]const u8 = null,     // null = auto-detect via PATH
};

pub const ConnectOptions = struct {
    session_name: ?[]const u8 = null, // attach to existing, or null for new
    detached: bool = true,
};

pub const NewSessionOptions = struct {
    name: ?[]const u8 = null,
    window_name: ?[]const u8 = null,
    start_directory: ?[]const u8 = null,
};

pub const NewWindowOptions = struct {
    name: ?[]const u8 = null,
    start_directory: ?[]const u8 = null,
};

pub const SplitWindowOptions = struct {
    horizontal: bool = false,
    percent: ?u8 = null,
};

pub const SendKeysOptions = struct {
    enter: bool = true,
    literal: bool = false,
};

pub const CapturePaneOptions = struct {
    escape_sequences: bool = false,   // -e flag
    start: ?i32 = null,              // -S flag, negative = relative to cursor (-20 = last 20 lines)
    end: ?i32 = null,                // -E flag
    history: bool = false,           // -S - (entire scrollback)
};
```

### State snapshot structs

```zig
pub const PaneInfo = struct {
    pane_id: []const u8,
    pane_index: u16,
    pane_pid: u32,
    pane_current_command: []const u8,
    pane_current_path: []const u8,
    pane_width: u16,
    pane_height: u16,
    pane_active: bool,
    window_id: []const u8,
    session_id: []const u8,
};

pub const WindowInfo = struct {
    window_id: []const u8,
    window_index: u16,
    window_name: []const u8,
    window_layout: []const u8,
    session_id: []const u8,
    panes: []PaneInfo,
};

pub const SessionInfo = struct {
    session_id: []const u8,
    session_name: []const u8,
    windows: []WindowInfo,
};

pub const Snapshot = struct {
    sessions: []SessionInfo,
    allocator: Allocator,

    pub fn deinit(self: *Snapshot) void { ... }
    pub fn find_pane(self: Snapshot, pane_id: []const u8) ?*const PaneInfo { ... }
    pub fn find_window(self: Snapshot, window_id: []const u8) ?*const WindowInfo { ... }
    pub fn find_session(self: Snapshot, session_id: []const u8) ?*const SessionInfo { ... }
};
```

## File Layout

```
src/
  root.zig            — public API re-exports
  main.zig            — test binary
  Server.zig          — Server struct, connect/disconnect, command/exec, high-level ops
  protocol.zig        — control mode parsing: %begin/%end blocks, notification parser
  snapshot.zig        — Snapshot/SessionInfo/WindowInfo/PaneInfo, format string parsing
  process.zig         — subprocess spawn + pipe management, one-shot exec
  which.zig           — find executable on PATH
```

## Test Binary (main.zig)

Exercises both modes:

### One-shot test
1. Find tmux, print version
2. Create a session (unique socket name)
3. Take a snapshot, print tree
4. Clean up

### Control mode test
1. Connect via control mode
2. Create session, window, split
3. Send keys, capture pane, print output
4. Set pane title
5. Poll for notifications and print them
6. Take a snapshot via control mode
7. Disconnect, clean up

## Implementation Order

1. **which.zig** — find tmux on PATH
2. **process.zig** — spawn subprocess, collect stdout/stderr (one-shot)
3. **Server.zig (one-shot only)** — init, exec, build args with socket flags
4. **protocol.zig** — line parser for `%begin`/`%end`/`%error` blocks and notifications
5. **Server.zig (control mode)** — connect, command, poll, disconnect
6. **snapshot.zig** — format string query, output parser, tree builder
7. **High-level methods** — new_session, send_keys, capture_pane, etc.
8. **main.zig** — test binary
9. **Unit tests** — test blocks in each file

## Design Decisions

**Flat API.** Everything goes through Server. You pass target IDs (pane_id, window_id, session_id) as strings. No object graph.

**Dual mode.** High-level methods work in both modes. If connected via control mode, they use that. Otherwise they fall back to one-shot subprocess. The caller doesn't need to care.

**Control mode is a pipe.** `tmux -CC` is just a child process with stdin/stdout pipes. For the remote case, the daemon will pipe these over SSH — the library doesn't need to know about SSH.

**Notifications are polled.** No callbacks, no threads. The caller polls when ready. Keeps it simple and composable with any event loop.

**Command numbers for matching.** Control mode includes a command number in `%begin`/`%end`. We track this to match responses to requests, since notifications can interleave.
