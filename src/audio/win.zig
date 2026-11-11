//! Windows audio: PlaySound straight from the embedded WAV bytes. Async and
//! fire-and-forget; a new clip cuts off the one still playing, which suits
//! the short reactions.

const std = @import("std");
const audio = @import("../audio.zig");

pub const name = "winmm";

const SND_ASYNC = 0x0001;
const SND_NODEFAULT = 0x0002;
const SND_MEMORY = 0x0004;

extern "winmm" fn PlaySoundA(sound: ?*const anyopaque, module: ?*anyopaque, flags: u32) callconv(.winapi) c_int;

pub const Audio = struct {
    enabled: bool,

    pub fn init(enabled: bool) Audio {
        return .{ .enabled = enabled };
    }

    pub fn play(self: *const Audio, clip: []const u8) void {
        if (!self.enabled) return;
        for (audio.clips) |known| {
            if (!std.mem.eql(u8, known.name, clip)) continue;
            // The data is static, as SND_ASYNC with SND_MEMORY requires.
            _ = PlaySoundA(known.data.ptr, null, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
            return;
        }
    }
};
