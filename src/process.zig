const std = @import("std");
const Allocator = std.mem.Allocator;
const process = std.process;

/// Result of running a tmux subprocess (one-shot mode).
pub const TmuxResult = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
    allocator: Allocator,

    pub fn deinit(self: *TmuxResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }

    pub fn success(self: TmuxResult) bool {
        return self.exit_code == 0;
    }
};

/// Maximum bytes to capture from stdout/stderr.
const max_output_bytes: usize = 10 * 1024 * 1024; // 10 MiB

/// Run tmux with the given arguments. Caller owns returned TmuxResult.
///
/// `tmux_bin` is the path to the tmux binary.
/// `base_args` are inserted before `args` (e.g. socket flags: -L name or -S path).
/// `args` are the tmux subcommand and its arguments.
pub fn run(
    allocator: Allocator,
    tmux_bin: []const u8,
    base_args: []const []const u8,
    args: []const []const u8,
) !TmuxResult {
    // Build full argv: [tmux_bin] ++ base_args ++ args
    var full_argv: std.ArrayList([]const u8) = .{};
    defer full_argv.deinit(allocator);
    try full_argv.ensureTotalCapacity(allocator, 1 + base_args.len + args.len);
    full_argv.appendAssumeCapacity(tmux_bin);
    full_argv.appendSliceAssumeCapacity(base_args);
    full_argv.appendSliceAssumeCapacity(args);

    const result = process.Child.run(.{
        .allocator = allocator,
        .argv = full_argv.items,
        .max_output_bytes = max_output_bytes,
    }) catch return error.TmuxFailed;

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => return error.TmuxFailed,
    };

    return .{
        .exit_code = exit_code,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .allocator = allocator,
    };
}

/// Run tmux and return stdout on success, or error on non-zero exit.
/// Frees stderr on success; on error, stderr content is lost.
pub fn runChecked(
    allocator: Allocator,
    tmux_bin: []const u8,
    base_args: []const []const u8,
    args: []const []const u8,
) ![]u8 {
    var result = try run(allocator, tmux_bin, base_args, args);
    if (!result.success()) {
        result.deinit();
        return error.TmuxCommandFailed;
    }
    // Free stderr, return stdout
    allocator.free(result.stderr);
    return result.stdout;
}

// --- Tests ---

test "run tmux --version" {
    const allocator = std.testing.allocator;

    // Find tmux first
    const tmux_bin = @import("which.zig").which(allocator, "tmux") catch null;
    if (tmux_bin == null) return; // skip if tmux not installed
    defer allocator.free(tmux_bin.?);

    var result = try run(allocator, tmux_bin.?, &.{}, &.{"-V"});
    defer result.deinit();

    try std.testing.expect(result.success());
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "tmux"));
}

test "run tmux with bad command returns non-zero exit" {
    const allocator = std.testing.allocator;

    const tmux_bin = @import("which.zig").which(allocator, "tmux") catch null;
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    var result = try run(allocator, tmux_bin.?, &.{}, &.{"not-a-real-command-xyz"});
    defer result.deinit();

    try std.testing.expect(!result.success());
}

test "runChecked tmux version" {
    const allocator = std.testing.allocator;

    const tmux_bin = @import("which.zig").which(allocator, "tmux") catch null;
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    const stdout = try runChecked(allocator, tmux_bin.?, &.{}, &.{"-V"});
    defer allocator.free(stdout);

    try std.testing.expect(std.mem.startsWith(u8, stdout, "tmux"));
}

test "runChecked returns error on failure" {
    const allocator = std.testing.allocator;

    const tmux_bin = @import("which.zig").which(allocator, "tmux") catch null;
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    const result = runChecked(allocator, tmux_bin.?, &.{}, &.{"not-a-real-command-xyz"});
    try std.testing.expectError(error.TmuxCommandFailed, result);
}

test "run with base_args" {
    const allocator = std.testing.allocator;

    const tmux_bin = @import("which.zig").which(allocator, "tmux") catch null;
    if (tmux_bin == null) return;
    defer allocator.free(tmux_bin.?);

    // -L with a non-existent socket name, just running -V should still work
    // since -V exits before connecting
    var result = try run(allocator, tmux_bin.?, &.{ "-L", "libtmux-test-nonexistent" }, &.{"-V"});
    defer result.deinit();

    try std.testing.expect(result.success());
    try std.testing.expect(std.mem.startsWith(u8, result.stdout, "tmux"));
}
