const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Window backend. Linux: auto (default: the GNOME Shell extension when it
    // is running, else X11), x11, or gnome alone. Windows: win32. macOS: appkit.
    // New backends are added to this enum and to src/backend.zig.
    const Backend = enum { auto, x11, gnome, win32, appkit };
    const os = target.result.os.tag;
    const default_backend: Backend = switch (os) {
        .windows => .win32,
        .macos => .appkit,
        else => .auto,
    };
    const backend = b.option(Backend, "backend", "window backend: auto (Linux default), x11, gnome, win32 (Windows), appkit (macOS)") orelse default_backend;
    const build_options = b.addOptions();
    build_options.addOption(Backend, "backend", backend);
    // Cross builds have no system X11 to find: point this at a tree made by
    // tools/cross_sysroot.py (usr/include, usr/lib/<arch>-linux-gnu).
    const x11_sysroot = b.option([]const u8, "x11-sysroot", "X11 headers and libraries for cross builds (tools/cross_sysroot.py)");

    // libc headers, plus Xlib/XFixes/XRandR on Linux, translated once by the build.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    if (x11_sysroot) |root| translate.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) });

    const exe = b.addExecutable(.{
        .name = "pet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = translate.createModule() },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    switch (backend) {
        .auto, .x11 => {
            exe.root_module.linkSystemLibrary("X11", .{});
            exe.root_module.linkSystemLibrary("Xfixes", .{});
            exe.root_module.linkSystemLibrary("Xext", .{});
            exe.root_module.linkSystemLibrary("Xrandr", .{});
            if (x11_sysroot) |root| {
                const triple = b.fmt("{s}-linux-gnu", .{@tagName(target.result.cpu.arch)});
                exe.root_module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib", triple }) });
            }
        },
        .gnome => {},
        // win32.zig, win_pipe.zig and audio/win.zig declare their own externs.
        .win32 => {
            exe.root_module.linkSystemLibrary("user32", .{});
            exe.root_module.linkSystemLibrary("gdi32", .{});
            exe.root_module.linkSystemLibrary("winmm", .{});
        },
        // appkit.zig loads AppKit and the Objective-C runtime with dlopen, so
        // the binary links only libSystem and cross-compiles without an SDK.
        .appkit => {},
    }
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the desktop pet");
    run_step.dependOn(&run_cmd.step);

    // `zig build sheet` writes every animation frame to zig-out/sheet.ppm so the
    // art can be checked without launching the overlay.
    const sheet = b.addExecutable(.{
        .name = "sheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sheet.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = translate.createModule() },
                .{ .name = "sprites", .module = b.createModule(.{ .root_source_file = b.path("src/sprites.zig"), .target = target, .optimize = optimize }) },
                .{ .name = "font", .module = b.createModule(.{ .root_source_file = b.path("src/font.zig"), .target = target, .optimize = optimize }) },
            },
        }),
    });
    const run_sheet = b.addRunArtifact(sheet);
    run_sheet.addArg("zig-out/sheet.ppm");
    b.step("sheet", "Dump all sprite frames to zig-out/sheet.ppm").dependOn(&run_sheet.step);

    // `zig build frames -Dframes-dir=DIR` also writes each frame as raw RGBA
    // for tools/make_gifs.py, which renders the README's GIFs.
    if (b.option([]const u8, "frames-dir", "where `zig build frames` writes raw RGBA frames")) |dir| {
        const run_frames = b.addRunArtifact(sheet);
        run_frames.addArgs(&.{ "zig-out/sheet.ppm", dir });
        b.step("frames", "Write every sprite frame as raw RGBA to -Dframes-dir").dependOn(&run_frames.step);
    }

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
