//! The few operating-system calls shared code needs, with one answer per OS,
//! so main.zig and the state machine stay free of POSIX/Win32 specifics.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

const windows = builtin.os.tag == .windows;

const win = struct {
    extern "kernel32" fn QueryPerformanceCounter(count: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(freq: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
};

/// Monotonic clock in nanoseconds; only differences are meaningful.
pub fn nowNs() u64 {
    if (windows) {
        var count: i64 = 0;
        var freq: i64 = 1;
        _ = win.QueryPerformanceCounter(&count);
        _ = win.QueryPerformanceFrequency(&freq);
        const ucount: u128 = @intCast(count);
        return @intCast(ucount * 1_000_000_000 / @as(u128, @intCast(freq)));
    }
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(u64, @intCast(ts.tv_sec)) * 1_000_000_000 + @as(u64, @intCast(ts.tv_nsec));
}

pub fn pid() u32 {
    if (windows) return win.GetCurrentProcessId();
    return @intCast(c.getpid());
}

/// Environment variable, or null when unset.
pub fn getenv(name: [*:0]const u8) ?[]const u8 {
    return if (c.getenv(name)) |v| std.mem.span(v) else null;
}

test nowNs {
    const a = nowNs();
    const b = nowNs();
    try std.testing.expect(b >= a);
}
