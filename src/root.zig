//! libtmux — Zig library for wrapping tmux operations.
//!
//! Supports both one-shot command execution and persistent control mode
//! connections (tmux -CC) with structured command/response and async
//! notification parsing.

const std = @import("std");

pub const which = @import("which.zig").which;
pub const protocol = @import("protocol.zig");
pub const snapshot = @import("snapshot.zig");
pub const process = @import("process.zig");
pub const Server = @import("Server.zig").Server;

// Re-export key types for convenience
pub const TmuxResult = @import("process.zig").TmuxResult;
pub const CommandResponse = protocol.CommandResponse;
pub const Notification = protocol.Notification;
pub const Snapshot = snapshot.Snapshot;

// Option types
pub const ServerOptions = @import("Server.zig").ServerOptions;
pub const ConnectOptions = @import("Server.zig").ConnectOptions;
pub const NewSessionOptions = @import("Server.zig").NewSessionOptions;
pub const NewWindowOptions = @import("Server.zig").NewWindowOptions;
pub const SplitWindowOptions = @import("Server.zig").SplitWindowOptions;
pub const SendKeysOptions = @import("Server.zig").SendKeysOptions;
pub const CapturePaneOptions = @import("Server.zig").CapturePaneOptions;

test {
    _ = @import("which.zig");
    _ = @import("protocol.zig");
    _ = @import("snapshot.zig");
    _ = @import("process.zig");
    _ = @import("Server.zig");
}
