//! macOS backend: a borderless, non-activating NSPanel above normal windows
//! whose content view's layer shows a CGImage of the pixel buffer. Clicks on
//! fully transparent pixels pass through to the window underneath.
//!
//! AppKit, QuartzCore and the Objective-C runtime are loaded with dlopen and
//! every call goes through objc_msgSend, so the binary links only libSystem
//! and cross-compiles from Linux without the macOS SDK.
//!
//! Coordinates are points with the origin at the top-left of the primary
//! screen, y down, like the other backends; AppKit's y-up frames are
//! converted at the edges.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const os = @import("../os.zig");

pub const name = "appkit";

const Error = backend.Error;
const PointerPos = backend.PointerPos;
const Rect = backend.Rect;
const Event = backend.Event;

const id = ?*anyopaque;
const SEL = ?*anyopaque;
const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;
const RTLD_LAZY = 0x1;
const RTLD_GLOBAL = 0x8;
const RTLD_DEFAULT: ?*anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));

// AppKit constants.
const NSWindowStyleMaskBorderless = 0;
const NSWindowStyleMaskNonactivatingPanel = 1 << 7;
const NSBackingStoreBuffered = 2;
const NSStatusWindowLevel = 25;
const NSApplicationActivationPolicyAccessory = 1;
const NSWindowCollectionBehaviorCanJoinAllSpaces = 1 << 0;
const NSWindowCollectionBehaviorStationary = 1 << 4;
const NSWindowCollectionBehaviorIgnoresCycle = 1 << 6;
const NSWindowCollectionBehaviorFullScreenAuxiliary = 1 << 8;
const NSEventTypeLeftMouseDown = 1;
const NSEventTypeLeftMouseUp = 2;
const NSEventTypeRightMouseDown = 3;
const NSEventTypeRightMouseUp = 4;
const NSEventTypeLeftMouseDragged = 6;
const NSEventTypeOtherMouseDown = 25;
const NSEventTypeOtherMouseUp = 26;
const NSEventMaskAny: u64 = std.math.maxInt(u64);
// CGBitmapInfo: premultiplied alpha first, 32-bit little-endian = BGRA bytes,
// which is 0xAARRGGBB in a little-endian u32, the caller's layout.
const kCGImageAlphaPremultipliedFirst = 2;
const kCGBitmapByteOrder32Little = 2 << 12;

const Runtime = struct {
    getClass: *const fn ([*:0]const u8) callconv(.c) id,
    registerName: *const fn ([*:0]const u8) callconv(.c) SEL,
    msgSend: *const anyopaque,
    msgSendStret: ?*const anyopaque,
    CGColorSpaceCreateDeviceRGB: *const fn () callconv(.c) ?*anyopaque,
    CGBitmapContextCreate: *const fn (?*anyopaque, usize, usize, usize, usize, ?*anyopaque, u32) callconv(.c) ?*anyopaque,
    CGBitmapContextCreateImage: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    CGImageRelease: *const fn (?*anyopaque) callconv(.c) void,
    CGContextRelease: *const fn (?*anyopaque) callconv(.c) void,
    filter_nearest: id,
    run_loop_mode: id,
    app: id = null,
    colorspace: ?*anyopaque = null,
    pool: id = null,
};

var rt: Runtime = undefined;
var loaded = false;

fn fnSym(comptime T: type, handle: ?*anyopaque, symbol: [*:0]const u8) Error!T {
    const p = dlsym(handle, symbol) orelse {
        std.debug.print("pet: appkit: missing symbol {s}\n", .{symbol});
        return error.NoDisplay;
    };
    return @ptrCast(@alignCast(p));
}

/// The value of an exported `NSString *const` (or similar) variable.
fn objSym(handle: ?*anyopaque, symbol: [*:0]const u8) Error!id {
    const p = dlsym(handle, symbol) orelse {
        std.debug.print("pet: appkit: missing symbol {s}\n", .{symbol});
        return error.NoDisplay;
    };
    return @as(*const id, @ptrCast(@alignCast(p))).*;
}

fn load() Error!void {
    if (loaded) return;
    const objc = dlopen("/usr/lib/libobjc.A.dylib", RTLD_LAZY | RTLD_GLOBAL) orelse return error.NoDisplay;
    _ = dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY | RTLD_GLOBAL) orelse return error.NoDisplay;
    const qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_GLOBAL) orelse return error.NoDisplay;
    rt = .{
        .getClass = try fnSym(@FieldType(Runtime, "getClass"), objc, "objc_getClass"),
        .registerName = try fnSym(@FieldType(Runtime, "registerName"), objc, "sel_registerName"),
        .msgSend = try fnSym(*const anyopaque, objc, "objc_msgSend"),
        // Only x86_64 returns large structs through a separate entry point.
        .msgSendStret = if (builtin.cpu.arch == .x86_64) try fnSym(*const anyopaque, objc, "objc_msgSend_stret") else null,
        .CGColorSpaceCreateDeviceRGB = try fnSym(@FieldType(Runtime, "CGColorSpaceCreateDeviceRGB"), RTLD_DEFAULT, "CGColorSpaceCreateDeviceRGB"),
        .CGBitmapContextCreate = try fnSym(@FieldType(Runtime, "CGBitmapContextCreate"), RTLD_DEFAULT, "CGBitmapContextCreate"),
        .CGBitmapContextCreateImage = try fnSym(@FieldType(Runtime, "CGBitmapContextCreateImage"), RTLD_DEFAULT, "CGBitmapContextCreateImage"),
        .CGImageRelease = try fnSym(@FieldType(Runtime, "CGImageRelease"), RTLD_DEFAULT, "CGImageRelease"),
        .CGContextRelease = try fnSym(@FieldType(Runtime, "CGContextRelease"), RTLD_DEFAULT, "CGContextRelease"),
        .filter_nearest = try objSym(qc, "kCAFilterNearest"),
        .run_loop_mode = try objSym(RTLD_DEFAULT, "NSDefaultRunLoopMode"),
    };
    loaded = true;
    rt.pool = send(id, send(id, cls("NSAutoreleasePool"), "alloc", .{}), "init", .{});
    rt.app = send(id, cls("NSApplication"), "sharedApplication", .{});
    // Accessory: no Dock icon or menu bar, like a desktop widget.
    _ = send(bool, rt.app, "setActivationPolicy:", .{@as(isize, NSApplicationActivationPolicyAccessory)});
    send(void, rt.app, "finishLaunching", .{});
    rt.colorspace = rt.CGColorSpaceCreateDeviceRGB();
}

fn cls(class_name: [*:0]const u8) id {
    return rt.getClass(class_name);
}

/// objc_msgSend with the signature spelled out by the argument types, which
/// must be concrete (no comptime_int literals).
fn send(comptime R: type, obj: id, selector: [*:0]const u8, args: anytype) R {
    const s = rt.registerName(selector);
    const big_struct = builtin.cpu.arch == .x86_64 and @typeInfo(R) == .@"struct" and @sizeOf(R) > 16;
    const imp = if (big_struct) rt.msgSendStret.? else rt.msgSend;
    const T = @typeInfo(@TypeOf(args)).@"struct".field_types;
    return switch (T.len) {
        0 => @as(*const fn (id, SEL) callconv(.c) R, @ptrCast(@alignCast(imp)))(obj, s),
        1 => @as(*const fn (id, SEL, T[0]) callconv(.c) R, @ptrCast(@alignCast(imp)))(obj, s, args[0]),
        2 => @as(*const fn (id, SEL, T[0], T[1]) callconv(.c) R, @ptrCast(@alignCast(imp)))(obj, s, args[0], args[1]),
        3 => @as(*const fn (id, SEL, T[0], T[1], T[2]) callconv(.c) R, @ptrCast(@alignCast(imp)))(obj, s, args[0], args[1], args[2]),
        4 => @as(*const fn (id, SEL, T[0], T[1], T[2], T[3]) callconv(.c) R, @ptrCast(@alignCast(imp)))(obj, s, args[0], args[1], args[2], args[3]),
        else => @compileError("send: too many arguments"),
    };
}

// --- shared event queue ----------------------------------------------------
// AppKit has one event queue per process; each window takes its own events
// out of this buffer, filled by whichever window pumps first.

const Queued = struct { window: id, ev: Event };
var queue: [64]Queued = undefined;
var queue_len: usize = 0;

fn enqueue(q: Queued) void {
    if (queue_len == queue.len) {
        std.mem.copyForwards(Queued, queue[0 .. queue.len - 1], queue[1..]);
        queue_len -= 1;
    }
    queue[queue_len] = q;
    queue_len += 1;
}

/// Height of the primary screen, which anchors AppKit's y-up coordinates.
var primary_h: f64 = 0;

fn pump() void {
    while (true) {
        const ev = send(id, rt.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{
            NSEventMaskAny,
            send(id, cls("NSDate"), "distantPast", .{}),
            rt.run_loop_mode,
            true,
        }) orelse return;
        const kind = send(usize, ev, "type", .{});
        switch (kind) {
            NSEventTypeLeftMouseDown, NSEventTypeRightMouseDown, NSEventTypeOtherMouseDown, NSEventTypeLeftMouseUp, NSEventTypeRightMouseUp, NSEventTypeOtherMouseUp, NSEventTypeLeftMouseDragged => if (send(id, ev, "window", .{})) |w| {
                const loc = send(NSPoint, ev, "locationInWindow", .{});
                const frame = send(NSRect, w, "frame", .{});
                // Desktop coordinates, y down; windows subtract their origin.
                const ax: i32 = @intFromFloat(@floor(frame.origin.x + loc.x));
                const ay: i32 = @intFromFloat(@floor(primary_h - (frame.origin.y + loc.y)));
                const wx: i32 = @intFromFloat(@floor(loc.x));
                const wy: i32 = @intFromFloat(@floor(frame.size.h - loc.y));
                const button: u32 = switch (kind) {
                    NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp, NSEventTypeLeftMouseDragged => 1,
                    NSEventTypeRightMouseDown, NSEventTypeRightMouseUp => 3,
                    else => 2,
                };
                const out: Event = switch (kind) {
                    NSEventTypeLeftMouseDown, NSEventTypeRightMouseDown, NSEventTypeOtherMouseDown => .{ .press = .{ .button = button, .x_root = ax, .y_root = ay, .x = wx, .y = wy } },
                    NSEventTypeLeftMouseDragged => .{ .motion = .{ .x_root = ax, .y_root = ay } },
                    else => .{ .release = .{ .button = button, .x_root = ax, .y_root = ay } },
                };
                enqueue(.{ .window = w, .ev = out });
            },
            else => {},
        }
        send(void, rt.app, "sendEvent:", .{ev});
    }
}

/// Block until AppKit has an event or the timeout passes. The FIFO is not
/// part of AppKit's run loop, so `extra_fd` waits for the frame timer.
pub fn wait(windows: []const *const Window, extra_fd: ?c_int, timeout_ms: i32) void {
    _ = windows;
    _ = extra_fd;
    if (!loaded) return;
    // Release whatever the last frame autoreleased.
    send(void, rt.pool, "drain", .{});
    rt.pool = send(id, send(id, cls("NSAutoreleasePool"), "alloc", .{}), "init", .{});
    const secs: f64 = @as(f64, @floatFromInt(@max(0, timeout_ms))) / 1000.0;
    const until = send(id, cls("NSDate"), "dateWithTimeIntervalSinceNow:", .{secs});
    _ = send(id, rt.app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ NSEventMaskAny, until, rt.run_loop_mode, false });
}

pub const Window = struct {
    panel: id,
    layer: id,
    ctx: ?*anyopaque,
    /// What the caller paints: straight 0xAARRGGBB.
    pixels: [*]u32,
    /// Premultiplied copy backing `ctx`.
    premul: [*]u32,
    w: u32,
    h: u32,
    argb: bool = true,
    screen_w: i32 = 0,
    screen_h: i32 = 0,
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    monitors: backend.Monitors = .{},
    primary: ?backend.Monitor = null,
    pos_x: i32 = std.math.minInt(i32),
    pos_y: i32 = std.math.minInt(i32),
    visible: bool = false,
    click_through: bool = false,
    last_monitor_check: i64 = 0,

    pub fn init(w: u32, h: u32) Error!Window {
        try load();
        const rect: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) } };
        const style: usize = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel;
        const panel = send(id, send(id, cls("NSPanel"), "alloc", .{}), "initWithContentRect:styleMask:backing:defer:", .{
            rect, style, @as(usize, NSBackingStoreBuffered), false,
        }) orelse return error.NoDisplay;
        send(void, panel, "setReleasedWhenClosed:", .{false});
        send(void, panel, "setOpaque:", .{false});
        send(void, panel, "setBackgroundColor:", .{send(id, cls("NSColor"), "clearColor", .{})});
        send(void, panel, "setHasShadow:", .{false});
        send(void, panel, "setLevel:", .{@as(isize, NSStatusWindowLevel)});
        send(void, panel, "setHidesOnDeactivate:", .{false});
        send(void, panel, "setFloatingPanel:", .{true});
        send(void, panel, "setBecomesKeyOnlyIfNeeded:", .{true});
        send(void, panel, "setCollectionBehavior:", .{@as(usize, NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle |
            NSWindowCollectionBehaviorFullScreenAuxiliary)});

        const view = send(id, panel, "contentView", .{});
        send(void, view, "setWantsLayer:", .{true});
        const layer = send(id, view, "layer", .{}) orelse return error.NoDisplay;
        // Retina scales the 1x image up; keep the pixel art sharp.
        send(void, layer, "setMagnificationFilter:", .{rt.filter_nearest});

        const n = @as(usize, w) * h;
        const pixels = std.heap.page_allocator.alloc(u32, n) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.free(pixels);
        const premul = std.heap.page_allocator.alloc(u32, n) catch return error.OutOfMemory;
        errdefer std.heap.page_allocator.free(premul);
        @memset(pixels, 0);
        @memset(premul, 0);
        const ctx = rt.CGBitmapContextCreate(premul.ptr, w, h, 8, @as(usize, w) * 4, rt.colorspace, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) orelse return error.NoImage;

        var result: Window = .{
            .panel = panel,
            .layer = layer,
            .ctx = ctx,
            .pixels = pixels.ptr,
            .premul = premul.ptr,
            .w = w,
            .h = h,
        };
        _ = result.refreshMonitors();
        return result;
    }

    pub fn deinit(self: *Window) void {
        send(void, self.panel, "orderOut:", .{@as(id, null)});
        send(void, self.panel, "close", .{});
        send(void, self.panel, "release", .{});
        rt.CGContextRelease(self.ctx);
        const n = @as(usize, self.w) * self.h;
        std.heap.page_allocator.free(self.pixels[0..n]);
        std.heap.page_allocator.free(self.premul[0..n]);
    }

    fn refreshMonitors(self: *Window) bool {
        const previous = self.monitors;
        self.monitors = .{};
        const screens = send(id, cls("NSScreen"), "screens", .{});
        const count = send(usize, screens, "count", .{});
        var chosen: ?backend.Monitor = null;
        for (0..count) |i| {
            const screen = send(id, screens, "objectAtIndex:", .{i});
            const f = send(NSRect, screen, "frame", .{});
            // Screen 0 holds the menu bar and anchors AppKit's coordinates.
            if (i == 0) primary_h = f.size.h;
            const m: backend.Monitor = .{
                .x = @intFromFloat(f.origin.x),
                .y = @intFromFloat(primary_h - (f.origin.y + f.size.h)),
                .w = @intFromFloat(f.size.w),
                .h = @intFromFloat(f.size.h),
            };
            if (m.w <= 0 or m.h <= 0) continue;
            self.monitors.add(m);
            if (i == 0) chosen = m;
        }
        if (self.monitors.len == 0) {
            self.monitors.add(.{ .x = 0, .y = 0, .w = 1280, .h = 800 });
            primary_h = 800;
        }
        const primary = chosen orelse self.monitors.items[0];
        var changed = !std.meta.eql(self.primary, @as(?backend.Monitor, primary)) or previous.len != self.monitors.len;
        if (!changed) for (previous.items[0..previous.len], self.monitors.items[0..self.monitors.len]) |old, new| {
            if (!std.meta.eql(old, new)) changed = true;
        };
        self.primary = primary;
        if (changed) self.useMonitor(primary);
        return changed;
    }

    pub fn useMonitor(self: *Window, m: backend.Monitor) void {
        self.origin_x = m.x;
        self.origin_y = m.y;
        self.screen_w = m.w;
        self.screen_h = m.h;
    }

    pub fn backendName(self: *const Window) []const u8 {
        _ = self;
        return name;
    }

    pub fn fd(self: *const Window) c_int {
        _ = self;
        return -1;
    }

    pub fn show(self: *Window) void {
        send(void, self.panel, "orderFrontRegardless", .{});
        self.visible = true;
    }

    pub fn hide(self: *Window) void {
        send(void, self.panel, "orderOut:", .{@as(id, null)});
        self.visible = false;
    }

    pub fn move(self: *Window, x: i32, y: i32) void {
        const ax = x + self.origin_x;
        const ay = y + self.origin_y;
        if (ax == self.pos_x and ay == self.pos_y) return;
        self.pos_x = ax;
        self.pos_y = ay;
        const bottom = @as(f64, @floatFromInt(ay)) + @as(f64, @floatFromInt(self.h));
        const origin: NSPoint = .{ .x = @floatFromInt(ax), .y = primary_h - bottom };
        send(void, self.panel, "setFrameOrigin:", .{origin});
    }

    pub fn raise(self: *Window) void {
        if (self.visible) send(void, self.panel, "orderFrontRegardless", .{});
    }

    pub fn present(self: *Window) void {
        const n = @as(usize, self.w) * self.h;
        for (self.pixels[0..n], self.premul[0..n]) |px, *out| {
            const a = px >> 24;
            out.* = switch (a) {
                0 => 0,
                255 => px,
                else => (a << 24) |
                    ((((px >> 16) & 0xFF) * a / 255) << 16) |
                    ((((px >> 8) & 0xFF) * a / 255) << 8) |
                    ((px & 0xFF) * a / 255),
            };
        }
        const img = rt.CGBitmapContextCreateImage(self.ctx) orelse return;
        defer rt.CGImageRelease(img);
        const tx = cls("CATransaction");
        send(void, tx, "begin", .{});
        send(void, tx, "setDisableActions:", .{true}); // no cross-fade between frames
        send(void, self.layer, "setContents:", .{@as(id, img)});
        send(void, tx, "commit", .{});
    }

    pub fn flush(self: *Window) void {
        _ = self;
    }

    /// Transparent pixels already pass clicks through; an empty shape makes
    /// the whole panel ignore the mouse (the speech bubble).
    pub fn setInputShape(self: *Window, rects: []const Rect) void {
        const want = rects.len == 0;
        if (want == self.click_through) return;
        self.click_through = want;
        send(void, self.panel, "setIgnoresMouseEvents:", .{want});
    }

    pub fn queryPointer(self: *Window) PointerPos {
        const p = send(NSPoint, cls("NSEvent"), "mouseLocation", .{});
        return .{
            .x = @as(i32, @intFromFloat(@floor(p.x))) - self.origin_x,
            .y = @as(i32, @intFromFloat(@floor(primary_h - p.y))) - self.origin_y,
        };
    }

    pub fn pollEvent(self: *Window) ?Event {
        const now: i64 = @intCast(os.nowNs() / std.time.ns_per_s);
        if (now != self.last_monitor_check) {
            self.last_monitor_check = now;
            if (self.refreshMonitors()) return .screen_changed;
        }
        pump();
        for (queue[0..queue_len], 0..) |q, i| {
            if (q.window != self.panel) continue;
            std.mem.copyForwards(Queued, queue[i .. queue_len - 1], queue[i + 1 .. queue_len]);
            queue_len -= 1;
            return switch (q.ev) {
                .press => |p| .{ .press = .{ .button = p.button, .x_root = p.x_root - self.origin_x, .y_root = p.y_root - self.origin_y, .x = p.x, .y = p.y } },
                .release => |r| .{ .release = .{ .button = r.button, .x_root = r.x_root - self.origin_x, .y_root = r.y_root - self.origin_y } },
                .motion => |m| .{ .motion = .{ .x_root = m.x_root - self.origin_x, .y_root = m.y_root - self.origin_y } },
                else => q.ev,
            };
        }
        return null;
    }
};
