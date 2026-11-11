//! The command channel: how petctl, shell hooks and other programs send
//! one-line commands to a running pet. Chosen by OS at compile time; the
//! parser those lines go through is in events.zig and is shared.
//!
//! Contract every implementation's `Channel` meets:
//!   open(name: ?[]const u8) !Channel   // instance name selects the address
//!   close(*Channel) void               // also removes the address, so senders
//!                                      // see "no pet running" afterwards
//!   path(*const Channel) []const u8    // human-readable address for the log
//!   pollCommand(*Channel) ?Command     // next parsed command, null if none
//!   wakeFd(*const Channel) ?c_int      // descriptor for backend.wait, if any

const std = @import("std");
const builtin = @import("builtin");
const events = @import("events.zig");

const impl = switch (builtin.os.tag) {
    .windows => @import("channel/win_pipe.zig"),
    else => @import("channel/fifo.zig"),
};

pub const name: []const u8 = impl.name;
pub const Channel = impl.Channel;

comptime {
    for ([_][]const u8{ "open", "close", "path", "pollCommand", "wakeFd" }) |f| {
        if (!@hasDecl(Channel, f)) @compileError("channel " ++ name ++ ": Channel is missing `" ++ f ++ "`");
    }
}

test {
    std.testing.refAllDecls(@This());
}
