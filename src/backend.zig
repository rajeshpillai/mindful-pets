//! Window backend selection. Everything outside this file and `src/backend/`
//! talks to `Window`, `wait` and the shared types below; only a backend knows
//! how its compositor works. Backends: `x11` (Xlib, also used under XWayland),
//! `gnome` (a Clutter actor drawn by the GNOME Shell extension in
//! gnome-extension/, over a Unix socket) and `auto` (gnome when the extension
//! is running, else x11; the Linux default), `win32` (a layered window, the
//! Windows default) and `appkit` (a borderless NSWindow, the macOS default).
//!
//! Pick one with `zig build -Dbackend=x11|gnome|auto|win32|appkit`.

const std = @import("std");
const options = @import("build_options");

pub const Kind = @TypeOf(options.backend);
pub const kind: Kind = options.backend;

const impl = switch (kind) {
    .x11 => @import("backend/x11.zig"),
    .gnome => @import("backend/gnome.zig"),
    .auto => @import("backend/auto.zig"),
    .win32 => @import("backend/win32.zig"),
    .appkit => @import("backend/appkit.zig"),
};

/// Name of the compiled-in backend. `Window.backendName()` tells which one a
/// window actually uses, which differs under `auto`.
pub const name: []const u8 = impl.name;

/// A transparent, always-on-top, frameless window the size of the sprite,
/// with a 32-bit ARGB pixel buffer the caller paints into.
pub const Window = impl.Window;

/// Block until one of the windows has input, `extra_fd` is readable (the
/// command pipe; pass null when there is none), or `timeout_ms` passes.
/// Backends without file descriptors may simply sleep for the timeout.
pub const wait = impl.wait;

pub const Error = error{ NoDisplay, NoImage, OutOfMemory };
pub const Monitor = @import("monitors.zig").Monitor;
pub const Monitors = @import("monitors.zig").Monitors;

/// Pointer position in screen coordinates.
pub const PointerPos = struct { x: i32, y: i32 };

/// A rectangle in window coordinates. The layout matches X11's XRectangle so
/// that backend can pass a slice straight through; others convert.
pub const Rect = extern struct { x: i16, y: i16, w: u16, h: u16 };

/// Input the backend reports. Buttons: 1 = left, 2 = middle, 3 = right.
/// `x_root`/`y_root` are screen coordinates, `x`/`y` window coordinates.
pub const Event = union(enum) {
    press: struct { button: u32, x_root: i32, y_root: i32, x: i32, y: i32 },
    release: struct { button: u32, x_root: i32, y_root: i32 },
    motion: struct { x_root: i32, y_root: i32 },
    /// The window contents were lost and must be painted again.
    expose,
    /// Monitor geometry changed; read the window's current screen dimensions.
    screen_changed,
    /// The compositor connection closed. Delivered once per window.
    disconnected,
};

// The contract every backend's `Window` must meet. Checked at compile time
// so a new backend fails to build with a clear message, not a confusing one
// from deep inside main.zig.
comptime {
    const required_fns = [_][]const u8{
        "init", // fn (w: u32, h: u32) Error!Window
        "deinit", // fn (*Window) void
        "backendName", // fn (*const Window) []const u8          "x11", "gnome", ... for the log
        "fd", // fn (*const Window) c_int                        descriptor to sleep on
        "show", // fn (*Window) void
        "hide", // fn (*Window) void
        "move", // fn (*Window, x: i32, y: i32) void             screen coordinates
        "raise", // fn (*Window) void                             bring to the top
        "present", // fn (*Window) void                           blit `pixels`
        "flush", // fn (*Window) void                             push queued requests
        "setInputShape", // fn (*Window, []const Rect) void        clicks outside fall through
        "queryPointer", // fn (*Window) PointerPos
        "useMonitor", // fn (*Window, Monitor) void             select local coordinate space
        "pollEvent", // fn (*Window) ?Event                       null when the queue is empty
    };
    for (required_fns) |f| {
        if (!@hasDecl(Window, f)) @compileError("backend " ++ name ++ ": Window is missing `" ++ f ++ "`");
    }
    const required_fields = [_][]const u8{
        "pixels", // [*]u32, w*h ARGB, little-endian 0xAARRGGBB
        "w", "h", // u32
        "argb", // bool: alpha 0 is really see-through; false means paint an opaque bg
        "screen_w", "screen_h", // i32; may change while running, announced by Event.screen_changed
        "origin_x", "origin_y", // i32; desktop origin of the selected monitor
        "monitors", // Monitors; actual screens, excluding gaps
    };
    for (required_fields) |f| {
        if (!@hasField(Window, f)) @compileError("backend " ++ name ++ ": Window is missing field `" ++ f ++ "`");
    }
    if (@TypeOf(wait) != fn ([]const *const Window, ?c_int, i32) void)
        @compileError("backend " ++ name ++ ": wait must be fn ([]const *const Window, ?c_int, i32) void");
}

test {
    std.testing.refAllDecls(@This());
}
