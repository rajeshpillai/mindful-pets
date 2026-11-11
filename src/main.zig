const std = @import("std");
const builtin = @import("builtin");
const os = @import("os.zig");
const backend = @import("backend.zig");
const petmod = @import("pet.zig");
const sprites = @import("sprites.zig");
const channel = @import("channel.zig");
const audio_mod = @import("audio.zig");
const font = @import("font.zig");
const roaming_mod = @import("roaming.zig");
const group_mod = @import("roam_group.zig");

const default_scale: u32 = 4;
const max_scale: u32 = 12;
const default_top: u32 = 32;
const frame_ms: i32 = 33;

/// Integer zoom of the 16x16 art, chosen on the command line.
var scale: u32 = default_scale;
/// Window edge in pixels: sprites.W * scale.
var size: u32 = sprites.W * default_scale;
/// Pixels reserved at the top of the screen (GNOME's bar) that the cat hangs below.
var top: u32 = default_top;
var mute: bool = false;
var roam: bool = false;
var roam_group: ?[]const u8 = null;
var character: *const sprites.Character = &sprites.cat;
/// Instance name: selects pet-NAME.fifo so several pets can run at once.
var instance: ?[]const u8 = null;

const usage =
    \\usage: pet [--pet cat|dog|rabbit] [--name NAME] [--scale N] [--top N] [--roam | --roam-group NAME] [--mute] [--help]
    \\
    \\A small animal that lives on the edges of your screen.
    \\
    \\  --pet KIND  which animal: cat (default), dog or rabbit
    \\  --name NAME run as a named instance with its own command pipe (pet-NAME), so you can
    \\              run several at once and address each with petctl -n NAME
    \\  --scale N   pixel zoom of the 16x16 art, 1..12 (default 4 = 64px)
    \\  --top N     pixels reserved for the top panel; the cat hangs below it (default 32)
    \\  --roam      visit other monitors, follow the pointer and drag between them
    \\              (default: stay on the primary monitor)
    \\  --roam-group NAME  roam together with pets in this group, with space between them
    \\  --mute      no sounds
    \\  -h, --help  show this help
    \\
    \\Mouse:  left-click = meow, drag = carry (it falls when dropped), rest the pointer on it = paw swipe, right-click = quit
    \\
++ "Pipe:   " ++ switch (builtin.os.tag) {
    .windows => "petctl.ps1 fail      (writes to \\\\.\\pipe\\pet)",
    .macos => "echo fail > /tmp/pet.fifo",
    else => "echo fail > $XDG_RUNTIME_DIR/pet.fifo",
} ++ "   (ok, fail, work, done, climb, sleep, wake, meow, say TEXT, goto X, quit)\n";

pub fn main(init: std.process.Init) !void {
    parseArgs(init.minimal.args, init.arena.allocator());

    var win = try backend.Window.init(size, size);
    defer win.deinit();
    win.show();

    // The speech bubble is a second, fully click-through window sized for the
    // longest message; only the part a message needs gets painted.
    const text_scale: u32 = @max(1, scale / 2);
    const bubble_max = font.Layout.forChars(petmod.Pet.max_say, text_scale);
    var bubble_win = try backend.Window.init(bubble_max.w, bubble_max.h);
    defer bubble_win.deinit();
    bubble_win.setInputShape(&.{});
    var bubble_shown = false;
    var bubble_text: [petmod.Pet.max_say]u8 = undefined;
    var bubble_len: usize = 0;
    var bubble_layout = bubble_max;

    var commands: ?channel.Channel = channel.Channel.open(instance) catch |err| blk: {
        std.debug.print("pet: no command channel ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (commands) |*ch| ch.close();

    var prng = std.Random.DefaultPrng.init(@intCast(nowNs()));
    var pet = petmod.Pet.init(
        prng.random(),
        character,
        @floatFromInt(win.screen_w),
        @floatFromInt(win.screen_h),
        @floatFromInt(size),
        @floatFromInt(top),
    );

    var audio = audio_mod.Audio.init(!mute);
    var roaming = roaming_mod.Roaming.init(prng.random());
    var group: ?group_mod.Group = if (roam_group) |n| group_mod.Group.open(n, nowNs() ^ (@as(u64, os.pid()) << 32)) catch |err| blk: {
        if (builtin.os.tag != .windows) return err;
        std.debug.print("pet: roaming groups are not supported on Windows yet; roaming alone\n", .{});
        break :blk null;
    } else null;
    defer if (group) |*g| g.close();
    var group_revision: u64 = 0;
    var manual_walk = false;

    std.debug.print("pet: a {s}{s}{s}\n", .{ character.name, if (instance != null) " named " else "", instance orelse "" });

    std.debug.print("pet: {d}x{d} screen, {s} window ({s} backend)\n", .{ win.screen_w, win.screen_h, if (win.argb) "transparent" else "opaque (no ARGB visual)", win.backendName() });
    if (roam) std.debug.print("pet: roaming between monitors\n", .{});
    if (roam_group) |n| std.debug.print("pet: roaming with group {s}\n", .{n});
    if (commands) |ch| std.debug.print("pet: commands via  echo fail > {s}\n", .{ch.path()});
    std.debug.print("pet: left-click = meow, drag = carry, right-click = quit\n", .{});

    var last_ms = nowMs();
    var last_ptr = win.queryPointer();
    var drag: ?struct { ox: i32, oy: i32, px: i32, py: i32, moved: bool } = null;
    var last_frame: ?*const sprites.Frame = null;
    var last_transform = pet.transform();
    var raise_timer: f32 = 0;
    const debug_events = os.getenv("PET_DEBUG") != null;
    var bubble_logged = false;

    while (true) {
        backend.wait(&.{ &win, &bubble_win }, if (commands) |ch| ch.wakeFd() else null, frame_ms);

        var input: petmod.Input = .{ .pointer_x = 0, .pointer_y = 0, .pointer_moved = false };
        var requested_monitor: ?backend.Monitor = null;

        while (win.pollEvent()) |ev| switch (ev) {
            .press => |p| switch (p.button) {
                1 => {
                    if (debug_events) std.debug.print("pet: press at {d},{d}\n", .{ p.x, p.y });
                    drag = .{ .ox = p.x, .oy = p.y, .px = p.x_root, .py = p.y_root, .moved = false };
                },
                3 => return,
                else => {},
            },
            .release => |r| if (r.button == 1) {
                if (debug_events) std.debug.print("pet: release, drag={?}\n", .{drag});
                if (drag) |d| {
                    if (!d.moved) input.clicked = true;
                    input.drop = true;
                }
                drag = null;
            },
            .motion => |m| if (drag) |*d| {
                if (!d.moved and (@abs(m.x_root - d.px) > 3 or @abs(m.y_root - d.py) > 3)) d.moved = true;
                if (d.moved) input.drag = .{
                    .x = @floatFromInt(m.x_root - d.ox),
                    .y = @floatFromInt(m.y_root - d.oy),
                };
            },
            .expose => last_frame = null,
            .screen_changed => {
                pet.resize(@floatFromInt(win.screen_w), @floatFromInt(win.screen_h));
                input.drag = null;
                if (pet.state == .held) input.drop = true;
                drag = null;
                last_ptr = win.queryPointer();
            },
            .disconnected => return,
        };
        // The bubble is click-through, so nothing it reports matters, but its
        // socket (or X connection) must still be read: the GNOME backend sends
        // pointer updates to every window, and an unread socket fills up and
        // blocks the sender, which on GNOME is the shell itself.
        while (bubble_win.pollEvent()) |ev| {
            if (ev == .disconnected) return;
        }

        var ptr = win.queryPointer();
        input.pointer_x = @floatFromInt(ptr.x);
        input.pointer_y = @floatFromInt(ptr.y);
        input.pointer_moved = ptr.x != last_ptr.x or ptr.y != last_ptr.y;
        const follows_pointer = drag != null or input.drag != null or (!manual_walk and roaming_mod.Roaming.ready(&pet));
        if (roam and follows_pointer and (input.pointer_moved or input.drag != null)) {
            if (win.monitors.at(ptr.x + win.origin_x, ptr.y + win.origin_y)) |m| {
                if (m.x != win.origin_x or m.y != win.origin_y or m.w != win.screen_w or m.h != win.screen_h) {
                    requested_monitor = m;
                    const dx = win.origin_x - m.x;
                    const dy = win.origin_y - m.y;
                    pet.relocate(@floatFromInt(dx), @floatFromInt(dy), @floatFromInt(m.w), @floatFromInt(m.h));
                    win.useMonitor(m);
                    roaming.reset(prng.random());
                    if (drag) |*d| {
                        d.px += dx;
                        d.py += dy;
                    }
                    if (input.drag) |*d| {
                        d.x += @floatFromInt(dx);
                        d.y += @floatFromInt(dy);
                    }
                    ptr.x += dx;
                    ptr.y += dy;
                    input.pointer_x = @floatFromInt(ptr.x);
                    input.pointer_y = @floatFromInt(ptr.y);
                    if (debug_events) std.debug.print("pet: monitor {d},{d} {d}x{d}\n", .{ m.x, m.y, m.w, m.h });
                }
            }
        }
        // Both windows use the same monitor-local coordinates, even while roaming.
        bubble_win.useMonitor(.{ .x = win.origin_x, .y = win.origin_y, .w = win.screen_w, .h = win.screen_h });
        last_ptr = ptr;

        if (commands) |*ch| while (ch.pollCommand()) |cmd| switch (cmd) {
            .pet => |e| pet.onEvent(e),
            .goto => |x| {
                pet.goTo(x);
                manual_walk = group != null and pet.state == .walk;
            },
            .say => |text| pet.say(text),
            .quit => return,
        };

        const now = nowMs();
        const dt: f32 = @floatCast(@min((now - last_ms) / 1000.0, 0.1));
        last_ms = now;
        pet.autonomous_walk = group == null;
        pet.update(dt, input);
        if (manual_walk and pet.state != .walk) {
            manual_walk = false;
            group_revision = 0;
        }
        const free_to_roam = drag == null and input.drag == null and !input.drop and !input.clicked;
        if (group) |*g| {
            const current: backend.Monitor = .{ .x = win.origin_x, .y = win.origin_y, .w = win.screen_w, .h = win.screen_h };
            const ready = free_to_roam and !manual_walk and roaming_mod.Roaming.ready(&pet);
            // Advancing an autonomous visit during pointer motion would bring
            // it straight back on the next pointer update. Existing plans and
            // explicit monitor requests can still be adopted while it moves.
            const polled = g.poll(@intFromFloat(now), size, &win.monitors, current, requested_monitor, ready and !input.pointer_moved, prng.random()) catch |err| blk: {
                std.debug.print("pet: leaving group {s} ({s}); roaming alone\n", .{ roam_group.?, @errorName(err) });
                g.close();
                group = null;
                break :blk null;
            };
            if (polled) |plan| {
                if (ready) {
                    const changed = !std.meta.eql(current, plan.monitor);
                    if (changed) {
                        const m = plan.monitor;
                        pet.relocate(@floatFromInt(current.x - m.x), @floatFromInt(current.y - m.y), @floatFromInt(m.w), @floatFromInt(m.h));
                        win.useMonitor(m);
                        bubble_win.useMonitor(m);
                        last_ptr = win.queryPointer();
                    }
                    if (changed or plan.revision != group_revision) {
                        pet.walkTo(plan.target_x);
                        group_revision = plan.revision;
                        if (debug_events) std.debug.print("pet: group {s} monitor {d},{d} walk to {d:.1}\n", .{ roam_group.?, plan.monitor.x, plan.monitor.y, plan.target_x });
                    }
                }
            }
        } else if (roam and free_to_roam and !input.pointer_moved) {
            const current: backend.Monitor = .{ .x = win.origin_x, .y = win.origin_y, .w = win.screen_w, .h = win.screen_h };
            if (roaming.tick(dt, &win.monitors, current, &pet)) |m| {
                pet.relocate(@floatFromInt(current.x - m.x), @floatFromInt(current.y - m.y), @floatFromInt(m.w), @floatFromInt(m.h));
                win.useMonitor(m);
                bubble_win.useMonitor(m);
                // A visit starts a walk on the destination's floor. Offset or
                // disconnected screens require a hop rather than crossing a gap.
                pet.walkTo(pet.size / 2 + prng.random().float(f32) * @max(0, pet.screen_w - pet.size));
                last_ptr = win.queryPointer();
                if (debug_events) std.debug.print("pet: visiting monitor {d},{d} {d}x{d}\n", .{ m.x, m.y, m.w, m.h });
            }
        }

        if (pet.takeSound()) |snd| {
            const clip = switch (snd) {
                .poke => character.sound_poke,
                .happy => character.sound_happy,
                .angry => character.sound_angry,
            };
            if (clip) |name| audio.play(name);
        }

        const frame = pet.frame();
        const transform = pet.transform();
        if (frame != last_frame or transform != last_transform) {
            render(win.pixels, frame, transform, win.argb);
            if (win.argb) applyInputShape(&win);
            last_frame = frame;
            last_transform = transform;
            win.present();
        }
        win.move(@intFromFloat(pet.x), @intFromFloat(pet.y));

        if (pet.bubble()) |text| {
            if (!bubble_shown or !std.mem.eql(u8, text, bubble_text[0..bubble_len])) {
                @memcpy(bubble_text[0..text.len], text);
                bubble_len = text.len;
                bubble_layout = font.Layout.forChars(text.len, text_scale);
                @memset(bubble_win.pixels[0 .. bubble_win.w * bubble_win.h], if (bubble_win.argb) 0 else 0xFF1E1E1E);
                font.drawBubble(bubble_win.pixels, bubble_win.w, bubble_layout, text);
                bubble_win.present();
                if (!bubble_shown) bubble_win.show();
                bubble_shown = true;
            }
            // Centre the painted part over the cat; below it when it hangs from the top.
            const bw: i32 = @intCast(bubble_layout.w);
            const bh: i32 = @intCast(bubble_layout.h);
            const cat_x: i32 = @intFromFloat(pet.x);
            const cat_y: i32 = @intFromFloat(pet.y);
            const half: i32 = @intCast(size / 2);
            const bx = std.math.clamp(cat_x + half - @divTrunc(bw, 2), 0, @max(0, win.screen_w - bw));
            const above = cat_y - bh - 2;
            const wanted_y = if (above >= 0) above else cat_y + @as(i32, @intCast(size)) + 2;
            const by = std.math.clamp(wanted_y, 0, @max(0, win.screen_h - bh));
            bubble_win.move(bx, by);
            if (debug_events and !bubble_logged) {
                std.debug.print("pet: bubble '{s}' {d}x{d} at {d},{d}\n", .{ text, bw, bh, bx, by });
                bubble_logged = true;
            }
        } else if (bubble_shown) {
            bubble_win.hide();
            bubble_shown = false;
            bubble_logged = false;
        }

        raise_timer += dt;
        if (raise_timer > 1.0) {
            win.raise();
            if (bubble_shown) bubble_win.raise();
            raise_timer = 0;
        }
        win.flush();
        // The bubble is its own window (own X connection), so it needs its own flush.
        bubble_win.flush();
    }
}

/// Argument strings (the instance and group names) are kept for the whole
/// run, so the iterator's buffer comes from the process arena. Windows needs
/// one to decode its command line; elsewhere it is unused.
fn parseArgs(args: std.process.Args, arena: std.mem.Allocator) void {
    var it = args.iterateAllocator(arena) catch fail("cannot read the command line");
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--scale")) {
            const value = it.next() orelse fail("--scale needs a number");
            scale = std.fmt.parseInt(u32, value, 10) catch fail("--scale needs a number");
            if (scale < 1 or scale > max_scale) fail("--scale must be between 1 and 12");
        } else if (std.mem.eql(u8, arg, "--top")) {
            const value = it.next() orelse fail("--top needs a number");
            top = std.fmt.parseInt(u32, value, 10) catch fail("--top needs a number");
        } else if (std.mem.eql(u8, arg, "--mute")) {
            mute = true;
        } else if (std.mem.eql(u8, arg, "--roam")) {
            roam = true;
        } else if (std.mem.eql(u8, arg, "--roam-group")) {
            const value = it.next() orelse fail("--roam-group needs a group name");
            if (value.len == 0 or value.len > 32) fail("group names must be 1..32 characters");
            for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') fail("group names may only use letters, digits, - and _");
            roam_group = value;
            roam = true;
        } else if (std.mem.eql(u8, arg, "--pet")) {
            const value = it.next() orelse fail("--pet needs cat, dog or rabbit");
            character = sprites.byName(value) orelse fail("--pet needs cat, dog or rabbit");
        } else if (std.mem.eql(u8, arg, "--name")) {
            const value = it.next() orelse fail("--name needs a name");
            if (value.len == 0 or value.len > 32) fail("--name must be 1..32 characters");
            for (value) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') fail("--name may only use letters, digits, - and _");
            instance = value;
        } else {
            fail(arg);
        }
    }
    size = sprites.W * scale;
}

fn fail(msg: []const u8) noreturn {
    std.debug.print("pet: bad argument: {s}\n\n{s}", .{ msg, usage });
    std.process.exit(2);
}

/// Expand the 16x16 frame into the window buffer with the requested orientation.
fn render(dst: [*]u32, frame: *const sprites.Frame, transform: petmod.Transform, argb: bool) void {
    const bg: u32 = if (argb) 0 else 0xFF1E1E1E;
    for (0..size) |y| {
        for (0..size) |x| {
            const dx: i32 = @intCast(x / scale);
            const dy: i32 = @intCast(y / scale);
            const src = sprites.source(transform, dx, dy);
            const sx: i32 = src.x;
            var sy: i32 = src.y;
            sy += frame.dy;
            var px: u32 = 0;
            if (sy >= 0 and sy < sprites.H) px = frame.px[@intCast(sy)][@intCast(sx)];
            dst[y * size + x] = if (px >> 24 == 0) bg else px;
        }
    }
}

/// Build horizontal runs of opaque pixels so only the cat itself is clickable.
fn applyInputShape(win: *backend.Window) void {
    var rects: [sprites.W * max_scale * (sprites.W / 2 + 1)]backend.Rect = undefined;
    var n: usize = 0;
    for (0..size) |y| {
        var x: usize = 0;
        while (x < size) {
            if (win.pixels[y * size + x] >> 24 == 0) {
                x += 1;
                continue;
            }
            const start = x;
            while (x < size and win.pixels[y * size + x] >> 24 != 0) x += 1;
            rects[n] = .{
                .x = @intCast(start),
                .y = @intCast(y),
                .w = @intCast(x - start),
                .h = 1,
            };
            n += 1;
        }
    }
    win.setInputShape(rects[0..n]);
}

fn nowNs() u64 {
    return os.nowNs();
}

fn nowMs() f64 {
    return @as(f64, @floatFromInt(nowNs())) / 1_000_000.0;
}

test {
    std.testing.refAllDecls(@This());
}
