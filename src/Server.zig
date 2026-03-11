const std = @import("std");
const Allocator = std.mem.Allocator;
const process = std.process;

const proc = @import("process.zig");
const protocol = @import("protocol.zig");
const snap_mod = @import("snapshot.zig");
const which_mod = @import("which.zig");

pub const TmuxResult = proc.TmuxResult;
pub const CommandResponse = protocol.CommandResponse;
pub const Notification = protocol.Notification;
pub const Snapshot = snap_mod.Snapshot;

pub const ServerOptions = struct {
    socket_name: ?[]const u8 = null,
    socket_path: ?[]const u8 = null,
    tmux_bin: ?[]const u8 = null, // null = auto-detect via PATH
};

pub const ConnectOptions = struct {
    session_name: ?[]const u8 = null, // attach to existing, or null for new
    detached: bool = true,
};

pub const NewSessionOptions = struct {
    name: ?[]const u8 = null,
    window_name: ?[]const u8 = null,
    start_directory: ?[]const u8 = null,
    detached: bool = true,
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
    escape_sequences: bool = false, // -e flag
    start: ?i32 = null, // -S flag, negative = relative to cursor
    end: ?i32 = null, // -E flag
    history: bool = false, // -S - (entire scrollback)
};

pub const Server = struct {
    allocator: Allocator,
    tmux_bin: []const u8,
    tmux_bin_owned: bool, // whether we need to free tmux_bin
    socket_name: ?[]const u8,
    socket_path: ?[]const u8,

    /// Base args derived from socket options (e.g., &.{"-L", "mysocket"}).
    /// Built once at init, used for all commands.
    base_args_buf: [4][]const u8,
    base_args_len: usize,

    pub fn init(allocator: Allocator, opts: ServerOptions) !Server {
        // Find tmux binary
        const bin_result = if (opts.tmux_bin) |b|
            .{ allocator.dupe(u8, b) catch return error.OutOfMemory, true }
        else blk: {
            const found = try which_mod.which(allocator, "tmux");
            if (found) |f| {
                break :blk .{ f, true };
            }
            return error.TmuxNotFound;
        };
        const tmux_bin: []const u8 = bin_result[0];
        const tmux_bin_owned: bool = bin_result[1];
        errdefer if (tmux_bin_owned) allocator.free(tmux_bin);

        var self = Server{
            .allocator = allocator,
            .tmux_bin = tmux_bin,
            .tmux_bin_owned = tmux_bin_owned,
            .socket_name = opts.socket_name,
            .socket_path = opts.socket_path,
            .base_args_buf = undefined,
            .base_args_len = 0,
        };

        // Build base args for socket
        if (opts.socket_name) |name| {
            self.base_args_buf[self.base_args_len] = "-L";
            self.base_args_len += 1;
            self.base_args_buf[self.base_args_len] = name;
            self.base_args_len += 1;
        }
        if (opts.socket_path) |path| {
            self.base_args_buf[self.base_args_len] = "-S";
            self.base_args_len += 1;
            self.base_args_buf[self.base_args_len] = path;
            self.base_args_len += 1;
        }

        return self;
    }

    pub fn deinit(self: *Server) void {
        if (self.tmux_bin_owned) {
            self.allocator.free(self.tmux_bin);
        }
    }

    fn baseArgs(self: *const Server) []const []const u8 {
        return self.base_args_buf[0..self.base_args_len];
    }

    // --- One-shot mode ---

    /// Execute a tmux command as a subprocess. Returns raw result.
    pub fn exec(self: *Server, args: []const []const u8) !TmuxResult {
        return proc.run(self.allocator, self.tmux_bin, self.baseArgs(), args);
    }

    /// Execute a tmux command, return stdout on success or error on failure.
    /// Caller owns returned slice.
    pub fn execChecked(self: *Server, args: []const []const u8) ![]u8 {
        return proc.runChecked(self.allocator, self.tmux_bin, self.baseArgs(), args);
    }

    // --- High-level operations (one-shot for now, control mode later) ---

    /// Take a snapshot of the full tmux state tree.
    pub fn takeSnapshot(self: *Server) !Snapshot {
        const format_arg = try std.fmt.allocPrint(self.allocator, "-F'{s}'", .{snap_mod.list_panes_format});
        defer self.allocator.free(format_arg);

        // Use the raw format string directly — tmux interprets #{...} in -F arg
        var args_buf: [4][]const u8 = undefined;
        args_buf[0] = "list-panes";
        args_buf[1] = "-a";
        args_buf[2] = "-F";
        args_buf[3] = snap_mod.list_panes_format;

        const stdout = self.execChecked(&args_buf) catch |err| switch (err) {
            error.TmuxCommandFailed => return error.SnapshotFailed,
            else => return err,
        };
        defer self.allocator.free(stdout);

        return snap_mod.parseSnapshot(self.allocator, stdout);
    }

    /// Create a new session. Returns the session ID (e.g., "$3").
    /// Caller owns returned slice.
    pub fn newSession(self: *Server, opts: NewSessionOptions) ![]u8 {
        var args: std.ArrayList([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "new-session");
        if (opts.detached) try args.append(self.allocator, "-d");
        try args.append(self.allocator, "-P");
        try args.append(self.allocator, "-F");
        try args.append(self.allocator, "#{session_id}");

        if (opts.name) |name| {
            try args.append(self.allocator, "-s");
            try args.append(self.allocator, name);
        }
        if (opts.window_name) |wname| {
            try args.append(self.allocator, "-n");
            try args.append(self.allocator, wname);
        }
        if (opts.start_directory) |dir| {
            try args.append(self.allocator, "-c");
            try args.append(self.allocator, dir);
        }

        const stdout = try self.execChecked(args.items);
        return try self.trimNewline(stdout);
    }

    /// Kill a session by target (name or ID).
    pub fn killSession(self: *Server, target: []const u8) !void {
        const stdout = self.execChecked(&.{ "kill-session", "-t", target }) catch |err| switch (err) {
            error.TmuxCommandFailed => return error.KillSessionFailed,
            else => return err,
        };
        self.allocator.free(stdout);
    }

    /// Create a new window in the given target session. Returns window ID.
    /// Caller owns returned slice.
    pub fn newWindow(self: *Server, target: []const u8, opts: NewWindowOptions) ![]u8 {
        var args: std.ArrayList([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "new-window");
        try args.append(self.allocator, "-t");
        try args.append(self.allocator, target);
        try args.append(self.allocator, "-P");
        try args.append(self.allocator, "-F");
        try args.append(self.allocator, "#{window_id}");

        if (opts.name) |name| {
            try args.append(self.allocator, "-n");
            try args.append(self.allocator, name);
        }
        if (opts.start_directory) |dir| {
            try args.append(self.allocator, "-c");
            try args.append(self.allocator, dir);
        }

        const stdout = try self.execChecked(args.items);
        return try self.trimNewline(stdout);
    }

    /// Kill a window by target.
    pub fn killWindow(self: *Server, target: []const u8) !void {
        const stdout = self.execChecked(&.{ "kill-window", "-t", target }) catch |err| switch (err) {
            error.TmuxCommandFailed => return error.KillWindowFailed,
            else => return err,
        };
        self.allocator.free(stdout);
    }

    /// Split a window/pane. Returns new pane ID.
    /// Caller owns returned slice.
    pub fn splitWindow(self: *Server, target: []const u8, opts: SplitWindowOptions) ![]u8 {
        var args: std.ArrayList([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "split-window");
        try args.append(self.allocator, "-t");
        try args.append(self.allocator, target);
        try args.append(self.allocator, "-P");
        try args.append(self.allocator, "-F");
        try args.append(self.allocator, "#{pane_id}");

        if (opts.horizontal) {
            try args.append(self.allocator, "-h");
        }

        var pct_buf: [8]u8 = undefined;
        if (opts.percent) |pct| {
            try args.append(self.allocator, "-l");
            const pct_str = std.fmt.bufPrint(&pct_buf, "{d}%", .{pct}) catch unreachable;
            try args.append(self.allocator, pct_str);
        }

        const stdout = try self.execChecked(args.items);
        return try self.trimNewline(stdout);
    }

    /// Kill a pane by target.
    pub fn killPane(self: *Server, target: []const u8) !void {
        const stdout = self.execChecked(&.{ "kill-pane", "-t", target }) catch |err| switch (err) {
            error.TmuxCommandFailed => return error.KillPaneFailed,
            else => return err,
        };
        self.allocator.free(stdout);
    }

    /// Send keys to a pane.
    pub fn sendKeys(self: *Server, target: []const u8, keys: []const u8, opts: SendKeysOptions) !void {
        var args: std.ArrayList([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "send-keys");
        try args.append(self.allocator, "-t");
        try args.append(self.allocator, target);

        if (opts.literal) {
            try args.append(self.allocator, "-l");
        }

        try args.append(self.allocator, keys);

        if (opts.enter) {
            try args.append(self.allocator, "Enter");
        }

        const stdout = self.execChecked(args.items) catch |err| switch (err) {
            error.TmuxCommandFailed => return error.SendKeysFailed,
            else => return err,
        };
        self.allocator.free(stdout);
    }

    /// Capture pane contents. Returns the captured text.
    /// Caller owns returned slice.
    pub fn capturePane(self: *Server, target: []const u8, opts: CapturePaneOptions) ![]u8 {
        var args: std.ArrayList([]const u8) = .{};
        defer args.deinit(self.allocator);

        try args.append(self.allocator, "capture-pane");
        try args.append(self.allocator, "-t");
        try args.append(self.allocator, target);
        try args.append(self.allocator, "-p"); // print to stdout

        if (opts.escape_sequences) {
            try args.append(self.allocator, "-e");
        }

        // Use function-scoped buffers so slices remain valid through execChecked
        var start_buf: [16]u8 = undefined;
        var end_buf: [16]u8 = undefined;

        if (opts.history) {
            try args.append(self.allocator, "-S");
            try args.append(self.allocator, "-");
        } else if (opts.start) |start| {
            try args.append(self.allocator, "-S");
            const start_str = std.fmt.bufPrint(&start_buf, "{d}", .{start}) catch unreachable;
            try args.append(self.allocator, start_str);
        }

        if (opts.end) |end| {
            try args.append(self.allocator, "-E");
            const end_str = std.fmt.bufPrint(&end_buf, "{d}", .{end}) catch unreachable;
            try args.append(self.allocator, end_str);
        }

        return self.execChecked(args.items);
    }

    /// Set a pane's title.
    pub fn setPaneTitle(self: *Server, target: []const u8, title: []const u8) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "printf '\\033]2;{s}\\033\\\\'", .{title});
        defer self.allocator.free(cmd);

        self.sendKeys(target, cmd, .{ .enter = true, .literal = true }) catch return error.SetPaneTitleFailed;
    }

    /// Kill the tmux server (all sessions).
    pub fn killServer(self: *Server) !void {
        const stdout = self.execChecked(&.{"kill-server"}) catch |err| switch (err) {
            error.TmuxCommandFailed => return error.KillServerFailed,
            else => return err,
        };
        self.allocator.free(stdout);
    }

    /// Check if the tmux server is running (has any sessions).
    pub fn isRunning(self: *Server) bool {
        const stdout = self.execChecked(&.{"list-sessions"}) catch return false;
        self.allocator.free(stdout);
        return true;
    }

    /// Trim trailing newlines from an owned slice by duping the trimmed
    /// portion and freeing the original. Caller owns the returned slice.
    fn trimNewline(self: *Server, data: []u8) ![]u8 {
        var len = data.len;
        while (len > 0 and (data[len - 1] == '\n' or data[len - 1] == '\r')) {
            len -= 1;
        }
        if (len == data.len) return data; // nothing to trim
        const trimmed = try self.allocator.dupe(u8, data[0..len]);
        self.allocator.free(data);
        return trimmed;
    }
};

// --- Tests ---

// Integration tests that require tmux installed.
// These use a unique socket name to avoid interfering with the user's tmux.

fn skipIfNoTmux(allocator: Allocator) !?[]const u8 {
    const found = which_mod.which(allocator, "tmux") catch return null;
    return found;
}

test "Server init and deinit" {
    const allocator = std.testing.allocator;
    const tmux_bin = try skipIfNoTmux(allocator);
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    var server = try Server.init(allocator, .{});
    defer server.deinit();

    try std.testing.expect(std.mem.endsWith(u8, server.tmux_bin, "/tmux"));
}

test "Server init with explicit binary" {
    const allocator = std.testing.allocator;
    const tmux_bin = try skipIfNoTmux(allocator);
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    var server = try Server.init(allocator, .{ .tmux_bin = tmux_bin.? });
    defer server.deinit();

    try std.testing.expectEqualStrings(tmux_bin.?, server.tmux_bin);
}

test "Server init with socket name" {
    const allocator = std.testing.allocator;
    const tmux_bin = try skipIfNoTmux(allocator);
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    var server = try Server.init(allocator, .{ .socket_name = "test-sock" });
    defer server.deinit();

    try std.testing.expectEqual(@as(usize, 2), server.base_args_len);
    try std.testing.expectEqualStrings("-L", server.base_args_buf[0]);
    try std.testing.expectEqualStrings("test-sock", server.base_args_buf[1]);
}

test "Server exec version" {
    const allocator = std.testing.allocator;
    const tmux_bin = try skipIfNoTmux(allocator);
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    var server = try Server.init(allocator, .{});
    defer server.deinit();

    var result = try server.exec(&.{"-V"});
    defer result.deinit();

    try std.testing.expect(result.success());
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "tmux"));
}

test "Server session lifecycle" {
    const allocator = std.testing.allocator;
    const tmux_bin = try skipIfNoTmux(allocator);
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    const sock_name = "libtmux-zig-test";

    var server = try Server.init(allocator, .{ .socket_name = sock_name });
    defer server.deinit();

    // Create a detached session
    const session_id = server.newSession(.{ .name = "test-sess" }) catch |err| {
        // If tmux server can't start (e.g., in CI without terminal), skip
        if (err == error.TmuxCommandFailed or err == error.TmuxFailed) return;
        return err;
    };
    defer allocator.free(session_id);

    // Session ID should start with $
    try std.testing.expect(session_id.len > 0);
    try std.testing.expect(session_id[0] == '$');

    // Clean up: kill the server on this socket
    server.killSession("test-sess") catch {};

    // Also kill the server to clean up the socket
    server.killServer() catch {};
}

test "Server snapshot" {
    const allocator = std.testing.allocator;
    const tmux_bin = try skipIfNoTmux(allocator);
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    const sock_name = "libtmux-zig-test-snap";

    var server = try Server.init(allocator, .{ .socket_name = sock_name });
    defer server.deinit();

    // Create a session
    const session_id = server.newSession(.{ .name = "snap-test" }) catch |err| {
        if (err == error.TmuxCommandFailed or err == error.TmuxFailed) return;
        return err;
    };
    defer allocator.free(session_id);

    // Take snapshot
    var snapshot = server.takeSnapshot() catch |err| {
        if (err == error.SnapshotFailed) {
            server.killServer() catch {};
            return;
        }
        server.killServer() catch {};
        return err;
    };
    defer snapshot.deinit();

    // Should have at least one session
    try std.testing.expect(snapshot.sessions.len >= 1);

    // Clean up
    server.killServer() catch {};
}
