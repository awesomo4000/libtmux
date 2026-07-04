# libtmux

Zig library for driving tmux programmatically. Wraps tmux operations with typed structs and provides a JSON-output CLI binary (`tmuxwrap`).

Requires Zig 0.16.0+ and tmux installed on the system.

## Building

```
zig build
```

Cross-compile for Linux:

```
zig build -Dtarget=x86_64-linux
```

Release build (123 KB binary):

```
zig build -Doptimize=ReleaseSmall
```

Run tests:

```
zig build test
```

## tmuxwrap CLI

The `tmuxwrap` binary provides subcommand-based access to every library operation. Output is JSON on stdout, errors are JSON on stderr.

```
tmuxwrap <socket-name> <subcommand> [flags] [args]
```

Use `default` as the socket name to connect to the user's default tmux server (no `-L` flag). Any other value is passed as `tmux -L <socket-name>`.

### Commands

Get tmux version:

```
$ tmuxwrap default version
{"version":"tmux 3.6a"}
```

Check if a server is running:

```
$ tmuxwrap default is-running
{"running":false}
```

Create a new session:

```
$ tmuxwrap my-socket new-session --name=work --window-name=editor --start-directory=/tmp
{"session_id":"$0"}
```

Take a snapshot of all sessions, windows, and panes:

```
$ tmuxwrap my-socket snapshot
{"sessions":[{"session_id":"$0","session_name":"work","windows":[...]}]}
```

Create a new window:

```
$ tmuxwrap my-socket new-window work --name=logs --start-directory=/var/log
{"window_id":"@1","target":"work"}
```

Split a window:

```
$ tmuxwrap my-socket split-window @1 --horizontal --percent=30
{"pane_id":"%2","target":"@1"}
```

Send keys to a pane:

```
$ tmuxwrap my-socket send-keys %2 "echo hello"
{"ok":true,"target":"%2","keys":"echo hello"}
```

Send keys without pressing Enter:

```
$ tmuxwrap my-socket send-keys %2 "draft text" --no-enter --literal
{"ok":true,"target":"%2","keys":"draft text"}
```

Capture pane contents:

```
$ tmuxwrap my-socket capture-pane %2
{"target":"%2","content":"$ echo hello\nhello\n$ "}
```

Capture with options:

```
$ tmuxwrap my-socket capture-pane %2 --escape --start=-5 --end=-1
$ tmuxwrap my-socket capture-pane %2 --history
```

Set a pane title:

```
$ tmuxwrap my-socket set-pane-title %2 "build output"
{"ok":true,"target":"%2","title":"build output"}
```

Kill a pane, window, session, or the entire server:

```
$ tmuxwrap my-socket kill-pane %2
$ tmuxwrap my-socket kill-window @1
$ tmuxwrap my-socket kill-session work
$ tmuxwrap my-socket kill-server
```

Show help:

```
$ tmuxwrap help
```

### Error output

Errors are JSON on stderr with a non-zero exit code:

```
$ tmuxwrap default kill-session nonexistent
{"error":"KillSessionFailed","message":"failed to kill session"}
```

```
$ tmuxwrap default bogus
{"error":"UnknownSubcommand","message":"bogus"}
```

## Library API

Import the `libtmux` module in your `build.zig`:

```zig
const libtmux_dep = b.dependency("libtmux", .{
    .target = target,
    .optimize = optimize,
});
const libtmux_mod = libtmux_dep.module("libtmux");
exe.root_module.addImport("libtmux", libtmux_mod);
```

Then use it:

```zig
const libtmux = @import("libtmux");
```

### Server

The `Server` struct is the main entry point. It finds the tmux binary, manages socket arguments, and executes commands.

`init` takes an `io: std.Io` and an `environ: std.process.Environ` in addition to the allocator and options. In a program, get these from the entry point `pub fn main(init: std.process.Init)` as `init.io` and `init.minimal.environ`. In tests, use `std.testing.io` and `std.testing.environ`.

Initialize with auto-detected tmux binary:

```zig
var server = try libtmux.Server.init(allocator, io, environ, .{});
defer server.deinit();
```

Initialize with a specific socket name:

```zig
var server = try libtmux.Server.init(allocator, io, environ, .{
    .socket_name = "my-app",
});
defer server.deinit();
```

Initialize with an explicit tmux binary path:

```zig
var server = try libtmux.Server.init(allocator, io, environ, .{
    .tmux_bin = "/opt/homebrew/bin/tmux",
    .socket_path = "/tmp/my-app.sock",
});
defer server.deinit();
```

#### ServerOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `socket_name` | `?[]const u8` | `null` | tmux `-L` socket name |
| `socket_path` | `?[]const u8` | `null` | tmux `-S` socket path |
| `tmux_bin` | `?[]const u8` | `null` | Path to tmux binary (auto-detected if null) |

### Raw command execution

Execute any tmux command and get the full result:

```zig
var result = try server.exec(&.{"-V"});
defer result.deinit();

if (result.success()) {
    std.debug.print("tmux version: {s}\n", .{result.stdout});
} else {
    std.debug.print("failed: {s}\n", .{result.stderr});
}
```

Execute and get stdout directly (errors on non-zero exit):

```zig
const stdout = try server.execChecked(&.{"list-sessions"});
defer allocator.free(stdout);
```

#### TmuxResult

| Field | Type | Description |
|-------|------|-------------|
| `exit_code` | `u8` | Process exit code |
| `stdout` | `[]u8` | Captured stdout |
| `stderr` | `[]u8` | Captured stderr |

Methods: `deinit()`, `success() bool`.

### Sessions

Create a new detached session:

```zig
const session_id = try server.newSession(.{
    .name = "work",
    .window_name = "editor",
    .start_directory = "/home/user/project",
});
defer allocator.free(session_id);
// session_id is e.g. "$0"
```

#### NewSessionOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `?[]const u8` | `null` | Session name |
| `window_name` | `?[]const u8` | `null` | Initial window name |
| `start_directory` | `?[]const u8` | `null` | Working directory |
| `detached` | `bool` | `true` | Create detached |

Kill a session by name or ID:

```zig
try server.killSession("work");
```

### Windows

Create a new window in a session:

```zig
const window_id = try server.newWindow("work", .{
    .name = "logs",
    .start_directory = "/var/log",
});
defer allocator.free(window_id);
// window_id is e.g. "@1"
```

#### NewWindowOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | `?[]const u8` | `null` | Window name |
| `start_directory` | `?[]const u8` | `null` | Working directory |

Kill a window:

```zig
try server.killWindow("@1");
```

### Panes

Split a window to create a new pane:

```zig
const pane_id = try server.splitWindow("@1", .{
    .horizontal = true,
    .percent = 30,
});
defer allocator.free(pane_id);
// pane_id is e.g. "%2"
```

#### SplitWindowOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `horizontal` | `bool` | `false` | Split horizontally (default is vertical) |
| `percent` | `?u8` | `null` | Size as percentage |

Kill a pane:

```zig
try server.killPane("%2");
```

### Sending keys

Send keys to a pane (presses Enter by default):

```zig
try server.sendKeys("%0", "echo hello", .{});
```

Send keys without pressing Enter:

```zig
try server.sendKeys("%0", "partial input", .{ .enter = false });
```

Send literal text (no tmux key interpretation):

```zig
try server.sendKeys("%0", "C-c", .{ .literal = true });
```

#### SendKeysOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `enter` | `bool` | `true` | Append Enter keystroke |
| `literal` | `bool` | `false` | Send keys literally (`-l` flag) |

### Capturing pane output

Capture visible pane content:

```zig
const content = try server.capturePane("%0", .{});
defer allocator.free(content);
```

Capture with ANSI escape sequences:

```zig
const content = try server.capturePane("%0", .{ .escape_sequences = true });
defer allocator.free(content);
```

Capture a specific line range:

```zig
const content = try server.capturePane("%0", .{ .start = 0, .end = 10 });
defer allocator.free(content);
```

Capture last N lines (negative offset from cursor):

```zig
const content = try server.capturePane("%0", .{ .start = -5 });
defer allocator.free(content);
```

Capture entire scrollback history:

```zig
const content = try server.capturePane("%0", .{ .history = true });
defer allocator.free(content);
```

#### CapturePaneOptions

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `escape_sequences` | `bool` | `false` | Include ANSI escapes (`-e`) |
| `start` | `?i32` | `null` | Start line (`-S`), negative = relative to cursor |
| `end` | `?i32` | `null` | End line (`-E`) |
| `history` | `bool` | `false` | Capture entire scrollback (`-S -`) |

### Pane titles

```zig
try server.setPaneTitle("%0", "build output");
```

### Snapshots

Take a snapshot of the full tmux state tree:

```zig
var snap = try server.takeSnapshot();
defer snap.deinit();

for (snap.sessions) |session| {
    std.debug.print("session: {s} ({s})\n", .{ session.session_id, session.session_name });
    for (session.windows) |window| {
        std.debug.print("  window: {s} [{s}]\n", .{ window.window_id, window.window_name });
        for (window.panes) |pane| {
            std.debug.print("    pane: {s} {d}x{d} {s}\n", .{
                pane.pane_id, pane.pane_width, pane.pane_height, pane.pane_current_command,
            });
        }
    }
}
```

Look up objects by ID:

```zig
if (snap.findSession("$0")) |session| {
    std.debug.print("found: {s}\n", .{session.session_name});
}

if (snap.findWindow("@1")) |window| {
    std.debug.print("found: {s}\n", .{window.window_name});
}

if (snap.findPane("%0")) |pane| {
    std.debug.print("found: {s}\n", .{pane.pane_current_command});
}
```

#### Snapshot types

**SessionInfo**: `session_id`, `session_name`, `windows: []WindowInfo`

**WindowInfo**: `window_id`, `window_index`, `window_name`, `window_layout`, `session_id`, `panes: []PaneInfo`

**PaneInfo**: `pane_id`, `pane_index`, `pane_pid`, `pane_current_command`, `pane_current_path`, `pane_width`, `pane_height`, `pane_active`, `window_id`, `session_id`

### Server lifecycle

Check if the server is running:

```zig
const running = server.isRunning();
```

Kill the entire server (all sessions):

```zig
try server.killServer();
```

### which

Find an executable on PATH:

```zig
const path = try libtmux.which(allocator, io, environ, "tmux");
if (path) |p| {
    defer allocator.free(p);
    std.debug.print("tmux at: {s}\n", .{p});
}
```

### Protocol parser

Parse tmux control mode (`tmux -CC`) protocol lines:

```zig
const line = try libtmux.protocol.parseLine("%begin 123 1 0");
switch (line) {
    .begin => |b| std.debug.print("begin: timestamp={d}\n", .{b.timestamp}),
    .end => |e| _ = e,
    .err => |e| _ = e,
    .notification => |n| _ = n,
    .data => |d| _ = d,
}
```

Decode octal escapes from control mode output:

```zig
const decoded = try libtmux.protocol.decodeOctalEscapes(allocator, "hello\\012world");
defer allocator.free(decoded);
// decoded is "hello\nworld"
```

## Architecture

```
Server (tmux server connection)
  ├── exec / execChecked    (one-shot subprocess commands)
  ├── takeSnapshot          (full state tree)
  ├── newSession / killSession
  ├── newWindow / killWindow
  ├── splitWindow / killPane
  ├── sendKeys / capturePane / setPaneTitle
  ├── isRunning / killServer
  └── [future: control mode via protocol parser]

Snapshot
  └── sessions: []SessionInfo
        └── windows: []WindowInfo
              └── panes: []PaneInfo
```

### Modules

| Module | Purpose |
|--------|---------|
| `Server.zig` | Main struct: init, socket args, all high-level operations |
| `process.zig` | Subprocess runner (`run`, `runChecked`, `TmuxResult`) |
| `snapshot.zig` | State tree parser for `list-panes -a` output |
| `protocol.zig` | Control mode protocol parser (`%begin`/`%end`/notifications) |
| `which.zig` | PATH-based executable lookup (cross-compile safe) |
| `root.zig` | Library entry point, re-exports all public types |
| `main.zig` | `tmuxwrap` CLI binary |

## tmux target syntax

tmux identifies objects with prefix characters:

| Prefix | Object | Example |
|--------|--------|---------|
| `$` | Session | `$0`, `$3` |
| `@` | Window | `@0`, `@5` |
| `%` | Pane | `%0`, `%12` |

Sessions can also be targeted by name (e.g., `work`). Windows within a session use `session:window` syntax (e.g., `work:0`).

## License

MIT
