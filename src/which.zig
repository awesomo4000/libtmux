const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Environ = std.process.Environ;

/// Find an executable on PATH. Returns the full path or null if not found.
/// Caller owns the returned slice.
///
/// `environ` supplies the process environment (PATH lookup). In `main`, use
/// `init.minimal.environ`; in tests, use `std.testing.environ`.
pub fn which(allocator: Allocator, io: Io, environ: Environ, name: []const u8) !?[]const u8 {
    const path_env = environ.getPosix("PATH") orelse return null;

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;

        // Build full path: dir/name
        const full_path = try std.fs.path.join(allocator, &.{ dir, name });
        defer allocator.free(full_path);

        // Check if the file exists and is executable
        if (isExecutable(io, full_path)) {
            return try allocator.dupe(u8, full_path);
        }
    }

    return null;
}

fn isExecutable(io: Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{ .execute = true }) catch return false;
    return true;
}

test "which finds a known binary" {
    const allocator = std.testing.allocator;

    // sh should exist on any unix system
    const result = try which(allocator, std.testing.io, std.testing.environ, "sh");
    try std.testing.expect(result != null);
    defer allocator.free(result.?);

    // Should be an absolute path containing "sh"
    try std.testing.expect(std.mem.endsWith(u8, result.?, "/sh"));
}

test "which returns null for nonexistent binary" {
    const allocator = std.testing.allocator;

    const result = try which(allocator, std.testing.io, std.testing.environ, "this_binary_definitely_does_not_exist_12345");
    try std.testing.expect(result == null);
}

test "which finds tmux if installed" {
    const allocator = std.testing.allocator;

    const result = try which(allocator, std.testing.io, std.testing.environ, "tmux");
    if (result) |path| {
        defer allocator.free(path);
        try std.testing.expect(std.mem.endsWith(u8, path, "/tmux"));
    }
    // If tmux isn't installed, that's fine — just skip
}
