# mindful-pets

A tiny desktop pet written in Zig: a pixel-art cat, dog or rabbit that lives
on the edges of your screen. It wanders, naps, climbs the sides, hangs from the top, drops
down, chases your mouse, swipes at it, and reacts with sounds to events you
send it from scripts (a failed build, a finished deploy, a Claude Code hook).

<p align="center"><img src="docs/img/pets.gif" alt="The cat, dog and rabbit walk in, then idle, purr, type, hiss, swipe and fall asleep" width="468"></p>

| Cat | Dog | Rabbit |
| :---: | :---: | :---: |
| <img src="docs/img/cat-walk.gif" alt="cat walking" width="60"> `--pet cat` | <img src="docs/img/dog-walk.gif" alt="dog walking" width="60"> `--pet dog` | <img src="docs/img/rabbit-walk.gif" alt="rabbit walking" width="60"> `--pet rabbit` |

The GIFs are rendered from the sprite data by `tools/make_gifs.py`.

It is a prototype. The default backend uses the GNOME Shell extension when
available and otherwise talks to X11 through XWayland. See [Limitations](#limitations).

## Requirements

- Zig master (built against `0.17.0-dev.2056`, see `build.zig.zon`)
- X11 development headers and libraries: `libx11-dev`, `libxfixes-dev`, `libxext-dev`,
  `libxrandr-dev` (Debian/Ubuntu names). All builds translate the shared C header;
  the X11/auto runtime links `libX11`, `libXfixes`, `libXext`, `libXrandr`.
  The GNOME-only runtime does not link these libraries.
- An X server or XWayland with a 32-bit ARGB visual (any compositing desktop)
- For sound, one of `pw-play`, `paplay`, `aplay` or `ffplay` on PATH (optional)
- Python 3 for `scripts/petctl` (non-blocking command writes)

## Download

Each [release](https://github.com/rajeshpillai/mindful-pets/releases) has
prebuilt Linux archives for x86_64 and aarch64 (glibc 2.31 or newer, so
Ubuntu 20.04, Debian 11, Fedora 32 and later). Unpack one, run
`scripts/install-extension` if you use GNOME (then log out and in once),
and start `./pet`. The runtime libraries `libX11`, `libXext`, `libXfixes`
and `libXrandr` are already on any X11 or XWayland desktop.

## Build and run

```sh
zig build            # binary lands in zig-out/bin/pet
zig build run        # build and launch
zig build run -- --scale 6
zig build run -- --pet dog --name rex   # a second animal with its own pipe
zig build test       # unit tests for the state machine and command parser
zig build sheet      # dump every animation frame to zig-out/sheet.ppm
python3 tools/test_integration.py  # private sockets/FIFOs; no real desktop is touched
node tools/test_extension.mjs     # extension protocol and click-through checks (Node.js)
python3 tools/test_x11.py         # primary/roaming/resize checks (Xvfb, xrandr, xdotool)
```

To cross-compile, fetch the target's X11 libraries once and point the build
at them (this is what `scripts/package` does for the release archives):

```sh
python3 tools/cross_sysroot.py aarch64      # prints .cache/sysroot/aarch64
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-gnu.2.31 \
  -Dx11-sysroot=$PWD/.cache/sysroot/aarch64
```

## Command line

```
pet [--pet cat|dog|rabbit] [--name NAME] [--scale N] [--top N] [--roam | --roam-group NAME] [--mute] [--help]

  --pet KIND  which animal: cat (default), dog or rabbit
  --name NAME run as a named instance listening on pet-NAME.fifo, so you can
              run several at once and address each with petctl -n NAME
  --scale N   pixel zoom of the 16x16 art, 1..12 (default 4 = 64px)
  --top N     pixels reserved for the top panel; the cat hangs below it (default 32)
  --roam      visit other monitors, follow the pointer and drag between them
              (default: stay on the primary monitor)
  --roam-group NAME  roam together with pets in this group, with space between them
  --mute      no sounds
  -h, --help  show this help
```

Environment:

- `XDG_RUNTIME_DIR` decides where the command pipe is created (falls back to `/tmp`).
- `PET_DEBUG=1` logs mouse button events to stderr.

## Using the cat

Mouse:

| Action | Result |
| --- | --- |
| Move the pointer near it | It runs after the pointer and sits down beside it. Several pets each pick their own spot, so they do not pile up. |
| Rest the pointer on it | After about a second it swipes a paw at it. <img src="docs/img/react-bat.gif" alt="swiping a paw" width="96" align="right"> |
| Left click | It startles and meows. |
| Drag | Carry it anywhere. Drop it above the floor and it falls. |
| Right click | Quit. |

Clicks only land on the cat's opaque pixels. The transparent part of its
window passes clicks through to whatever is underneath.

Pets stay on the primary monitor by default. Pass `--roam` to follow the
pointer between monitors, carry a pet across them, and let it visit another
monitor on its own every 30–60 seconds while idle, sitting or walking.
Visits wait for sleep, work, reactions, climbing and dragging to finish.
Pointer following also waits for quiet floor states; dragging still carries
a pet between monitors immediately.
Autonomous visits wait for the pointer to settle so a visit is not immediately
undone by pointer following.
The pet hops to the destination monitor's floor and starts a walk; it never
walks through empty gaps in an offset or stacked layout. A speech bubble
travels with it. Off-screen positions recover at the nearest edge of the
current monitor on the next frame, including after a monitor is removed.

On its own it idles, walks to random spots, sits, blinks, and now and then
heads for a screen edge, climbs it, pauses, and either climbs back down or
hangs upside down from the top edge, walks along it, and drops. After about
45 seconds with nothing happening nearby it falls asleep. Moving the pointer
close to it wakes it up.

Speech: `petctl say "tests green"` puts a bubble over its head for a few
seconds. Scripts can use it as a one-line status display.

Sounds: a meow when clicked or poked, a purr on `ok`, a hiss on `fail`. The
clips are synthesized by `tools/gen_sounds.py` and embedded in the binary;
drop real recordings into `src/assets/` and rebuild to replace them. Pass
`--mute` to silence it.

## Several pets

Each process is one animal. Start more with `--name`, which gives each its
own pipe, and talk to them with `petctl -n NAME` or `PET_NAME=NAME`:

```sh
pet &                              # the cat, on pet.fifo
pet --pet dog --name rex &         # on pet-rex.fifo
pet --pet rabbit --name bun --scale 3 &
petctl -n rex say "walkies"
PET_NAME=bun petctl fail
```

The hooks and shell shortcuts talk to the unnamed pet unless `PET_NAME` is
set in that shell. Each animal has its own sounds: the cat meows, purrs and
hisses, the dog woofs, pants and growls, the rabbit squeaks and thumps.

Each pet with `--roam` chooses its own monitor visits. For pets that should
travel together, give them the same `--roam-group` name:

```sh
pet --name luna --roam-group friends &
pet --pet dog --name rex --roam-group friends &
pet --pet rabbit --name bun --roam &  # independent
```

Group members share monitor visits and walking destinations, with spacing
based on their body sizes. They pick another destination every 8–16 seconds
and visit another monitor every 30–60 seconds. Moving or dragging one member
to another monitor brings available group members along; busy, sleeping or
carried pets rejoin when free. Different group names travel independently.
An explicit `petctl goto X` finishes before its member resumes group plans.
Ordinary walks come from the group plan; naps, climbing and reactions retain
their own behavior. A failed group-state update logs once and lets that pet
continue roaming independently.
If a member cannot see the group's selected monitor (for example, it uses an
older backend or the monitor was removed), it also continues independently
instead of repeatedly changing the group's plan.
A group keeps going if a member quits. Use unique `--name` values so each
pet also has its own command pipe. Groups support up to 32 pets in the same
desktop session and runtime directory.

Group coordination leaves a small private `pet-roam-UID-GROUP.state` file in
`$XDG_RUNTIME_DIR` (or `/tmp`). It resets after three seconds without active
members; keeping the file avoids splitting a group as pets join or leave.

## Sending it events

The pet listens on a named pipe at `$XDG_RUNTIME_DIR/pet.fifo` (or
`pet-NAME.fifo` for a named instance). Write one command per line:

| Command | Effect | |
| --- | --- | --- |
| `ok`, `pass`, `happy` | Content: eyes closed, little heart. | <img src="docs/img/react-happy.gif" alt="happy" width="96"> |
| `fail`, `error`, `angry` | Hisses, then sulks. | <img src="docs/img/react-angry.gif" alt="angry" width="96"> |
| `work`, `busy` | Sits and types until `ok`, `fail` or `done` arrives (gives up after 15 min). Ignores the pointer meanwhile. | <img src="docs/img/react-work.gif" alt="work" width="96"> |
| `done`, `idle` | Ends `work` without a verdict. | |
| `climb` | Walk to the nearest screen edge and climb it. | |
| `say TEXT` | Show TEXT in a speech bubble for a few seconds (up to 40 characters, uppercase font). | |
| `sleep` | Curls up until woken. | <img src="docs/img/react-sleep.gif" alt="sleep" width="96"> |
| `wake` | Wakes a sleeping cat. | |
| `meow`, `alert`, `poke` | Startle it. | <img src="docs/img/react-alert.gif" alt="alert" width="96"> |
| `goto X` | Walk so its centre ends up at screen x coordinate X. | |
| `quit`, `exit` | Exit. | |

### petctl and shell integration

`scripts/petctl` wraps the pipe and is a silent no-op when the cat is not
running, so it is safe in hooks and makefiles. Writes are non-blocking and
atomic. A full pipe or a command larger than the pipe's atomic-write limit is
dropped, so a stopped pet cannot hold up a hook:

```sh
scripts/petctl fail              # one command
scripts/petctl run zig build     # cat works while the command runs, then ok/fail
```

`scripts/pet.sh` adds shortcuts to your shell. Source it from `~/.bashrc`:

```sh
source /path/to/mindful-pets/scripts/pet.sh
zb            # zig build, cat reacts to the result
zt            # zig build test
pet_run make  # any command
pet_say meow
```

Set `PET_FIFO` to point both at a different pipe. Commands sent while the cat
is not running are dropped: the pet removes its pipe on exit.

### Claude Code

`.claude/settings.json` in this repo wires three hooks: when you submit a
prompt the cat starts typing, when the turn ends it purrs, and when Claude
needs your attention (a permission prompt) it meows and shows the
notification text in a speech bubble. They call
`scripts/petctl`, so nothing happens if the cat is not running. To get the
same in another project, copy that file or merge the `hooks` block into its
`.claude/settings.json`.

### Other ideas

```sh
# git: wake the cat on every commit
echo 'petctl meow' > .git/hooks/post-commit && chmod +x .git/hooks/post-commit

# tests in a watch loop
watchexec -e zig -- petctl run zig build test
```

## Project layout

```
src/main.zig     event loop, argument parsing, rendering into the window buffer
src/pet.zig      the state machine (idle, walk, run, sit, sleep, alert, happy, angry, work, bat, climb, cling, hang, held, fall)
src/sprites.zig  frame format, palette, orientation mapping, Character struct
src/characters/  cat.zig, dog.zig, rabbit.zig: 16x16 ASCII frames per animal
src/backend.zig  window backend interface and selection (`zig build -Dbackend=auto|x11|gnome`)
src/backend/     x11.zig: override-redirect window, XImage blit, XFixes input shape;
                 gnome.zig: Unix-socket client of the GNOME Shell extension;
                 auto.zig: gnome if the extension answers, else x11 (the default)
gnome-extension/ the GNOME Shell extension (one Clutter actor per pet window)
scripts/install-extension  copies it into place; enabled after your next login (a running shell keeps the old copy)
scripts/nested-shell  headless GNOME Shell with the extension, for testing without touching your session
src/events.zig   command vocabulary and parser
src/channel.zig  command channel interface; channel/fifo.zig is the named pipe
src/audio.zig    embedded sound clips and playback interface; audio/shell.zig runs a CLI player
src/font.zig     3x5 bitmap font and the speech-bubble renderer
src/c.h          the C headers translated by build.zig (Xlib, XFixes, libc bits)
src/assets/      WAV clips, embedded at build time by src/audio.zig
tools/gen_sounds.py  regenerates those clips (stdlib Python)
tools/sheet.zig  renders all frames to a PPM for reviewing the art
tools/make_gifs.py  renders the README GIFs into docs/img (Pillow)
tools/test_integration.py  regression tests against a fake shell on a private socket (Python 3)
tools/test_extension.mjs   extension protocol and click-through checks (Node.js)
scripts/petctl   send a command to the pipe, or wrap a command and report its result (Python 3)
scripts/pet.sh   shell shortcuts (zb, zt, pet_run, pet_say)
.claude/         Claude Code hooks that drive the cat
```

To change the art, edit the ASCII blocks in `src/characters/*.zig` (palette
in `src/sprites.zig`) and run `zig build sheet` to check the result. To add
an animal, copy one of those files, register it in `sprites.all`, and give it
sound clip names from `src/assets/` (or null for silence).

## GNOME Shell backend

Without help the pet is an X11 client. Under GNOME on Wayland that means it
runs in XWayland and goes blind whenever the pointer is over a native window.
The `gnome` backend fixes that: the pet becomes a Clutter actor drawn by a
small GNOME Shell extension, which sees the pointer everywhere and keeps the
pet above native windows. The Zig program is unchanged apart from the window
layer; it talks to the extension over a Unix socket.

```sh
scripts/install-extension          # copies gnome-extension/ into ~/.local/share/gnome-shell/extensions
# log out and back in once, so GNOME Shell loads the new extension
gnome-extensions enable mindful-pet@rajeshpillai.github.io
zig build && zig-out/bin/pet       # the default `auto` backend now finds it
```

The default build is the `auto` backend: it uses the extension when it is
running and falls back to X11 otherwise, and the startup log says which. Force
one with `zig build -Dbackend=x11` or `-Dbackend=gnome`. GNOME 46 to 48.

Both backends use the primary monitor by default. X11 reads XRandR monitor
rectangles and the primary output; GNOME reports its primary monitor and,
with protocol v3, the connected monitor rectangles used by `--roam`.

The pet handles changes to the primary monitor's size and position while
running. New clients negotiate monitor coordinates and click-through bubbles;
older clients keep the legacy whole-desktop protocol. A new binary also works
with an older extension, with the older extension's limitations until re-login.
To update an installed extension, run `scripts/install-extension` again and
log out and back in; a running shell keeps the old copy until then.

If the extension is disabled or the shell restarts while a pet is running,
the pet exits cleanly.

## Limitations

- **Wayland with the X11 backend.** The cat is an X11 client, so under GNOME
  Wayland it lives in XWayland. It cannot see the pointer while the pointer is
  over native Wayland windows, so cursor chasing only works over X11
  applications and the cat itself, and it cannot sit on top of native windows
  reliably. Use the GNOME backend above, or on other Wayland compositors wait
  for a wlr-layer-shell backend.
- The top edge is the screen's, not your editor's. Climbing an application
  window needs window geometry, which is the same Wayland gap as above.
- `--roam` needs the current GNOME extension, or XRandR 1.5+ on X11.
  An older extension supplies only its original screen geometry, and an
  X server without monitor information falls back to its root-window size.
- **Linux only** for now. Windowing is X11 or the GNOME Shell extension,
  commands arrive on a POSIX named pipe, and sounds go through
  pw-play/paplay/aplay/ffplay. Any X11 desktop with a compositor works, and
  so does XWayland on GNOME, KDE or Sway. macOS and Windows need a backend of
  their own; see TODO.md.
- Sounds are synthesized placeholders; real recordings are on the roadmap.
