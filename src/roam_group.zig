//! Named roaming groups share a small private file. Non-blocking flock keeps
//! updates consistent across pet processes without electing a permanent leader.
//! Any member can advance a due plan; a busy member joins when it is free again.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const geometry = @import("monitors.zig");

const magic: u64 = 0x4d50524752503031; // MPRGRP01: versioned local state layout
const stale_ms: i64 = 3000;
const max_members = 32;

const Member = extern struct { id: u64, seen_ms: i64, size: u32, reserved: u32 };
const Shared = extern struct {
    magic: u64,
    seen_ms: i64,
    visit_ms: i64,
    walk_ms: i64,
    revision: u64,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    target: u32,
    reserved: u32,
    members: [max_members]Member,

    fn monitor(self: *const Shared) geometry.Monitor {
        return .{ .x = self.x, .y = self.y, .w = self.w, .h = self.h };
    }

    fn select(self: *Shared, m: geometry.Monitor) void {
        self.x = m.x;
        self.y = m.y;
        self.w = m.w;
        self.h = m.h;
    }

    fn fresh(now: i64, m: geometry.Monitor, rand: std.Random) Shared {
        var s = std.mem.zeroes(Shared);
        s.magic = magic;
        s.seen_ms = now;
        s.visit_ms = now + visitDelay(rand);
        s.walk_ms = now + walkDelay(rand);
        s.revision = 1;
        s.select(m);
        s.target = rand.uintLessThan(u32, 600001) + 200000;
        return s;
    }

    fn valid(self: *const Shared, now: i64) bool {
        if (self.magic != magic or self.revision == 0 or self.target > 1000000 or
            self.w <= 0 or self.h <= 0 or self.w > 1048576 or self.h > 1048576 or
            self.seen_ms > now or self.seen_ms < now - stale_ms or
            self.visit_ms > now + 60000 or self.walk_ms > now + 20000) return false;
        for (self.members) |m| {
            if (m.id != 0 and (m.size == 0 or m.size > 4096 or m.seen_ms > now)) return false;
        }
        return true;
    }

    fn advance(self: *Shared, id: u64, size: u32, now: i64, monitors: *const geometry.Monitors, requested: ?geometry.Monitor, ready: bool, rand: std.Random) !Plan {
        var exists = false;
        for (monitors.items[0..monitors.len]) |m| if (std.meta.eql(m, self.monitor())) {
            exists = true;
            break;
        };
        // An incompatible peer must not rewrite everybody else's plan at each
        // heartbeat. The caller logs once and continues independently.
        if (!exists) return error.IncompatibleMonitors;
        var slot: ?usize = null;
        var changed = false;
        for (&self.members, 0..) |*member, i| {
            if (member.id != 0 and member.seen_ms < now - stale_ms) {
                member.* = std.mem.zeroes(Member);
                changed = true;
            }
            if (member.id == id) slot = i;
        }
        if (slot == null) {
            for (self.members, 0..) |member, i| {
                if (member.id == 0) {
                    slot = i;
                    changed = true;
                    break;
                }
            }
        }
        const own = slot orelse return error.GroupFull;
        self.members[own] = .{ .id = id, .seen_ms = now, .size = size, .reserved = 0 };
        self.seen_ms = now;
        if (requested) |m| {
            if (!std.meta.eql(m, self.monitor())) {
                self.select(m);
                self.visit_ms = now + visitDelay(rand);
                changed = true;
            }
        } else if (ready and now >= self.visit_ms and monitors.len > 1) {
            var candidates: [32]geometry.Monitor = undefined;
            var count: usize = 0;
            for (monitors.items[0..monitors.len]) |m| {
                if (std.meta.eql(m, self.monitor())) continue;
                candidates[count] = m;
                count += 1;
            }
            if (count > 0) {
                self.select(candidates[rand.uintLessThan(usize, count)]);
                changed = true;
            }
            self.visit_ms = now + visitDelay(rand);
        }
        if (changed or (ready and now >= self.walk_ms)) {
            self.target = rand.uintLessThan(u32, 600001) + 200000;
            self.walk_ms = now + walkDelay(rand);
            self.revision +%= 1;
            if (self.revision == 0) self.revision = 1;
        }
        return .{ .monitor = self.monitor(), .revision = self.revision, .target_x = self.destination(own) };
    }

    fn destination(self: *const Shared, own: usize) f32 {
        var total: f32 = 0;
        var before: f32 = 0;
        var count: usize = 0;
        var preceding: usize = 0;
        for (self.members, 0..) |m, i| {
            if (m.id == 0) continue;
            const width: f32 = @floatFromInt(m.size);
            total += width;
            count += 1;
            if (i < own) {
                before += width;
                preceding += 1;
            }
        }
        const width: f32 = @floatFromInt(self.w);
        const body: f32 = @floatFromInt(self.members[own].size);
        const gap: f32 = if (count > 1) @min(16, @max(0, (width - total) / @as(f32, @floatFromInt(count - 1)))) else 0;
        const span = total + gap * @as(f32, @floatFromInt(count - 1));
        const wanted = @as(f32, @floatFromInt(self.target)) / 1000000 * width - span / 2;
        const base = std.math.clamp(wanted, 0, @max(0, width - span));
        // When a group is too wide, shrink the spacing to keep every pet visible.
        const offset = before + gap * @as(f32, @floatFromInt(preceding));
        const fitted = if (span > width and total > body) offset * @max(0, width - body) / (total - body) else offset;
        return std.math.clamp(base + fitted, 0, @max(0, width - body)) + body / 2;
    }
};

pub const Plan = struct { monitor: geometry.Monitor, revision: u64, target_x: f32 };

/// Windows has no flock; a group there would need LockFileEx on a file in
/// %LOCALAPPDATA%. Until then `--roam-group` reports this and the pet roams alone.
pub const Group = if (builtin.os.tag == .windows) UnsupportedGroup else PosixGroup;

const UnsupportedGroup = struct {
    pub fn open(name: []const u8, nonce: u64) !UnsupportedGroup {
        _ = name;
        _ = nonce;
        return error.RoamingGroupsUnsupportedOnWindows;
    }
    pub fn close(self: *UnsupportedGroup) void {
        _ = self;
    }
    pub fn poll(self: *UnsupportedGroup, now: i64, size: u32, monitors: *const geometry.Monitors, current: geometry.Monitor, requested: ?geometry.Monitor, ready: bool, rand: std.Random) !?Plan {
        _ = .{ self, now, size, monitors, current, requested, ready, rand };
        return null;
    }
};

const PosixGroup = struct {
    fd: c_int,
    id: u64,
    next_poll_ms: i64 = 0,
    pending_monitor: ?geometry.Monitor = null,

    pub fn open(name: []const u8, nonce: u64) !PosixGroup {
        const dir: []const u8 = if (c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
        var buf: [512:0]u8 = undefined;
        const path = try std.mem.printSentinel(&buf, "{s}/pet-roam-{d}-{s}.state", .{ dir, c.geteuid(), name }, 0);
        const fd = c.open(path.ptr, c.O_CREAT | c.O_RDWR | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return error.CannotOpenRoamingGroup;
        errdefer _ = c.close(fd);
        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_mode & c.S_IFMT != c.S_IFREG or
            stat.st_uid != c.geteuid() or stat.st_mode & 0o077 != 0 or stat.st_nlink != 1) return error.InvalidRoamingGroupFile;
        return .{ .fd = fd, .id = if (nonce == 0) 1 else nonce };
    }

    pub fn close(self: *PosixGroup) void {
        _ = c.close(self.fd);
        // Keep the inode: unlinking can split a group when a new member is joining.
        // Its heartbeat expires after three seconds with no active members.
    }

    pub fn poll(self: *PosixGroup, now: i64, size: u32, monitors: *const geometry.Monitors, current: geometry.Monitor, requested: ?geometry.Monitor, ready: bool, rand: std.Random) !?Plan {
        if (requested) |m| self.pending_monitor = m;
        if (self.pending_monitor) |m| {
            var exists = false;
            for (monitors.items[0..monitors.len]) |available| if (std.meta.eql(available, m)) {
                exists = true;
                break;
            };
            if (!exists) self.pending_monitor = null;
        }
        if (self.pending_monitor == null and now < self.next_poll_ms) return null;
        self.next_poll_ms = now + 200;
        if (c.flock(self.fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            const err = std.posix.errno(@as(c_int, -1));
            if (err == .AGAIN or err == .INTR) return null;
            return error.CannotLockRoamingGroup;
        }
        defer _ = c.flock(self.fd, c.LOCK_UN);
        // Capture time after taking the lock: another process may have written
        // a heartbeat newer than the caller's frame timestamp.
        var ts: c.struct_timespec = undefined;
        if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return error.CannotReadClock;
        const shared_now = ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
        var state: Shared = undefined;
        const read = c.pread(self.fd, &state, @sizeOf(Shared), 0);
        if (read < 0) return error.CannotReadRoamingGroup;
        if (read != @sizeOf(Shared) or !state.valid(shared_now)) state = Shared.fresh(shared_now, current, rand);
        const plan = try state.advance(self.id, size, shared_now, monitors, self.pending_monitor, ready, rand);
        if (c.pwrite(self.fd, &state, @sizeOf(Shared), 0) != @sizeOf(Shared)) return error.CannotWriteRoamingGroup;
        self.pending_monitor = null;
        return plan;
    }
};

fn visitDelay(rand: std.Random) i64 {
    return 30000 + @as(i64, rand.uintLessThan(u32, 30001));
}
fn walkDelay(rand: std.Random) i64 {
    return 8000 + @as(i64, rand.uintLessThan(u32, 8001));
}

test "group members share plans, spread mixed sizes and survive a missing member" {
    var prng = std.Random.DefaultPrng.init(4);
    const first: geometry.Monitor = .{ .x = 710, .y = 1080, .w = 1366, .h = 768 };
    const second: geometry.Monitor = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    var monitors: geometry.Monitors = .{};
    monitors.add(first);
    monitors.add(second);
    var state = Shared.fresh(10000, first, prng.random());
    _ = try state.advance(1, 64, 10000, &monitors, null, true, prng.random());
    const b = try state.advance(2, 96, 10000, &monitors, null, true, prng.random());
    const a = try state.advance(1, 64, 10001, &monitors, null, true, prng.random());
    try std.testing.expectEqual(b.revision, a.revision);
    try std.testing.expect(b.target_x - a.target_x >= 80);
    const changed = try state.advance(1, 64, 10002, &monitors, second, true, prng.random());
    const follower = try state.advance(2, 96, 10003, &monitors, null, false, prng.random());
    try std.testing.expectEqualDeep(second, follower.monitor);
    try std.testing.expectEqual(changed.revision, follower.revision);
    // Keep member 2 alive while 1 exits. No leader election can strand the group.
    _ = try state.advance(2, 96, 12500, &monitors, null, true, prng.random());
    _ = try state.advance(2, 96, 14000, &monitors, null, true, prng.random());
    try std.testing.expectEqual(@as(u64, 0), state.members[0].id);
    state.visit_ms = 14001;
    const waiting = try state.advance(2, 96, 14001, &monitors, null, false, prng.random());
    try std.testing.expectEqualDeep(second, waiting.monitor);
    const visit = try state.advance(2, 96, 14002, &monitors, null, true, prng.random());
    try std.testing.expectEqualDeep(first, visit.monitor);
    try std.testing.expect(!state.valid(visitDelay(prng.random()) + 14002));
}

test "group destinations fit a screen narrower than the group" {
    var prng = std.Random.DefaultPrng.init(8);
    const screen: geometry.Monitor = .{ .x = 0, .y = 0, .w = 160, .h = 600 };
    var monitors: geometry.Monitors = .{};
    monitors.add(screen);
    var state = Shared.fresh(1, screen, prng.random());
    for (0..5) |i| _ = try state.advance(i + 1, 64, 1, &monitors, null, true, prng.random());
    for (0..5) |i| {
        const x = state.destination(i) - 32;
        try std.testing.expect(x >= 0 and x <= 96);
    }
}

test "a peer missing the shared monitor cannot churn the group plan" {
    var prng = std.Random.DefaultPrng.init(9);
    const primary: geometry.Monitor = .{ .x = 710, .y = 1080, .w = 1366, .h = 768 };
    const other: geometry.Monitor = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
    var monitors: geometry.Monitors = .{};
    monitors.add(primary);
    var state = Shared.fresh(10000, other, prng.random());
    const before = state;
    try std.testing.expectError(error.IncompatibleMonitors, state.advance(1, 64, 10001, &monitors, primary, true, prng.random()));
    try std.testing.expectEqualDeep(before, state);
}
