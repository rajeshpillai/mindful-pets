//! Dev tool: writes every sprite frame, scaled 4x on a checkerboard, to a
//! binary PPM so the art can be reviewed with any image viewer.
//! Usage: sheet OUT.ppm [FRAMES_DIR]
//! With FRAMES_DIR, also writes each frame as raw 16x16 RGBA
//! (NAME-ANIM-I.rgba, alpha last) for tools/make_gifs.py.

const std = @import("std");
const c = @import("c");
const sprites = @import("sprites");
const font = @import("font");

const scale = 4;
const cell = sprites.W * scale;
const gap = 4;

const anims = [_][]const u8{ "idle", "walk", "sit", "sleep", "alert", "happy", "angry", "work", "bat", "held" };

fn framesOf(ch: *const sprites.Character, anim: []const u8) []const sprites.Frame {
    inline for (anims) |name| {
        if (std.mem.eql(u8, name, anim)) return @field(ch, name);
    }
    unreachable;
}

/// One row per animation per character, characters side by side.
const Row = struct { frames: []const sprites.Frame };
const rows = blk: {
    var out: [anims.len]Row = undefined;
    for (anims, 0..) |a, i| out[i] = .{ .frames = framesOf(&sprites.cat, a) };
    break :blk out;
};

pub fn main(init: std.process.Init) !void {
    var it = init.minimal.args.iterate();
    _ = it.skip();
    const out_path = it.next() orelse "sheet.ppm";
    if (it.next()) |dir| try writeFrames(dir);

    const transforms = [_]sprites.Transform{ .none, .flip_h, .flip_v, .rot180, .wall_left, .wall_right };
    // Each character gets a column block 4 frames wide.
    const block = 4 * (cell + gap) + gap;
    const sample = "Hello world 0123 ok?!";
    const bubble = font.Layout.forChars(sample.len, 2);
    const width = @max(@max(sprites.all.len * block, transforms.len * (cell + gap) + gap), bubble.w + 2 * gap);
    const height = (anims.len + 1) * (cell + gap) + gap + bubble.h + gap;

    const buf = try init.gpa.alloc(u8, width * height * 3);
    defer init.gpa.free(buf);

    // Checkerboard background makes transparency visible.
    for (0..height) |y| for (0..width) |x| {
        const light = ((x / 8) + (y / 8)) % 2 == 0;
        const v: u8 = if (light) 0x9a else 0x7a;
        const i = (y * width + x) * 3;
        buf[i] = v;
        buf[i + 1] = v;
        buf[i + 2] = v;
    };

    for (sprites.all, 0..) |ch, ci| for (anims, 0..) |a, ri| for (framesOf(ch, a), 0..) |frame, fi| {
        const ox = ci * block + gap + fi * (cell + gap);
        const oy = gap + ri * (cell + gap);
        for (0..cell) |y| for (0..cell) |x| {
            const px = frame.px[y / scale][x / scale];
            if (px >> 24 == 0) continue;
            const i = ((oy + y) * width + (ox + x)) * 3;
            buf[i] = @truncate(px >> 16);
            buf[i + 1] = @truncate(px >> 8);
            buf[i + 2] = @truncate(px);
        };
    };
    _ = rows;

    // Last row: the standing frame in every orientation the renderer supports.
    for (transforms, 0..) |t, ti| {
        const ox = gap + ti * (cell + gap);
        const oy = gap + anims.len * (cell + gap);
        for (0..cell) |y| for (0..cell) |x| {
            const src = sprites.source(t, @intCast(x / scale), @intCast(y / scale));
            const px = sprites.cat.idle[0].px[@intCast(src.y)][@intCast(src.x)];
            if (px >> 24 == 0) continue;
            const i = ((oy + y) * width + (ox + x)) * 3;
            buf[i] = @truncate(px >> 16);
            buf[i + 1] = @truncate(px >> 8);
            buf[i + 2] = @truncate(px);
        };
    }

    // Speech bubble sample at the bottom.
    {
        const tmp = try init.gpa.alloc(u32, @as(usize, bubble.w) * bubble.h);
        defer init.gpa.free(tmp);
        @memset(tmp, 0);
        font.drawBubble(tmp.ptr, bubble.w, bubble, sample);
        const oy = (anims.len + 1) * (cell + gap) + gap;
        for (0..bubble.h) |y| for (0..bubble.w) |x| {
            const px = tmp[y * bubble.w + x];
            if (px >> 24 == 0) continue;
            const i = ((oy + y) * width + (gap + x)) * 3;
            buf[i] = @truncate(px >> 16);
            buf[i + 1] = @truncate(px >> 8);
            buf[i + 2] = @truncate(px);
        };
    }

    var path_buf: [1024:0]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "{s}", .{out_path}, 0);
    const f = c.fopen(path.ptr, "wb") orelse return error.CannotOpenOutput;
    defer _ = c.fclose(f);
    var header: [64]u8 = undefined;
    const h = try std.mem.print(&header, "P6\n{d} {d}\n255\n", .{ width, height });
    _ = c.fwrite(h.ptr, 1, h.len, f);
    _ = c.fwrite(buf.ptr, 1, buf.len, f);
    std.debug.print("sheet: wrote {s} ({d}x{d})\n", .{ out_path, width, height });
}

fn writeFrames(dir: []const u8) !void {
    var n: usize = 0;
    for (sprites.all) |ch| inline for (anims) |a| for (@field(ch, a), 0..) |frame, fi| {
        var path_buf: [1024:0]u8 = undefined;
        const path = try std.mem.printSentinel(&path_buf, "{s}/{s}-{s}-{d}.rgba", .{ dir, ch.name, a, fi }, 0);
        var rgba: [sprites.W * sprites.H * 4]u8 = undefined;
        for (0..sprites.H) |y| for (0..sprites.W) |x| {
            const px = frame.px[y][x];
            const i = (y * sprites.W + x) * 4;
            rgba[i] = @truncate(px >> 16);
            rgba[i + 1] = @truncate(px >> 8);
            rgba[i + 2] = @truncate(px);
            rgba[i + 3] = @truncate(px >> 24);
        };
        const f = c.fopen(path.ptr, "wb") orelse return error.CannotOpenOutput;
        _ = c.fwrite(&rgba, 1, rgba.len, f);
        _ = c.fclose(f);
        n += 1;
    };
    std.debug.print("sheet: wrote {d} frames to {s}\n", .{ n, dir });
}
