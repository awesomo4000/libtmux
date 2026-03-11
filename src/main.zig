const std = @import("std");
const libtmux = @import("libtmux");

const Writer = std.io.Writer;
const Stringify = std.json.Stringify;

// ── Subcommand enum ─────────────────────────────────────────────────

const Subcommand = enum {
    version,
    @"is-running",
    snapshot,
    @"new-session",
    @"kill-session",
    @"new-window",
    @"kill-window",
    @"split-window",
    @"kill-pane",
    @"send-keys",
    @"capture-pane",
    @"set-pane-title",
    @"kill-server",
    help,
};

// ── JSON helpers ────────────────────────────────────────────────────

fn writeJson(w: *Writer, value_arg: anytype) !void {
    Stringify.value(value_arg, .{}, w) catch return error.JsonWriteFailed;
    try w.writeAll("\n");
}

fn writeJsonError(w: *Writer, err_name: []const u8, message: []const u8) void {
    var jw: Stringify = .{ .writer = w };
    jw.beginObject() catch return;
    jw.objectField("error") catch return;
    jw.write(err_name) catch return;
    jw.objectField("message") catch return;
    jw.write(message) catch return;
    jw.endObject() catch return;
    w.writeAll("\n") catch return;
    w.flush() catch return;
}

// ── Flag parsing helpers ────────────────────────────────────────────

fn parseFlag(arg: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) {
        return arg[prefix.len..];
    }
    return null;
}

fn isFlag(arg: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, arg, name);
}

// ── Subcommand handlers ─────────────────────────────────────────────

fn cmdVersion(server: *libtmux.Server, w: *Writer) !void {
    var result = try server.exec(&.{"-V"});
    defer result.deinit();

    if (!result.success()) {
        return error.TmuxCommandFailed;
    }

    const trimmed = std.mem.trimRight(u8, result.stdout, "\n\r");
    try writeJson(w, .{ .version = trimmed });
}

fn cmdIsRunning(server: *libtmux.Server, w: *Writer) !void {
    const running = server.isRunning();
    try writeJson(w, .{ .running = running });
}

fn cmdSnapshot(server: *libtmux.Server, w: *Writer) !void {
    var snap = try server.takeSnapshot();
    defer snap.deinit();

    // Build a JSON-friendly representation
    try writeSnapshotJson(w, snap);
}

fn writeSnapshotJson(w: *Writer, snap: libtmux.Snapshot) !void {
    var jw: Stringify = .{ .writer = w };
    jw.beginObject() catch return;
    jw.objectField("sessions") catch return;
    jw.beginArray() catch return;

    for (snap.sessions) |session| {
        jw.beginObject() catch return;
        jw.objectField("session_id") catch return;
        jw.write(session.session_id) catch return;
        jw.objectField("session_name") catch return;
        jw.write(session.session_name) catch return;
        jw.objectField("windows") catch return;
        jw.beginArray() catch return;

        for (session.windows) |window| {
            jw.beginObject() catch return;
            jw.objectField("window_id") catch return;
            jw.write(window.window_id) catch return;
            jw.objectField("window_index") catch return;
            jw.write(window.window_index) catch return;
            jw.objectField("window_name") catch return;
            jw.write(window.window_name) catch return;
            jw.objectField("window_layout") catch return;
            jw.write(window.window_layout) catch return;
            jw.objectField("panes") catch return;
            jw.beginArray() catch return;

            for (window.panes) |pane| {
                jw.beginObject() catch return;
                jw.objectField("pane_id") catch return;
                jw.write(pane.pane_id) catch return;
                jw.objectField("pane_index") catch return;
                jw.write(pane.pane_index) catch return;
                jw.objectField("pane_pid") catch return;
                jw.write(pane.pane_pid) catch return;
                jw.objectField("pane_current_command") catch return;
                jw.write(pane.pane_current_command) catch return;
                jw.objectField("pane_current_path") catch return;
                jw.write(pane.pane_current_path) catch return;
                jw.objectField("pane_width") catch return;
                jw.write(pane.pane_width) catch return;
                jw.objectField("pane_height") catch return;
                jw.write(pane.pane_height) catch return;
                jw.objectField("pane_active") catch return;
                jw.write(pane.pane_active) catch return;
                jw.endObject() catch return;
            }

            jw.endArray() catch return;
            jw.endObject() catch return;
        }

        jw.endArray() catch return;
        jw.endObject() catch return;
    }

    jw.endArray() catch return;
    jw.endObject() catch return;
    w.writeAll("\n") catch return;
}

fn cmdNewSession(server: *libtmux.Server, args: []const []const u8, w: *Writer) !void {
    var opts: libtmux.NewSessionOptions = .{};
    for (args) |arg| {
        if (parseFlag(arg, "--name=")) |v| {
            opts.name = v;
        } else if (parseFlag(arg, "--window-name=")) |v| {
            opts.window_name = v;
        } else if (parseFlag(arg, "--start-directory=")) |v| {
            opts.start_directory = v;
        }
    }

    const session_id = try server.newSession(opts);
    defer server.allocator.free(session_id);
    try writeJson(w, .{ .session_id = session_id });
}

fn cmdKillSession(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    if (args.len == 0) {
        writeJsonError(ew, "Usage", "kill-session requires a target argument");
        return error.MissingArgs;
    }
    try server.killSession(args[0]);
    try writeJson(w, .{ .ok = true, .target = args[0] });
}

fn cmdNewWindow(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    var target: ?[]const u8 = null;
    var opts: libtmux.NewWindowOptions = .{};

    for (args) |arg| {
        if (parseFlag(arg, "--name=")) |v| {
            opts.name = v;
        } else if (parseFlag(arg, "--start-directory=")) |v| {
            opts.start_directory = v;
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            target = arg;
        }
    }

    if (target == null) {
        writeJsonError(ew, "Usage", "new-window requires a target session");
        return error.MissingArgs;
    }

    const window_id = try server.newWindow(target.?, opts);
    defer server.allocator.free(window_id);
    try writeJson(w, .{ .window_id = window_id, .target = target.? });
}

fn cmdKillWindow(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    if (args.len == 0) {
        writeJsonError(ew, "Usage", "kill-window requires a target argument");
        return error.MissingArgs;
    }
    try server.killWindow(args[0]);
    try writeJson(w, .{ .ok = true, .target = args[0] });
}

fn cmdSplitWindow(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    var target: ?[]const u8 = null;
    var opts: libtmux.SplitWindowOptions = .{};

    for (args) |arg| {
        if (isFlag(arg, "--horizontal")) {
            opts.horizontal = true;
        } else if (parseFlag(arg, "--percent=")) |v| {
            opts.percent = std.fmt.parseInt(u8, v, 10) catch {
                writeJsonError(ew, "Usage", "invalid --percent value");
                return error.MissingArgs;
            };
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            target = arg;
        }
    }

    if (target == null) {
        writeJsonError(ew, "Usage", "split-window requires a target");
        return error.MissingArgs;
    }

    const pane_id = try server.splitWindow(target.?, opts);
    defer server.allocator.free(pane_id);
    try writeJson(w, .{ .pane_id = pane_id, .target = target.? });
}

fn cmdKillPane(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    if (args.len == 0) {
        writeJsonError(ew, "Usage", "kill-pane requires a target argument");
        return error.MissingArgs;
    }
    try server.killPane(args[0]);
    try writeJson(w, .{ .ok = true, .target = args[0] });
}

fn cmdSendKeys(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    var target: ?[]const u8 = null;
    var keys: ?[]const u8 = null;
    var opts: libtmux.SendKeysOptions = .{};

    for (args) |arg| {
        if (isFlag(arg, "--no-enter")) {
            opts.enter = false;
        } else if (isFlag(arg, "--literal")) {
            opts.literal = true;
        } else if (target == null) {
            target = arg;
        } else if (keys == null) {
            keys = arg;
        }
    }

    if (target == null or keys == null) {
        writeJsonError(ew, "Usage", "send-keys requires <target> <keys>");
        return error.MissingArgs;
    }

    try server.sendKeys(target.?, keys.?, opts);
    try writeJson(w, .{ .ok = true, .target = target.?, .keys = keys.? });
}

fn cmdCapturePane(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    var target: ?[]const u8 = null;
    var opts: libtmux.CapturePaneOptions = .{};

    for (args) |arg| {
        if (isFlag(arg, "--escape")) {
            opts.escape_sequences = true;
        } else if (isFlag(arg, "--history")) {
            opts.history = true;
        } else if (parseFlag(arg, "--start=")) |v| {
            opts.start = std.fmt.parseInt(i32, v, 10) catch {
                writeJsonError(ew, "Usage", "invalid --start value");
                return error.MissingArgs;
            };
        } else if (parseFlag(arg, "--end=")) |v| {
            opts.end = std.fmt.parseInt(i32, v, 10) catch {
                writeJsonError(ew, "Usage", "invalid --end value");
                return error.MissingArgs;
            };
        } else if (!std.mem.startsWith(u8, arg, "--")) {
            target = arg;
        }
    }

    if (target == null) {
        writeJsonError(ew, "Usage", "capture-pane requires a target");
        return error.MissingArgs;
    }

    const content = try server.capturePane(target.?, opts);
    defer server.allocator.free(content);
    try writeJson(w, .{ .target = target.?, .content = content });
}

fn cmdSetPaneTitle(server: *libtmux.Server, args: []const []const u8, w: *Writer, ew: *Writer) !void {
    var target: ?[]const u8 = null;
    var title: ?[]const u8 = null;

    for (args) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (target == null) {
                target = arg;
            } else if (title == null) {
                title = arg;
            }
        }
    }

    if (target == null or title == null) {
        writeJsonError(ew, "Usage", "set-pane-title requires <target> <title>");
        return error.MissingArgs;
    }

    try server.setPaneTitle(target.?, title.?);
    try writeJson(w, .{ .ok = true, .target = target.?, .title = title.? });
}

fn cmdKillServer(server: *libtmux.Server, w: *Writer) !void {
    try server.killServer();
    try writeJson(w, .{ .ok = true });
}

// ── Help ────────────────────────────────────────────────────────────

const usage_text =
    \\Usage: tmuxwrap <socket-name> <subcommand> [flags] [args]
    \\
    \\  socket-name:  tmux socket name ("default" for user default server)
    \\
    \\Subcommands:
    \\  version                    Show tmux version
    \\  is-running                 Check if tmux server is running
    \\  snapshot                   Snapshot full tmux state tree (sessions/windows/panes)
    \\  new-session                Create a new session
    \\                               --name=<name>  --window-name=<name>  --start-directory=<dir>
    \\  kill-session <target>      Kill a session by name or ID
    \\  new-window <target>        Create a new window in target session
    \\                               --name=<name>  --start-directory=<dir>
    \\  kill-window <target>       Kill a window
    \\  split-window <target>      Split a window/pane
    \\                               --horizontal  --percent=<N>
    \\  kill-pane <target>         Kill a pane
    \\  send-keys <target> <keys>  Send keys to a pane
    \\                               --no-enter  --literal
    \\  capture-pane <target>      Capture pane contents
    \\                               --escape  --start=<N>  --end=<N>  --history
    \\  set-pane-title <target> <title>  Set a pane title
    \\  kill-server                Kill the tmux server (all sessions)
    \\  help                       Show this help message
    \\
    \\Output: JSON on stdout (success), JSON on stderr (errors)
    \\
;

// ── Error mapping ───────────────────────────────────────────────────

fn tmuxErrorName(err: anyerror) []const u8 {
    return switch (err) {
        error.TmuxNotFound => "TmuxNotFound",
        error.TmuxCommandFailed => "TmuxCommandFailed",
        error.TmuxFailed => "TmuxFailed",
        error.SnapshotFailed => "SnapshotFailed",
        error.KillSessionFailed => "KillSessionFailed",
        error.KillWindowFailed => "KillWindowFailed",
        error.KillPaneFailed => "KillPaneFailed",
        error.KillServerFailed => "KillServerFailed",
        error.SendKeysFailed => "SendKeysFailed",
        error.SetPaneTitleFailed => "SetPaneTitleFailed",
        error.JsonWriteFailed => "JsonWriteFailed",
        else => "UnknownError",
    };
}

fn tmuxErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.TmuxNotFound => "tmux binary not found on PATH",
        error.TmuxCommandFailed => "tmux command returned non-zero exit code",
        error.TmuxFailed => "tmux process failed to start",
        error.SnapshotFailed => "failed to take tmux snapshot",
        error.KillSessionFailed => "failed to kill session",
        error.KillWindowFailed => "failed to kill window",
        error.KillPaneFailed => "failed to kill pane",
        error.KillServerFailed => "failed to kill server",
        error.SendKeysFailed => "failed to send keys",
        error.SetPaneTitleFailed => "failed to set pane title",
        error.MissingArgs => "missing required arguments",
        error.JsonWriteFailed => "failed to write JSON output",
        else => "unknown error",
    };
}

// ── Main ────────────────────────────────────────────────────────────

pub fn main() void {
    std.process.exit(run());
}

fn run() u8 {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // Collect args into a slice
    var arg_iter = std.process.args();
    var arg_list: std.ArrayList([]const u8) = .{};
    defer arg_list.deinit(gpa);

    while (arg_iter.next()) |arg| {
        arg_list.append(gpa, arg) catch return 1;
    }
    const argv = arg_list.items;

    return runWithArgs(gpa, argv);
}

fn runWithArgs(gpa: std.mem.Allocator, argv: []const []const u8) u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_file_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_file_writer.interface;

    // argv[0] = program name, argv[1] = socket-name, argv[2] = subcommand, argv[3..] = rest
    if (argv.len < 2) {
        stdout.writeAll(usage_text) catch {};
        stdout.flush() catch {};
        return 1;
    }

    // Check for bare "help" as first arg (no socket needed)
    if (std.mem.eql(u8, argv[1], "help") or std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h")) {
        stdout.writeAll(usage_text) catch {};
        stdout.flush() catch {};
        return 0;
    }

    if (argv.len < 3) {
        stdout.writeAll(usage_text) catch {};
        stdout.flush() catch {};
        return 1;
    }

    const socket_name_arg = argv[1];
    const sub_str = argv[2];
    const rest = if (argv.len > 3) argv[3..] else &[_][]const u8{};

    const sub = std.meta.stringToEnum(Subcommand, sub_str) orelse {
        writeJsonError(stderr, "UnknownSubcommand", sub_str);
        stderr.flush() catch {};
        return 1;
    };

    if (sub == .help) {
        stdout.writeAll(usage_text) catch {};
        stdout.flush() catch {};
        return 0;
    }

    // "default" means no socket arg (use tmux default server)
    const socket_name: ?[]const u8 = if (std.mem.eql(u8, socket_name_arg, "default")) null else socket_name_arg;

    var server = libtmux.Server.init(gpa, .{ .socket_name = socket_name }) catch |err| {
        writeJsonError(stderr, tmuxErrorName(err), tmuxErrorMessage(err));
        stderr.flush() catch {};
        return 1;
    };
    defer server.deinit();

    const result = switch (sub) {
        .version => cmdVersion(&server, stdout),
        .@"is-running" => cmdIsRunning(&server, stdout),
        .snapshot => cmdSnapshot(&server, stdout),
        .@"new-session" => cmdNewSession(&server, rest, stdout),
        .@"kill-session" => cmdKillSession(&server, rest, stdout, stderr),
        .@"new-window" => cmdNewWindow(&server, rest, stdout, stderr),
        .@"kill-window" => cmdKillWindow(&server, rest, stdout, stderr),
        .@"split-window" => cmdSplitWindow(&server, rest, stdout, stderr),
        .@"kill-pane" => cmdKillPane(&server, rest, stdout, stderr),
        .@"send-keys" => cmdSendKeys(&server, rest, stdout, stderr),
        .@"capture-pane" => cmdCapturePane(&server, rest, stdout, stderr),
        .@"set-pane-title" => cmdSetPaneTitle(&server, rest, stdout, stderr),
        .@"kill-server" => cmdKillServer(&server, stdout),
        .help => unreachable,
    };

    if (result) |_| {
        stdout.flush() catch {};
        return 0;
    } else |err| {
        // MissingArgs already wrote the error to stderr
        if (err != error.MissingArgs) {
            writeJsonError(stderr, tmuxErrorName(err), tmuxErrorMessage(err));
        }
        stderr.flush() catch {};
        return 1;
    }
}

test "main module imports libtmux" {
    _ = libtmux.Server;
    _ = libtmux.TmuxResult;
    _ = libtmux.CommandResponse;
    _ = libtmux.Notification;
    _ = libtmux.Snapshot;
    _ = libtmux.ServerOptions;
    _ = libtmux.protocol;
    _ = libtmux.snapshot;
    _ = libtmux.process;
}
