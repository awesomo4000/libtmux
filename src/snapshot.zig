const std = @import("std");
const Allocator = std.mem.Allocator;

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
    /// Raw buffer backing all string slices in the tree.
    _raw: []const u8,

    pub fn deinit(self: *Snapshot) void {
        for (self.sessions) |session| {
            for (session.windows) |window| {
                self.allocator.free(window.panes);
            }
            self.allocator.free(session.windows);
        }
        self.allocator.free(self.sessions);
        self.allocator.free(self._raw);
    }

    pub fn findPane(self: Snapshot, pane_id: []const u8) ?*const PaneInfo {
        for (self.sessions) |*session| {
            for (session.windows) |*window| {
                for (window.panes) |*pane| {
                    if (std.mem.eql(u8, pane.pane_id, pane_id)) return pane;
                }
            }
        }
        return null;
    }

    pub fn findWindow(self: Snapshot, window_id: []const u8) ?*const WindowInfo {
        for (self.sessions) |*session| {
            for (session.windows) |*window| {
                if (std.mem.eql(u8, window.window_id, window_id)) return window;
            }
        }
        return null;
    }

    pub fn findSession(self: Snapshot, session_id: []const u8) ?*const SessionInfo {
        for (self.sessions) |*session| {
            if (std.mem.eql(u8, session.session_id, session_id)) return session;
        }
        return null;
    }
};

/// The format string sent to tmux list-panes -a -F.
/// Fields are pipe-delimited.
pub const list_panes_format =
    "#{session_id}|#{session_name}|" ++
    "#{window_id}|#{window_index}|#{window_name}|#{window_layout}|" ++
    "#{pane_id}|#{pane_index}|#{pane_pid}|#{pane_current_command}|" ++
    "#{pane_current_path}|#{pane_width}|#{pane_height}|#{pane_active}";

const field_count = 14;

/// A flat record from one line of list-panes output.
const PaneRecord = struct {
    session_id: []const u8,
    session_name: []const u8,
    window_id: []const u8,
    window_index: []const u8,
    window_name: []const u8,
    window_layout: []const u8,
    pane_id: []const u8,
    pane_index: []const u8,
    pane_pid: []const u8,
    pane_current_command: []const u8,
    pane_current_path: []const u8,
    pane_width: []const u8,
    pane_height: []const u8,
    pane_active: []const u8,
};

fn parseRecord(line: []const u8) !PaneRecord {
    var fields: [field_count][]const u8 = undefined;
    var it = std.mem.splitScalar(u8, line, '|');
    var i: usize = 0;
    while (it.next()) |field| {
        if (i >= field_count) return error.TooManyFields;
        fields[i] = field;
        i += 1;
    }
    if (i != field_count) return error.WrongFieldCount;

    return .{
        .session_id = fields[0],
        .session_name = fields[1],
        .window_id = fields[2],
        .window_index = fields[3],
        .window_name = fields[4],
        .window_layout = fields[5],
        .pane_id = fields[6],
        .pane_index = fields[7],
        .pane_pid = fields[8],
        .pane_current_command = fields[9],
        .pane_current_path = fields[10],
        .pane_width = fields[11],
        .pane_height = fields[12],
        .pane_active = fields[13],
    };
}

fn makePaneInfo(rec: PaneRecord) PaneInfo {
    return .{
        .pane_id = rec.pane_id,
        .pane_index = std.fmt.parseInt(u16, rec.pane_index, 10) catch 0,
        .pane_pid = std.fmt.parseInt(u32, rec.pane_pid, 10) catch 0,
        .pane_current_command = rec.pane_current_command,
        .pane_current_path = rec.pane_current_path,
        .pane_width = std.fmt.parseInt(u16, rec.pane_width, 10) catch 0,
        .pane_height = std.fmt.parseInt(u16, rec.pane_height, 10) catch 0,
        .pane_active = std.mem.eql(u8, rec.pane_active, "1"),
        .window_id = rec.window_id,
        .session_id = rec.session_id,
    };
}

/// Parse the full output of `tmux list-panes -a -F '...'` into a Snapshot tree.
/// The raw_output is duped internally — caller can free their copy.
pub fn parseSnapshot(allocator: Allocator, raw_output: []const u8) !Snapshot {
    const raw = try allocator.dupe(u8, raw_output);
    errdefer allocator.free(raw);

    // First pass: parse all records into flat list
    var records: std.ArrayList(PaneRecord) = .empty;
    defer records.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const rec = try parseRecord(line);
        try records.append(allocator, rec);
    }

    if (records.items.len == 0) {
        return .{
            .sessions = try allocator.alloc(SessionInfo, 0),
            .allocator = allocator,
            ._raw = raw,
        };
    }

    // Second pass: build tree by iterating records and grouping
    // Records come sorted by session, then window, then pane from tmux.
    var session_list: std.ArrayList(SessionInfo) = .empty;
    errdefer {
        for (session_list.items) |s| {
            for (s.windows) |w| allocator.free(w.panes);
            allocator.free(s.windows);
        }
        session_list.deinit(allocator);
    }

    var window_list: std.ArrayList(WindowInfo) = .empty;
    defer window_list.deinit(allocator);

    var pane_list: std.ArrayList(PaneInfo) = .empty;
    defer pane_list.deinit(allocator);

    var prev_session_id: []const u8 = records.items[0].session_id;
    var prev_session_name: []const u8 = records.items[0].session_name;
    var prev_window_id: []const u8 = records.items[0].window_id;
    var prev_rec: PaneRecord = records.items[0];

    for (records.items) |rec| {
        const new_session = !std.mem.eql(u8, rec.session_id, prev_session_id);
        const new_window = new_session or !std.mem.eql(u8, rec.window_id, prev_window_id);

        if (new_window and pane_list.items.len > 0) {
            // Flush accumulated panes into a window
            try window_list.append(allocator, .{
                .window_id = prev_rec.window_id,
                .window_index = std.fmt.parseInt(u16, prev_rec.window_index, 10) catch 0,
                .window_name = prev_rec.window_name,
                .window_layout = prev_rec.window_layout,
                .session_id = prev_rec.session_id,
                .panes = try pane_list.toOwnedSlice(allocator),
            });
        }

        if (new_session and window_list.items.len > 0) {
            // Flush accumulated windows into a session
            try session_list.append(allocator, .{
                .session_id = prev_session_id,
                .session_name = prev_session_name,
                .windows = try window_list.toOwnedSlice(allocator),
            });
        }

        if (new_session) {
            prev_session_id = rec.session_id;
            prev_session_name = rec.session_name;
        }
        if (new_window) {
            prev_window_id = rec.window_id;
        }

        try pane_list.append(allocator, makePaneInfo(rec));
        prev_rec = rec;
    }

    // Flush the last window and session
    if (pane_list.items.len > 0) {
        try window_list.append(allocator, .{
            .window_id = prev_rec.window_id,
            .window_index = std.fmt.parseInt(u16, prev_rec.window_index, 10) catch 0,
            .window_name = prev_rec.window_name,
            .window_layout = prev_rec.window_layout,
            .session_id = prev_rec.session_id,
            .panes = try pane_list.toOwnedSlice(allocator),
        });
    }
    if (window_list.items.len > 0) {
        try session_list.append(allocator, .{
            .session_id = prev_session_id,
            .session_name = prev_session_name,
            .windows = try window_list.toOwnedSlice(allocator),
        });
    }

    return .{
        .sessions = try session_list.toOwnedSlice(allocator),
        .allocator = allocator,
        ._raw = raw,
    };
}

// --- Tests ---

test "parseRecord valid line" {
    const line = "$0|main|@0|0|bash|b25f,80x24,0,0,0|%0|0|12345|bash|/home/user|80|24|1";
    const rec = try parseRecord(line);
    try std.testing.expectEqualStrings("$0", rec.session_id);
    try std.testing.expectEqualStrings("main", rec.session_name);
    try std.testing.expectEqualStrings("@0", rec.window_id);
    try std.testing.expectEqualStrings("0", rec.window_index);
    try std.testing.expectEqualStrings("bash", rec.window_name);
    try std.testing.expectEqualStrings("%0", rec.pane_id);
    try std.testing.expectEqualStrings("12345", rec.pane_pid);
    try std.testing.expectEqualStrings("80", rec.pane_width);
    try std.testing.expectEqualStrings("24", rec.pane_height);
    try std.testing.expectEqualStrings("1", rec.pane_active);
}

test "parseRecord wrong field count" {
    const line = "$0|main|@0";
    const result = parseRecord(line);
    try std.testing.expectError(error.WrongFieldCount, result);
}

test "parseSnapshot single session single pane" {
    const allocator = std.testing.allocator;
    const output = "$0|main|@0|0|bash|b25f,80x24,0,0,0|%0|0|12345|bash|/home/user|80|24|1\n";
    var snap = try parseSnapshot(allocator, output);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 1), snap.sessions.len);
    try std.testing.expectEqualStrings("$0", snap.sessions[0].session_id);
    try std.testing.expectEqualStrings("main", snap.sessions[0].session_name);
    try std.testing.expectEqual(@as(usize, 1), snap.sessions[0].windows.len);
    try std.testing.expectEqualStrings("@0", snap.sessions[0].windows[0].window_id);
    try std.testing.expectEqual(@as(usize, 1), snap.sessions[0].windows[0].panes.len);

    const pane = snap.sessions[0].windows[0].panes[0];
    try std.testing.expectEqualStrings("%0", pane.pane_id);
    try std.testing.expectEqual(@as(u16, 80), pane.pane_width);
    try std.testing.expectEqual(@as(u16, 24), pane.pane_height);
    try std.testing.expect(pane.pane_active);
}

test "parseSnapshot multiple panes in one window" {
    const allocator = std.testing.allocator;
    const output =
        "$0|main|@0|0|bash|b25f,80x24,0,0,0|%0|0|12345|bash|/home/user|40|24|1\n" ++
        "$0|main|@0|0|bash|b25f,80x24,0,0,0|%1|1|12346|vim|/home/user|40|24|0\n";
    var snap = try parseSnapshot(allocator, output);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 1), snap.sessions.len);
    try std.testing.expectEqual(@as(usize, 1), snap.sessions[0].windows.len);
    try std.testing.expectEqual(@as(usize, 2), snap.sessions[0].windows[0].panes.len);
    try std.testing.expectEqualStrings("%0", snap.sessions[0].windows[0].panes[0].pane_id);
    try std.testing.expectEqualStrings("%1", snap.sessions[0].windows[0].panes[1].pane_id);
}

test "parseSnapshot multiple windows" {
    const allocator = std.testing.allocator;
    const output =
        "$0|main|@0|0|bash|layout0|%0|0|100|bash|/home|80|24|1\n" ++
        "$0|main|@1|1|vim|layout1|%1|0|101|vim|/home|80|24|1\n";
    var snap = try parseSnapshot(allocator, output);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 1), snap.sessions.len);
    try std.testing.expectEqual(@as(usize, 2), snap.sessions[0].windows.len);
    try std.testing.expectEqualStrings("@0", snap.sessions[0].windows[0].window_id);
    try std.testing.expectEqualStrings("@1", snap.sessions[0].windows[1].window_id);
}

test "parseSnapshot multiple sessions" {
    const allocator = std.testing.allocator;
    const output =
        "$0|work|@0|0|bash|layout0|%0|0|100|bash|/home|80|24|1\n" ++
        "$1|play|@1|0|zsh|layout1|%1|0|101|zsh|/tmp|80|24|1\n";
    var snap = try parseSnapshot(allocator, output);
    defer snap.deinit();

    try std.testing.expectEqual(@as(usize, 2), snap.sessions.len);
    try std.testing.expectEqualStrings("$0", snap.sessions[0].session_id);
    try std.testing.expectEqualStrings("work", snap.sessions[0].session_name);
    try std.testing.expectEqualStrings("$1", snap.sessions[1].session_id);
    try std.testing.expectEqualStrings("play", snap.sessions[1].session_name);
}

test "findPane" {
    const allocator = std.testing.allocator;
    const output =
        "$0|main|@0|0|bash|layout0|%0|0|100|bash|/home|80|24|1\n" ++
        "$0|main|@0|0|bash|layout0|%1|1|101|vim|/home|40|24|0\n";
    var snap = try parseSnapshot(allocator, output);
    defer snap.deinit();

    const pane = snap.findPane("%1");
    try std.testing.expect(pane != null);
    try std.testing.expectEqualStrings("vim", pane.?.pane_current_command);

    const missing = snap.findPane("%99");
    try std.testing.expect(missing == null);
}

test "parseSnapshot empty input" {
    const allocator = std.testing.allocator;
    var snap = try parseSnapshot(allocator, "");
    defer snap.deinit();
    try std.testing.expectEqual(@as(usize, 0), snap.sessions.len);
}

test "list_panes_format has correct field count" {
    var count: usize = 0;
    for (list_panes_format) |c| {
        if (c == '|') count += 1;
    }
    // pipe-delimited: field_count - 1 pipes
    try std.testing.expectEqual(@as(usize, field_count - 1), count);
}
