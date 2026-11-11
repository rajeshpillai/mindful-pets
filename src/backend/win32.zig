//! Win32 backend: a layered, top-most, tool window (no taskbar button, never
//! takes focus) updated with UpdateLayeredWindow from a 32-bit DIB. Layered
//! windows hit-test on per-pixel alpha, so clicks on transparent pixels
//! already fall through; setInputShape only has to make the bubble fully
//! click-through with WS_EX_TRANSPARENT.
//!
//! Coordinates are physical pixels (per-monitor DPI aware), relative to the
//! selected monitor like every other backend.

const std = @import("std");
const backend = @import("../backend.zig");

pub const name = "win32";

const Error = backend.Error;
const PointerPos = backend.PointerPos;
const Rect = backend.Rect;
const Event = backend.Event;

// --- Win32 declarations ------------------------------------------------------

const BOOL = c_int;
const HANDLE = ?*anyopaque;
const HWND = ?*anyopaque;
const HDC = ?*anyopaque;
const HBITMAP = ?*anyopaque;
const HMONITOR = ?*anyopaque;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

const POINT = extern struct { x: i32, y: i32 };
const SIZE = extern struct { cx: i32, cy: i32 };
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const MSG = extern struct { hwnd: HWND, message: u32, wParam: WPARAM, lParam: LPARAM, time: u32, pt: POINT, private: u32 };
const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: HANDLE,
    hIcon: HANDLE = null,
    hCursor: HANDLE = null,
    hbrBackground: HANDLE = null,
    lpszMenuName: ?[*:0]const u16 = null,
    lpszClassName: [*:0]const u16,
    hIconSm: HANDLE = null,
};
const MONITORINFO = extern struct { cbSize: u32 = @sizeOf(MONITORINFO), rcMonitor: RECT = undefined, rcWork: RECT = undefined, dwFlags: u32 = 0 };
const BLENDFUNCTION = extern struct { op: u8, flags: u8, alpha: u8, format: u8 };
const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0, // BI_RGB
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};
const BITMAPINFO = extern struct { header: BITMAPINFOHEADER, colors: [1]u32 = .{0} };
const MONITORENUMPROC = *const fn (HMONITOR, HDC, *RECT, LPARAM) callconv(.winapi) BOOL;

const WS_POPUP = 0x80000000;
const WS_EX_TOPMOST = 0x00000008;
const WS_EX_TRANSPARENT = 0x00000020;
const WS_EX_TOOLWINDOW = 0x00000080;
const WS_EX_LAYERED = 0x00080000;
const WS_EX_NOACTIVATE = 0x08000000;
const GWL_EXSTYLE = -20;
const SW_HIDE = 0;
const SW_SHOWNOACTIVATE = 4;
const SWP_NOSIZE = 0x0001;
const SWP_NOMOVE = 0x0002;
const SWP_NOZORDER = 0x0004;
const SWP_NOACTIVATE = 0x0010;
const HWND_TOPMOST: HWND = @ptrFromInt(std.math.maxInt(usize)); // (HWND)-1
const PM_REMOVE = 0x0001;
const QS_ALLINPUT = 0x04FF;
const ULW_ALPHA = 0x00000002;
const AC_SRC_OVER = 0x00;
const AC_SRC_ALPHA = 0x01;
const MONITORINFOF_PRIMARY = 0x00000001;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -4))));

const WM_DISPLAYCHANGE = 0x007E;
const WM_MOUSEACTIVATE = 0x0021;
const WM_MOUSEMOVE = 0x0200;
const WM_LBUTTONDOWN = 0x0201;
const WM_LBUTTONUP = 0x0202;
const WM_RBUTTONDOWN = 0x0204;
const WM_RBUTTONUP = 0x0205;
const WM_MBUTTONDOWN = 0x0207;
const WM_MBUTTONUP = 0x0208;
const WM_DPICHANGED = 0x02E0;
const MA_NOACTIVATE = 3;
const MK_LBUTTON = 0x0001;

extern "kernel32" fn GetModuleHandleW(name: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetConsoleProcessList(list: [*]u32, count: u32) callconv(.winapi) u32;
extern "kernel32" fn FreeConsole() callconv(.winapi) BOOL;
extern "user32" fn RegisterClassExW(class: *const WNDCLASSEXW) callconv(.winapi) u16;
extern "user32" fn CreateWindowExW(ex_style: u32, class: [*:0]const u16, title: [*:0]const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: HWND, menu: HANDLE, instance: HANDLE, param: ?*anyopaque) callconv(.winapi) HWND;
extern "user32" fn DestroyWindow(hwnd: HWND) callconv(.winapi) BOOL;
extern "user32" fn DefWindowProcW(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(hwnd: HWND, cmd: c_int) callconv(.winapi) BOOL;
extern "user32" fn SetWindowPos(hwnd: HWND, after: HWND, x: i32, y: i32, w: i32, h: i32, flags: u32) callconv(.winapi) BOOL;
extern "user32" fn GetWindowLongPtrW(hwnd: HWND, index: c_int) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hwnd: HWND, index: c_int, value: isize) callconv(.winapi) isize;
extern "user32" fn PeekMessageW(msg: *MSG, hwnd: HWND, min: u32, max: u32, remove: u32) callconv(.winapi) BOOL;
extern "user32" fn TranslateMessage(msg: *const MSG) callconv(.winapi) BOOL;
extern "user32" fn DispatchMessageW(msg: *const MSG) callconv(.winapi) LRESULT;
extern "user32" fn MsgWaitForMultipleObjects(count: u32, handles: ?[*]const HANDLE, wait_all: BOOL, ms: u32, wake_mask: u32) callconv(.winapi) u32;
extern "user32" fn GetCursorPos(pt: *POINT) callconv(.winapi) BOOL;
extern "user32" fn SetCapture(hwnd: HWND) callconv(.winapi) HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn GetDC(hwnd: HWND) callconv(.winapi) HDC;
extern "user32" fn ReleaseDC(hwnd: HWND, dc: HDC) callconv(.winapi) c_int;
extern "user32" fn UpdateLayeredWindow(hwnd: HWND, dst_dc: HDC, dst: ?*const POINT, size: ?*const SIZE, src_dc: HDC, src: ?*const POINT, key: u32, blend: ?*const BLENDFUNCTION, flags: u32) callconv(.winapi) BOOL;
extern "user32" fn EnumDisplayMonitors(dc: HDC, clip: ?*const RECT, callback: MONITORENUMPROC, data: LPARAM) callconv(.winapi) BOOL;
extern "user32" fn GetMonitorInfoW(monitor: HMONITOR, info: *MONITORINFO) callconv(.winapi) BOOL;
extern "user32" fn GetSystemMetrics(index: c_int) callconv(.winapi) c_int;
extern "user32" fn SetProcessDpiAwarenessContext(ctx: HANDLE) callconv(.winapi) BOOL;
extern "gdi32" fn CreateCompatibleDC(dc: HDC) callconv(.winapi) HDC;
extern "gdi32" fn DeleteDC(dc: HDC) callconv(.winapi) BOOL;
extern "gdi32" fn CreateDIBSection(dc: HDC, info: *const BITMAPINFO, usage: u32, bits: *?*anyopaque, section: HANDLE, offset: u32) callconv(.winapi) HBITMAP;
extern "gdi32" fn SelectObject(dc: HDC, obj: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(obj: ?*anyopaque) callconv(.winapi) BOOL;

// --- process-wide state ------------------------------------------------------

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MindfulPet");
var class_registered = false;
/// Set by the window procedure on WM_DISPLAYCHANGE / WM_DPICHANGED; each
/// window then refreshes its monitor list on its next pollEvent.
var display_generation: u32 = 0;

fn wndProc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
        WM_MOUSEACTIVATE => return MA_NOACTIVATE,
        WM_DISPLAYCHANGE, WM_DPICHANGED => display_generation +%= 1,
        else => {},
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// Started from a double-click, a console-subsystem program gets a console
/// window of its own; close it. Started from a terminal, the console is
/// shared and stays, so the log is visible there.
fn dropOwnConsole() void {
    var pids: [2]u32 = undefined;
    if (GetConsoleProcessList(&pids, pids.len) == 1) _ = FreeConsole();
}

fn processInit() Error!void {
    if (class_registered) return;
    dropOwnConsole();
    _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    const wc: WNDCLASSEXW = .{ .lpfnWndProc = wndProc, .hInstance = GetModuleHandleW(null), .lpszClassName = class_name };
    if (RegisterClassExW(&wc) == 0) return error.NoDisplay;
    class_registered = true;
}

/// Sleep until a message arrives for this thread or the timeout passes. The
/// command pipe has no waitable descriptor here, so `extra_fd` is ignored;
/// the 33 ms frame timer picks up commands.
pub fn wait(windows: []const *const Window, extra_fd: ?c_int, timeout_ms: i32) void {
    _ = windows;
    _ = extra_fd;
    _ = MsgWaitForMultipleObjects(0, null, 0, @intCast(@max(0, timeout_ms)), QS_ALLINPUT);
}

fn lowWord(v: LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(v))))));
}

fn highWord(v: LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(v)) >> 16))));
}

const EnumCtx = struct { monitors: *backend.Monitors, primary: ?backend.Monitor = null };

fn enumMonitor(mon: HMONITOR, dc: HDC, rect: *RECT, data: LPARAM) callconv(.winapi) BOOL {
    _ = dc;
    _ = rect;
    const ctx: *EnumCtx = @ptrFromInt(@as(usize, @bitCast(data)));
    var info: MONITORINFO = .{};
    if (GetMonitorInfoW(mon, &info) == 0) return 1;
    const r = info.rcMonitor;
    const m: backend.Monitor = .{ .x = r.left, .y = r.top, .w = r.right - r.left, .h = r.bottom - r.top };
    if (m.w <= 0 or m.h <= 0) return 1;
    ctx.monitors.add(m);
    if (info.dwFlags & MONITORINFOF_PRIMARY != 0) ctx.primary = m;
    return 1;
}

pub const Window = struct {
    hwnd: HWND,
    mem_dc: HDC,
    dib: HBITMAP,
    old_bitmap: ?*anyopaque,
    /// The DIB's own memory: premultiplied BGRA, top-down.
    dib_bits: [*]u32,
    /// What the caller paints: straight 0xAARRGGBB.
    pixels: [*]u32,
    w: u32,
    h: u32,
    argb: bool = true,
    screen_w: i32 = 0,
    screen_h: i32 = 0,
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    monitors: backend.Monitors = .{},
    primary: ?backend.Monitor = null,
    /// Last position given to `move`, in desktop coordinates.
    pos_x: i32 = std.math.minInt(i32),
    pos_y: i32 = std.math.minInt(i32),
    visible: bool = false,
    click_through: bool = false,
    seen_display_generation: u32 = 0,
    last_monitor_check: u64 = 0,

    pub fn init(w: u32, h: u32) Error!Window {
        try processInit();
        const ex_style = WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
        const title = std.unicode.utf8ToUtf16LeStringLiteral("pet");
        const hwnd = CreateWindowExW(ex_style, class_name, title, WS_POPUP, 0, 0, @intCast(w), @intCast(h), null, null, GetModuleHandleW(null), null) orelse return error.NoDisplay;
        errdefer _ = DestroyWindow(hwnd);

        const screen_dc = GetDC(null);
        defer _ = ReleaseDC(null, screen_dc);
        const mem_dc = CreateCompatibleDC(screen_dc) orelse return error.NoImage;
        errdefer _ = DeleteDC(mem_dc);
        // Negative height: top-down rows, matching the caller's buffer.
        const info: BITMAPINFO = .{ .header = .{ .biWidth = @intCast(w), .biHeight = -@as(i32, @intCast(h)) } };
        var bits: ?*anyopaque = null;
        const dib = CreateDIBSection(screen_dc, &info, 0, &bits, null, 0) orelse return error.NoImage;
        errdefer _ = DeleteObject(dib);
        const old = SelectObject(mem_dc, dib);

        const pixels = std.heap.page_allocator.alloc(u32, @as(usize, w) * h) catch return error.OutOfMemory;
        @memset(pixels, 0);

        var result: Window = .{
            .hwnd = hwnd,
            .mem_dc = mem_dc,
            .dib = dib,
            .old_bitmap = old,
            .dib_bits = @ptrCast(@alignCast(bits.?)),
            .pixels = pixels.ptr,
            .w = w,
            .h = h,
        };
        result.seen_display_generation = display_generation;
        _ = result.refreshMonitors();
        return result;
    }

    pub fn deinit(self: *Window) void {
        _ = SelectObject(self.mem_dc, self.old_bitmap);
        _ = DeleteObject(self.dib);
        _ = DeleteDC(self.mem_dc);
        _ = DestroyWindow(self.hwnd);
        std.heap.page_allocator.free(self.pixels[0 .. @as(usize, self.w) * self.h]);
    }

    fn refreshMonitors(self: *Window) bool {
        const previous = self.monitors;
        self.monitors = .{};
        var ctx: EnumCtx = .{ .monitors = &self.monitors };
        _ = EnumDisplayMonitors(null, null, enumMonitor, @bitCast(@intFromPtr(&ctx)));
        if (self.monitors.len == 0) self.monitors.add(.{ .x = 0, .y = 0, .w = GetSystemMetrics(0), .h = GetSystemMetrics(1) });
        const chosen = ctx.primary orelse self.monitors.items[0];
        var changed = !std.meta.eql(self.primary, @as(?backend.Monitor, chosen)) or previous.len != self.monitors.len;
        if (!changed) for (previous.items[0..previous.len], self.monitors.items[0..self.monitors.len]) |old, new| {
            if (!std.meta.eql(old, new)) changed = true;
        };
        self.primary = chosen;
        if (changed) self.useMonitor(chosen);
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
        _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
        self.visible = true;
    }

    pub fn hide(self: *Window) void {
        _ = ShowWindow(self.hwnd, SW_HIDE);
        self.visible = false;
    }

    pub fn move(self: *Window, x: i32, y: i32) void {
        const ax = x + self.origin_x;
        const ay = y + self.origin_y;
        if (ax == self.pos_x and ay == self.pos_y) return;
        self.pos_x = ax;
        self.pos_y = ay;
        _ = SetWindowPos(self.hwnd, null, ax, ay, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    pub fn raise(self: *Window) void {
        _ = SetWindowPos(self.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    /// Premultiply into the DIB and hand it to the compositor.
    pub fn present(self: *Window) void {
        const n = @as(usize, self.w) * self.h;
        for (self.pixels[0..n], self.dib_bits[0..n]) |px, *out| {
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
        const size: SIZE = .{ .cx = @intCast(self.w), .cy = @intCast(self.h) };
        const src: POINT = .{ .x = 0, .y = 0 };
        const blend: BLENDFUNCTION = .{ .op = AC_SRC_OVER, .flags = 0, .alpha = 255, .format = AC_SRC_ALPHA };
        _ = UpdateLayeredWindow(self.hwnd, null, null, &size, self.mem_dc, &src, 0, &blend, ULW_ALPHA);
    }

    pub fn flush(self: *Window) void {
        _ = self;
    }

    /// Transparent pixels already let clicks through; an empty shape makes
    /// the whole window click-through (the speech bubble).
    pub fn setInputShape(self: *Window, rects: []const Rect) void {
        const want = rects.len == 0;
        if (want == self.click_through) return;
        self.click_through = want;
        var style = GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE);
        if (want) style |= WS_EX_TRANSPARENT else style &= ~@as(isize, WS_EX_TRANSPARENT);
        _ = SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, style);
    }

    pub fn queryPointer(self: *Window) PointerPos {
        var pt: POINT = .{ .x = 0, .y = 0 };
        _ = GetCursorPos(&pt);
        return .{ .x = pt.x - self.origin_x, .y = pt.y - self.origin_y };
    }

    pub fn pollEvent(self: *Window) ?Event {
        const now = GetTickCount64();
        if (self.seen_display_generation != display_generation or now / 1000 != self.last_monitor_check) {
            self.seen_display_generation = display_generation;
            self.last_monitor_check = now / 1000;
            if (self.refreshMonitors()) return .screen_changed;
        }
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, self.hwnd, 0, 0, PM_REMOVE) != 0) {
            // msg.pt is the cursor position when the message was posted, in
            // desktop coordinates, so it stays right while the window moves.
            const rx = msg.pt.x - self.origin_x;
            const ry = msg.pt.y - self.origin_y;
            switch (msg.message) {
                WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN => {
                    const button: u32 = switch (msg.message) {
                        WM_LBUTTONDOWN => 1,
                        WM_MBUTTONDOWN => 2,
                        else => 3,
                    };
                    // Keep receiving moves and the release while dragging off the window.
                    if (button == 1) _ = SetCapture(self.hwnd);
                    return .{ .press = .{ .button = button, .x_root = rx, .y_root = ry, .x = lowWord(msg.lParam), .y = highWord(msg.lParam) } };
                },
                WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP => {
                    const button: u32 = switch (msg.message) {
                        WM_LBUTTONUP => 1,
                        WM_MBUTTONUP => 2,
                        else => 3,
                    };
                    if (button == 1) _ = ReleaseCapture();
                    return .{ .release = .{ .button = button, .x_root = rx, .y_root = ry } };
                },
                // Like X11's ButtonMotionMask: only motion with the button held.
                WM_MOUSEMOVE => if (msg.wParam & MK_LBUTTON != 0) return .{ .motion = .{ .x_root = rx, .y_root = ry } },
                else => {
                    _ = TranslateMessage(&msg);
                    _ = DispatchMessageW(&msg);
                },
            }
        }
        // Messages for no particular window (thread messages) still need pumping.
        while (PeekMessageW(&msg, @ptrFromInt(std.math.maxInt(usize)), 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return null;
    }
};
