const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = std.fs;

/// Find an executable on PATH. Returns the full path or null if not found.
/// Caller owns the returned slice.
pub fn which(allocator: Allocator, name: []const u8) !?[]const u8 {
    const path_env = std.posix.getenv("PATH") orelse return null;

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        // Build full path: dir/name
        const full_path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(full_path);

        // Check if the file exists and is executable
        if (isExecutable(full_path)) {
            return try allocator.dupe(u8, full_path);
        }
    }

    return null;
}

fn isExecutable(path: []const u8) bool {
    // Use Zig's posix wrapper (works without libc on Linux via raw syscall)
    std.posix.faccessat(std.posix.AT.FDCWD, path, std.posix.X_OK, 0) catch return false;
    return true;
}

test "which finds a known binary" {
    const allocator = std.testing.allocator;

    // sh should exist on any unix system
    const result = try which(allocator, "sh");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    // Should be an absolute path containing "sh"
    try std.testing.expect(std.mem.endsWith(u8, result.?, "/sh"));
}

test "which returns null for nonexistent binary" {
    const allocator = std.testing.allocator;

    const result = try which(allocator, "this_binary_definitely_does_not_exist_12345");
    try std.testing.expect(result == null);
}

test "which finds tmux if installed" {
    const allocator = std.testing.allocator;

    const result = try which(allocator, "tmux");
    if (result) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "/tmux"));
    }
    // If tmux isn't installed, that's fine — just skip
}
