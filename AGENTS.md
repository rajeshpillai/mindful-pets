# Agent notes for mindful-pets

Read this before changing anything. README.md is for users, TODO.md is the
roadmap, HANDOFF.md carries session-to-session state.

## What this is

A desktop pet in Zig: a pixel-art cat, dog or rabbit drawn by the GNOME Shell
extension, with a transparent X11 override-redirect window as the fallback
(runs under XWayland on GNOME), a layered window on Windows and an NSPanel on
macOS. It reacts to commands on a named pipe and to Claude Code hooks. `jarvis-bot` was an old
code name; the repo is github.com/rajeshpillai/mindful-pets.

## Commands the user gives

- **"ship it" or "deploy"**: commit and push first if there are changes,
  then run `scripts/ship`. It builds with `-Doptimize=ReleaseSafe`, copies
  `pet` (the `auto` backend) and `petctl` into `~/Desktop/tools`, then tags
  HEAD `vYYYY.MM.DD` (`.N` for later ones that day) and pushes the tag.
  The tag starts `.github/workflows/release.yml`, which cross-builds
  Linux, Windows and macOS archives (x86_64 and aarch64) on one Linux
  runner with `scripts/package` and publishes the
  GitHub release; ship waits for that run and prints the release URL (pass
  it on) or the failed run's URL. It refuses a dirty tree or a HEAD that is
  not `origin/main`. `scripts/ship --no-release` only copies locally.
  The workflow pins the Zig dev build in `release.yml`; bump it when the
  local toolchain moves.
- Zig reference: https://ziglang.in (the user's own site), tracks master.

## Build, test, check

```sh
zig build                 # also required before any live test: `zig build test`
                          # and `zig build sheet` do NOT reinstall the exe
zig build test            # unit tests (state machine, parser, font, characters)
zig build sheet           # all frames -> zig-out/sheet.ppm (check art this way;
                          # GNOME blocks CLI screenshots)
zig fmt --check build.zig src tools
zig build -Dtarget=x86_64-windows-gnu && zig build -Dtarget=aarch64-macos
                          # compile-check the other backends; nothing here can
                          # run them (no Wine, no Mac), so say so when reporting
python3 tools/test_integration.py   # after `zig build`: pet against a fake shell on a private
                                    # socket (monitor changes, bubble disconnect, input
                                    # negotiation, legacy extension) plus full/no-reader FIFOs
node tools/test_extension.mjs       # extension protocol + alpha hit-testing with a stub actor
python3 tools/test_x11.py           # after `zig build`: primary output, off-screen recovery, live
                                    # monitor changes and roaming in a private Xvfb (needs Xvfb,
                                    # xrandr, xdotool; skips without them)
```

Toolchain: Zig master (0.17.0-dev). `@cImport` is gone; C headers go through
`b.addTranslateC` on `src/c.h`. `main(init: std.process.Init)`, args via
`init.minimal.args.iterate()`, `std.mem.printSentinel` for C strings.

## Layout

```
src/main.zig        event loop, flags, rendering, bubble window
src/pet.zig         state machine; knows nothing about X11 or audio
src/monitors.zig    shared desktop-space monitor rectangles (gaps excluded)
src/roaming.zig     optional autonomous monitor visits, waiting for quiet floor states
src/roam_group.zig  named roaming groups: shared plans via non-blocking file locks
src/sprites.zig     Frame format, palette, orientation mapping, Character struct, `all`
src/characters/     cat.zig, dog.zig, rabbit.zig (16x16 ASCII art, facing right)
src/backend.zig     window backend interface: shared types, comptime selection, contract check
src/backend/x11.zig Xlib implementation: window creation, XImage blit, XFixes input shape
src/backend/gnome.zig  client of the GNOME Shell extension over a Unix socket; protocol in extension.js
src/backend/auto.zig   default: probes the extension socket once, then wraps gnome or x11 for every window
src/backend/win32.zig  Windows: layered WS_EX_TOPMOST tool window, UpdateLayeredWindow, own Win32 externs
src/backend/appkit.zig macOS: NSPanel via objc_msgSend; AppKit/QuartzCore dlopen'd so no SDK is needed
src/os.zig          clock, pid, getenv per OS (shared code must not call POSIX directly)
gnome-extension/    mindful-pet@rajeshpillai.github.io: GJS extension, one Clutter actor per pet window
scripts/install-extension  copy the extension into ~/.local/share/gnome-shell/extensions (enable rules inside)
scripts/nested-shell       headless GNOME Shell with the extension, isolated from the real session, for tests;
                           `--ext DIR` loads the repo copy, extra flags go to gnome-shell (`--virtual-monitor WxH`)
src/events.zig      command vocabulary + parser (shared by every channel)
src/channel.zig     command channel interface, chosen by OS; channel/fifo.zig (POSIX), channel/win_pipe.zig (\\.\pipe\pet, PIPE_NOWAIT)
src/audio.zig       embedded WAV clips + playback interface, chosen by OS; audio/shell.zig shells out to a player, audio/win.zig PlaySound
src/font.zig        3x5 font + speech bubble painter
scripts/petctl      send a command; `petctl run CMD`; `-n NAME` for named instances; needs python3
                    (atomic non-blocking write, dropped when the pipe is full)
scripts/pet.sh      shell shortcuts (zb, zt, pet_run, pet_say)
scripts/ship        the "ship it" action
scripts/package     cross-build release archives for linux/windows/macos x x86_64/aarch64 into dist/ (CI runs it; works locally)
scripts/petctl.ps1  Windows petctl (PowerShell, NamedPipeClientStream with a zero connect timeout)
tools/cross_sysroot.py  fetch focal X11 headers/libs per arch into .cache/sysroot for -Dx11-sysroot
.github/workflows/release.yml  v* tag -> scripts/package -> GitHub release
tools/make_gifs.py  README GIFs in docs/img from the sprite frames (`zig build frames`, Pillow)
tools/sheet.zig     sprite sheet dump; tools/gen_sounds.py regenerates src/assets/*.wav
tools/test_integration.py  private-socket/FIFO regressions against a fake shell (python3, needs zig build)
tools/test_extension.mjs   extension protocol and hit-testing checks with a stub actor (node)
tools/test_x11.py          XRandR primary/roaming/resize regressions in a private Xvfb (python3, needs zig build)
.claude/settings.json  hooks: prompt -> work, stop -> ok, notification -> meow + say
```

## Pitfalls that cost time

- VS Code's Python extension runs a tool also named `pet`. Never
  `pkill -x pet` or trust `pgrep -x pet`; track the pet by PID (`$!`).
- Each `x11.Window` opens its own X connection. Anything you do to a window
  must be followed by that window's `flush()` or it silently never happens.
- `std.debug.print` goes to stderr; when testing in the background, read the
  log after a clean quit (`petctl quit`), not after `kill`.
- The pet walks, so a window position read with `xwininfo` is stale within a
  second. xdotool works under XWayland for click/drag tests.
- A Claude Code settings file created mid-session is not loaded until
  `/hooks` or a restart.
- The extension runs on GNOME Shell's main thread. Anything that blocks there
  freezes the whole desktop until a hard reboot; it happened on 2026-10-12
  when a synchronous `write_all` to a pet socket nobody was reading filled the
  kernel buffer. Rules: every write to a pet goes through `writer.js`
  (non-blocking, bounded, drops a pet that stops reading); no `write_all`,
  `read_line` or other synchronous I/O in extension.js; on the pet side every
  window's socket is drained every frame (main.zig polls the bubble too) and
  `gnome.zig` sends with `MSG_DONTWAIT` and gives up on a stalled shell.
- GNOME Shell on Wayland reads an extension's files once. A new extension
  loads after logging out and in, and a running shell keeps the old copy of a
  changed one even across disable/enable, so `scripts/install-extension`
  leaves an already loaded extension disabled until the next login. Test
  changes in a headless shell instead: `scripts/nested-shell` starts one with
  a private runtime dir, private GSettings (keyfile backend, extension
  enabled) and `env -i`, because the shell inherited from the VS Code snap
  carries `GSETTINGS_SCHEMA_DIR`, `XDG_DATA_DIRS` and snap library paths that
  make gnome-shell abort. Run the pet and petctl with
  `XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR/mp-nested`. Its log is the only view you
  get: no screenshots and no pointer in a headless shell. `--ext DIR` loads
  the repo's extension instead of the installed one, and extra flags go to
  gnome-shell, so `--virtual-monitor 1366x768` adds a second monitor for
  stage-origin tests.
- The `gnome` backend reports socket closure once as `disconnected`.
  main.zig quits when either the pet or bubble connection disconnects.
  Monitor updates report `screen_changed`; auto.zig refreshes its mirrored
  geometry before main.zig resizes the state machine.

## Conventions

- Keep compositor-specific code in `src/backend/`. main.zig only uses
  `backend.Window`, `backend.wait` and the shared types in `src/backend.zig`.
  New backend (GNOME Shell extension, AppKit, Win32): add a file beside
  x11.zig exporting `name`, `Window` and `wait`, a value to the `Backend`
  enum in build.zig plus its system libraries, and an arm in the `impl`
  switch in backend.zig, and an arm in auto.zig if it should be auto-detected.
  The comptime block in backend.zig tells you what is missing. `screen_w`
  and `screen_h` may change while running: a backend that learns of monitor
  changes updates them and reports `screen_changed`; one whose connection
  can go away reports `disconnected` once. X11 listens for XRandR geometry
  changes and also checks once a second. Each backend exposes `monitors`,
  `origin_x/y` and `useMonitor`: input and move coordinates remain relative
  to the selected real monitor. Keep every socket operation on the compositor
  side non-blocking.
  The command channel (`src/channel.zig`) and audio (`src/audio.zig`) follow
  the same pattern but select on `builtin.os.tag`. build.zig picks the
  default backend from the target OS (win32, appkit, else auto); `src/c.h`
  guards POSIX and X11 headers with `_WIN32`/`__linux__`, and shared code
  goes through `src/os.zig`. An `@import` in a switch arm must name an
  existing file even when that arm is never taken.
- New reaction: add frames to every file in `src/characters/` and a field in
  `sprites.Character`, a `State`/`Event` in pet.zig, a word in
  `events.parse`, the usage string in main.zig, `anims` in tools/sheet.zig,
  and the README table. Changed art: rerun `python3 tools/make_gifs.py`.
- Commit messages: imperative summary line, body with bullets, co-author
  trailer as configured. Push to `origin main` after committing.
