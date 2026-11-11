//! Windows command channel: a named pipe, \\.\pipe\pet (or \\.\pipe\pet-NAME
//! for a named instance), that scripts/petctl.ps1 writes one-line commands
//! into. The server end is in PIPE_NOWAIT mode, so connecting and reading
//! never block the frame loop; one client at a time, and a client that finds
//! the pipe busy drops its command, like petctl does with a full FIFO.

const std = @import("std");
const events = @import("../events.zig");

pub const name = "named-pipe";

const HANDLE = ?*anyopaque;
const INVALID_HANDLE: HANDLE = @ptrFromInt(std.math.maxInt(usize));

const PIPE_ACCESS_INBOUND = 0x00000001;
const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
const PIPE_NOWAIT = 0x00000001;
const PIPE_REJECT_REMOTE_CLIENTS = 0x00000008;

const ERROR_BROKEN_PIPE = 109;
const ERROR_NO_DATA = 232;
const ERROR_PIPE_CONNECTED = 535;
const ERROR_PIPE_LISTENING = 536;

extern "kernel32" fn CreateNamedPipeW(name: [*:0]const u16, open_mode: u32, pipe_mode: u32, max_instances: u32, out_size: u32, in_size: u32, timeout: u32, sa: ?*anyopaque) callconv(.winapi) HANDLE;
extern "kernel32" fn ConnectNamedPipe(pipe: HANDLE, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn DisconnectNamedPipe(pipe: HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(file: HANDLE, buf: [*]u8, len: u32, read: *u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

pub const Channel = struct {
    pipe: HANDLE,
    connected: bool = false,
    path_buf: [64]u8 = undefined,
    path_len: usize = 0,
    carry: [512]u8 = undefined,
    carry_len: usize = 0,
    line: [512]u8 = undefined,

    pub fn open(instance: ?[]const u8) !Channel {
        var ch: Channel = .{ .pipe = INVALID_HANDLE };
        const p = if (instance) |n|
            try std.fmt.bufPrint(&ch.path_buf, "\\\\.\\pipe\\pet-{s}", .{n})
        else
            try std.fmt.bufPrint(&ch.path_buf, "\\\\.\\pipe\\pet", .{});
        ch.path_len = p.len;
        var wide: [64:0]u16 = undefined;
        for (p, 0..) |b, i| wide[i] = b; // ASCII: instance names are [A-Za-z0-9_-]
        wide[p.len] = 0;
        // FIRST_PIPE_INSTANCE: fail rather than share a name with another pet.
        ch.pipe = CreateNamedPipeW(&wide, PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 0, 4096, 0, null);
        if (ch.pipe == INVALID_HANDLE) return error.CannotCreatePipe;
        return ch;
    }

    pub fn close(self: *Channel) void {
        if (self.pipe == INVALID_HANDLE) return;
        _ = DisconnectNamedPipe(self.pipe);
        _ = CloseHandle(self.pipe);
        self.pipe = INVALID_HANDLE;
    }

    pub fn path(self: *const Channel) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Pipes are not descriptors the backend can wait on; the frame timer
    /// polls instead.
    pub fn wakeFd(self: *const Channel) ?c_int {
        _ = self;
        return null;
    }

    pub fn pollCommand(self: *Channel) ?events.Command {
        if (self.takeLine()) |line| return events.parse(line);
        self.fill();
        if (self.takeLine()) |line| return events.parse(line);
        return null;
    }

    fn fill(self: *Channel) void {
        if (self.pipe == INVALID_HANDLE) return;
        if (!self.connected) {
            if (ConnectNamedPipe(self.pipe, null) != 0) {
                self.connected = true;
            } else switch (GetLastError()) {
                // NO_DATA: the client already wrote and closed; its bytes
                // are still readable until ReadFile reports BROKEN_PIPE.
                ERROR_PIPE_CONNECTED, ERROR_NO_DATA => self.connected = true,
                ERROR_PIPE_LISTENING => return,
                else => return,
            }
        }
        if (self.carry_len == self.carry.len) self.carry_len = 0; // garbage line, drop it
        var n: u32 = 0;
        const space: u32 = @intCast(self.carry.len - self.carry_len);
        if (ReadFile(self.pipe, self.carry[self.carry_len..].ptr, space, &n, null) != 0) {
            self.carry_len += n;
            return;
        }
        switch (GetLastError()) {
            ERROR_NO_DATA => {}, // connected, nothing written yet
            else => {
                // BROKEN_PIPE or anything else: the client is gone; listen again.
                // A final line without its newline still counts.
                if (self.carry_len > 0 and self.carry_len < self.carry.len and
                    std.mem.indexOfScalar(u8, self.carry[0..self.carry_len], '\n') == null)
                {
                    self.carry[self.carry_len] = '\n';
                    self.carry_len += 1;
                }
                _ = DisconnectNamedPipe(self.pipe);
                self.connected = false;
            },
        }
    }

    fn takeLine(self: *Channel) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.carry[0..self.carry_len], '\n') orelse return null;
        var end = nl;
        if (end > 0 and self.carry[end - 1] == '\r') end -= 1; // PowerShell may send CRLF
        @memcpy(self.line[0..end], self.carry[0..end]);
        const rest = self.carry_len - (nl + 1);
        std.mem.copyForwards(u8, self.carry[0..rest], self.carry[nl + 1 .. self.carry_len]);
        self.carry_len = rest;
        return self.line[0..end];
    }
};
