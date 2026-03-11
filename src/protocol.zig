const std = @import("std");
const Allocator = std.mem.Allocator;

/// A command response from a %begin/%end or %begin/%error block.
pub const CommandResponse = struct {
    output: []const u8,
    success: bool, // true = %end, false = %error
    time: i64,
    command_number: u32,
};

/// All possible control mode notifications.
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

/// What kind of line we parsed.
pub const LineType = union(enum) {
    begin: BlockHeader,
    end: BlockHeader,
    @"error": BlockHeader,
    notification: Notification,
    /// A line of output inside a %begin/%end block.
    data: []const u8,
};

pub const BlockHeader = struct {
    time: i64,
    command_number: u32,
    flags: u32,
};

/// Parse a single line from tmux control mode stdout.
/// The input line should NOT include the trailing newline.
/// All returned slices point into the input line — no allocations.
pub fn parseLine(line: []const u8) !LineType {
    if (line.len == 0) return .{ .data = line };

    if (line[0] != '%') return .{ .data = line };

    // Try block delimiters first
    if (std.mem.startsWith(u8, line, "%begin ")) {
        return .{ .begin = try parseBlockHeader(line[7..]) };
    }
    if (std.mem.startsWith(u8, line, "%end ")) {
        return .{ .end = try parseBlockHeader(line[5..]) };
    }
    if (std.mem.startsWith(u8, line, "%error ")) {
        return .{ .@"error" = try parseBlockHeader(line[7..]) };
    }

    // Notifications
    if (std.mem.startsWith(u8, line, "%output ")) {
        return .{ .notification = try parseOutput(line[8..]) };
    }
    if (std.mem.startsWith(u8, line, "%window-add ")) {
        return .{ .notification = .{ .window_add = .{ .window_id = line[12..] } } };
    }
    if (std.mem.startsWith(u8, line, "%window-close ")) {
        return .{ .notification = .{ .window_close = .{ .window_id = line[14..] } } };
    }
    if (std.mem.startsWith(u8, line, "%window-renamed ")) {
        const rest = line[16..];
        const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
        return .{ .notification = .{ .window_renamed = .{
            .window_id = rest[0..sep],
            .name = rest[sep + 1 ..],
        } } };
    }
    if (std.mem.startsWith(u8, line, "%window-pane-changed ")) {
        const rest = line[21..];
        const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
        return .{ .notification = .{ .window_pane_changed = .{
            .window_id = rest[0..sep],
            .pane_id = rest[sep + 1 ..],
        } } };
    }
    if (std.mem.startsWith(u8, line, "%session-changed ")) {
        const rest = line[17..];
        const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
        return .{ .notification = .{ .session_changed = .{
            .session_id = rest[0..sep],
            .name = rest[sep + 1 ..],
        } } };
    }
    if (std.mem.startsWith(u8, line, "%session-renamed ")) {
        return .{ .notification = .{ .session_renamed = .{ .name = line[17..] } } };
    }
    if (std.mem.startsWith(u8, line, "%session-window-changed ")) {
        const rest = line[24..];
        const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
        return .{ .notification = .{ .session_window_changed = .{
            .session_id = rest[0..sep],
            .window_id = rest[sep + 1 ..],
        } } };
    }
    if (std.mem.startsWith(u8, line, "%sessions-changed")) {
        return .{ .notification = .{ .sessions_changed = {} } };
    }
    if (std.mem.startsWith(u8, line, "%layout-change ")) {
        const rest = line[15..];
        const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
        return .{ .notification = .{ .layout_change = .{
            .window_id = rest[0..sep],
            .layout = rest[sep + 1 ..],
        } } };
    }
    if (std.mem.startsWith(u8, line, "%pane-mode-changed ")) {
        return .{ .notification = .{ .pane_mode_changed = .{ .pane_id = line[19..] } } };
    }
    if (std.mem.startsWith(u8, line, "%client-detached ")) {
        return .{ .notification = .{ .client_detached = .{ .client = line[17..] } } };
    }
    if (std.mem.startsWith(u8, line, "%client-session-changed ")) {
        const rest = line[24..];
        const sep1 = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
        const after1 = rest[sep1 + 1 ..];
        const sep2 = std.mem.indexOfScalar(u8, after1, ' ') orelse return error.InvalidLine;
        return .{ .notification = .{ .client_session_changed = .{
            .client = rest[0..sep1],
            .session_id = after1[0..sep2],
            .name = after1[sep2 + 1 ..],
        } } };
    }
    if (std.mem.startsWith(u8, line, "%exit")) {
        const reason = if (line.len > 6) line[6..] else null;
        return .{ .notification = .{ .exit = .{ .reason = reason } } };
    }
    if (std.mem.startsWith(u8, line, "%unlinked-window-add ")) {
        return .{ .notification = .{ .unlinked_window_add = .{ .window_id = line[21..] } } };
    }
    if (std.mem.startsWith(u8, line, "%unlinked-window-close ")) {
        return .{ .notification = .{ .unlinked_window_close = .{ .window_id = line[23..] } } };
    }
    if (std.mem.startsWith(u8, line, "%unlinked-window-renamed ")) {
        return .{ .notification = .{ .unlinked_window_renamed = .{ .window_id = line[25..] } } };
    }
    if (std.mem.startsWith(u8, line, "%paste-buffer-changed ")) {
        return .{ .notification = .{ .paste_buffer_changed = .{ .name = line[22..] } } };
    }
    if (std.mem.startsWith(u8, line, "%paste-buffer-deleted ")) {
        return .{ .notification = .{ .paste_buffer_deleted = .{ .name = line[22..] } } };
    }
    if (std.mem.startsWith(u8, line, "%continue ")) {
        return .{ .notification = .{ .@"continue" = .{ .pane_id = line[10..] } } };
    }
    if (std.mem.startsWith(u8, line, "%pause ")) {
        return .{ .notification = .{ .pause = .{ .pane_id = line[7..] } } };
    }
    if (std.mem.startsWith(u8, line, "%message ")) {
        return .{ .notification = .{ .message = .{ .text = line[9..] } } };
    }
    if (std.mem.startsWith(u8, line, "%config-error ")) {
        return .{ .notification = .{ .config_error = .{ .error_text = line[14..] } } };
    }

    // Unknown %-line — treat as data rather than error, forward compat
    return .{ .data = line };
}

fn parseBlockHeader(rest: []const u8) !BlockHeader {
    var it = std.mem.splitScalar(u8, rest, ' ');

    const time_str = it.next() orelse return error.InvalidLine;
    const cmd_str = it.next() orelse return error.InvalidLine;
    const flags_str = it.next() orelse return error.InvalidLine;

    return .{
        .time = std.fmt.parseInt(i64, time_str, 10) catch return error.InvalidLine,
        .command_number = std.fmt.parseInt(u32, cmd_str, 10) catch return error.InvalidLine,
        .flags = std.fmt.parseInt(u32, flags_str, 10) catch return error.InvalidLine,
    };
}

fn parseOutput(rest: []const u8) !Notification {
    const sep = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.InvalidLine;
    return .{ .output = .{
        .pane_id = rest[0..sep],
        .data = rest[sep + 1 ..],
    } };
}

/// Decode tmux octal escapes in %output data.
/// tmux escapes non-printable characters and backslash as \xxx (octal).
/// Caller owns returned slice.
pub fn decodeOctalEscapes(allocator: Allocator, data: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == '\\' and i + 3 < data.len) {
            const d0 = data[i + 1];
            const d1 = data[i + 2];
            const d2 = data[i + 3];
            if (d0 >= '0' and d0 <= '3' and d1 >= '0' and d1 <= '7' and d2 >= '0' and d2 <= '7') {
                const val: u8 = (d0 - '0') * 64 + (d1 - '0') * 8 + (d2 - '0');
                try result.append(allocator, val);
                i += 4;
                continue;
            }
            // \\  -> backslash
            if (data[i + 1] == '\\') {
                try result.append(allocator, '\\');
                i += 2;
                continue;
            }
        }
        try result.append(allocator, data[i]);
        i += 1;
    }

    return try result.toOwnedSlice(allocator);
}

// --- Tests ---

test "parse %begin" {
    const result = try parseLine("%begin 1363006971 2 1");
    switch (result) {
        .begin => |h| {
            try std.testing.expectEqual(@as(i64, 1363006971), h.time);
            try std.testing.expectEqual(@as(u32, 2), h.command_number);
            try std.testing.expectEqual(@as(u32, 1), h.flags);
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %end" {
    const result = try parseLine("%end 1363006971 2 1");
    switch (result) {
        .end => |h| {
            try std.testing.expectEqual(@as(i64, 1363006971), h.time);
            try std.testing.expectEqual(@as(u32, 2), h.command_number);
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %error" {
    const result = try parseLine("%error 1363006971 3 1");
    switch (result) {
        .@"error" => |h| {
            try std.testing.expectEqual(@as(u32, 3), h.command_number);
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %output" {
    const result = try parseLine("%output %0 hello world");
    switch (result) {
        .notification => |n| switch (n) {
            .output => |o| {
                try std.testing.expectEqualStrings("%0", o.pane_id);
                try std.testing.expectEqualStrings("hello world", o.data);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %window-add" {
    const result = try parseLine("%window-add @3");
    switch (result) {
        .notification => |n| switch (n) {
            .window_add => |w| {
                try std.testing.expectEqualStrings("@3", w.window_id);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %window-close" {
    const result = try parseLine("%window-close @2");
    switch (result) {
        .notification => |n| switch (n) {
            .window_close => |w| {
                try std.testing.expectEqualStrings("@2", w.window_id);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %session-changed" {
    const result = try parseLine("%session-changed $1 work");
    switch (result) {
        .notification => |n| switch (n) {
            .session_changed => |s| {
                try std.testing.expectEqualStrings("$1", s.session_id);
                try std.testing.expectEqualStrings("work", s.name);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %session-renamed" {
    const result = try parseLine("%session-renamed newname");
    switch (result) {
        .notification => |n| switch (n) {
            .session_renamed => |s| {
                try std.testing.expectEqualStrings("newname", s.name);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %sessions-changed" {
    const result = try parseLine("%sessions-changed");
    switch (result) {
        .notification => |n| switch (n) {
            .sessions_changed => {},
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %layout-change" {
    const result = try parseLine("%layout-change @1 80x24,0,0,2 80x24,0,0,2 *");
    switch (result) {
        .notification => |n| switch (n) {
            .layout_change => |l| {
                try std.testing.expectEqualStrings("@1", l.window_id);
                try std.testing.expectEqualStrings("80x24,0,0,2 80x24,0,0,2 *", l.layout);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %window-renamed" {
    const result = try parseLine("%window-renamed @1 mywindow");
    switch (result) {
        .notification => |n| switch (n) {
            .window_renamed => |w| {
                try std.testing.expectEqualStrings("@1", w.window_id);
                try std.testing.expectEqualStrings("mywindow", w.name);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %window-pane-changed" {
    const result = try parseLine("%window-pane-changed @1 %3");
    switch (result) {
        .notification => |n| switch (n) {
            .window_pane_changed => |w| {
                try std.testing.expectEqualStrings("@1", w.window_id);
                try std.testing.expectEqualStrings("%3", w.pane_id);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %exit with reason" {
    const result = try parseLine("%exit server exited");
    switch (result) {
        .notification => |n| switch (n) {
            .exit => |e| {
                try std.testing.expectEqualStrings("server exited", e.reason.?);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %exit without reason" {
    const result = try parseLine("%exit");
    switch (result) {
        .notification => |n| switch (n) {
            .exit => |e| {
                try std.testing.expect(e.reason == null);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %pane-mode-changed" {
    const result = try parseLine("%pane-mode-changed %0");
    switch (result) {
        .notification => |n| switch (n) {
            .pane_mode_changed => |p| {
                try std.testing.expectEqualStrings("%0", p.pane_id);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse %client-session-changed" {
    const result = try parseLine("%client-session-changed /dev/pts/0 $1 work");
    switch (result) {
        .notification => |n| switch (n) {
            .client_session_changed => |c| {
                try std.testing.expectEqualStrings("/dev/pts/0", c.client);
                try std.testing.expectEqualStrings("$1", c.session_id);
                try std.testing.expectEqualStrings("work", c.name);
            },
            else => return error.UnexpectedResult,
        },
        else => return error.UnexpectedResult,
    }
}

test "parse plain data line" {
    const result = try parseLine("0: ksh* (1 panes) [80x24]");
    switch (result) {
        .data => |d| {
            try std.testing.expectEqualStrings("0: ksh* (1 panes) [80x24]", d);
        },
        else => return error.UnexpectedResult,
    }
}

test "parse empty line" {
    const result = try parseLine("");
    switch (result) {
        .data => |d| {
            try std.testing.expectEqualStrings("", d);
        },
        else => return error.UnexpectedResult,
    }
}

test "unknown %notification treated as data" {
    const result = try parseLine("%future-notification foo bar");
    switch (result) {
        .data => {},
        else => return error.UnexpectedResult,
    }
}

test "decode octal escapes" {
    const allocator = std.testing.allocator;

    // \012 = newline (10 decimal)
    const result = try decodeOctalEscapes(allocator, "hello\\012world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello\nworld", result);
}

test "decode octal escapes backslash" {
    const allocator = std.testing.allocator;

    const result = try decodeOctalEscapes(allocator, "path\\\\file");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("path\\file", result);
}

test "decode octal escapes no escapes" {
    const allocator = std.testing.allocator;

    const result = try decodeOctalEscapes(allocator, "plain text");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("plain text", result);
}
