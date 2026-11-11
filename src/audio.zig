//! Sound playback. The clips are embedded here and are the same everywhere;
//! how they get to a speaker is chosen by OS at compile time.
//!
//! Contract every implementation's `Audio` meets:
//!   init(enabled: bool) Audio          // never fails; falls back to silence
//!   play(*const Audio, clip: []const u8) void   // clip is a name from `clips`

const std = @import("std");
const builtin = @import("builtin");

pub const Clip = struct { name: []const u8, data: []const u8 };

/// Every sound a character may name in its `sound_*` fields.
pub const clips = [_]Clip{
    .{ .name = "meow", .data = @embedFile("assets/meow.wav") },
    .{ .name = "purr", .data = @embedFile("assets/purr.wav") },
    .{ .name = "hiss", .data = @embedFile("assets/hiss.wav") },
    .{ .name = "woof", .data = @embedFile("assets/woof.wav") },
    .{ .name = "pant", .data = @embedFile("assets/pant.wav") },
    .{ .name = "growl", .data = @embedFile("assets/growl.wav") },
    .{ .name = "squeak", .data = @embedFile("assets/squeak.wav") },
    .{ .name = "thump", .data = @embedFile("assets/thump.wav") },
};

const impl = switch (builtin.os.tag) {
    .windows => @import("audio/win.zig"),
    else => @import("audio/shell.zig"),
};

pub const name: []const u8 = impl.name;
pub const Audio = impl.Audio;

comptime {
    for ([_][]const u8{ "init", "play" }) |f| {
        if (!@hasDecl(Audio, f)) @compileError("audio " ++ name ++ ": Audio is missing `" ++ f ++ "`");
    }
}

test {
    std.testing.refAllDecls(@This());
}
