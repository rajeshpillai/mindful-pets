#!/usr/bin/env python3
"""Render the README's animated GIFs from the real sprite frames.

    python3 tools/make_gifs.py        (needs Pillow)

Runs `zig build frames` (tools/sheet.zig with a frames directory), then writes docs/img/:
  pets.gif         all three pets walk in, then go through their reactions
  NAME-walk.gif    one walking pet per character
  react-ANIM.gif   the three pets side by side in one reaction
Frame timings follow Pet.frame() in src/pet.zig.
"""
import os
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "img"
PETS = ["cat", "dog", "rabbit"]
# Seconds per frame, as in Pet.frame(). sit blinks briefly every 4 s.
TIMING = {"idle": 0.7, "walk": 0.12, "sleep": 0.9, "happy": 0.4, "angry": 0.15,
          "work": 0.2, "bat": 0.35, "alert": 1.0, "held": 1.0, "sit": 1.0}
BG = (236, 231, 222)
FLOOR = (200, 192, 178)
SCALE = 6
SPRITE = 16 * SCALE
STEP = 1 / 25  # GIF tick for composed scenes


def load(frames_dir):
    frames = {}
    for f in sorted(os.listdir(frames_dir)):
        name, anim, idx = f[:-len(".rgba")].split("-")
        data = (frames_dir / f).read_bytes()
        img = Image.frombytes("RGBA", (16, 16), data).resize((SPRITE, SPRITE), Image.NEAREST)
        frames.setdefault((name, anim), []).append((int(idx), img))
    return {k: [img for _, img in sorted(v)] for k, v in frames.items()}


def at(frames, pet, anim, t):
    seq = frames[(pet, anim)]
    return seq[int(t / TIMING[anim]) % len(seq)]


def canvas(w, h):
    img = Image.new("RGB", (w, h), BG)
    img.paste(FLOOR, (0, h - 6, w, h))
    return img


def save(path, images, step):
    # Merge runs of identical frames so the files stay small.
    out, durations = [], []
    for img in images:
        if out and img.tobytes() == out[-1].tobytes():
            durations[-1] += step
        else:
            out.append(img)
            durations.append(step)
    pal = [im.convert("P", palette=Image.ADAPTIVE, colors=64) for im in out]
    pal[0].save(path, save_all=True, append_images=pal[1:], loop=0,
                duration=[round(d * 1000) for d in durations], optimize=True, disposal=1)
    print(f"wrote {path.relative_to(ROOT)} ({path.stat().st_size // 1024} KiB)")


def scene(frames, script, width):
    """script: list of (anim, seconds, walking). Pets walk in from the left."""
    h = SPRITE + 18
    slot = width // len(PETS)
    images, t_total = [], sum(s for _, s, _ in script)
    t = 0.0
    while t < t_total:
        acc, anim, walk_t, phase_t = 0.0, None, 0.0, 0.0
        for a, secs, walking in script:
            if t < acc + secs:
                anim, phase_t = a, t - acc
                walk_t = secs if walking else 0
                break
            acc += secs
        img = canvas(width, h)
        for i, pet in enumerate(PETS):
            home = i * slot + (slot - SPRITE) // 2
            x = home
            if walk_t:
                start = -SPRITE - (len(PETS) - 1 - i) * 30
                x = int(start + (home - start) * min(1.0, phase_t / walk_t))
            sprite = at(frames, pet, anim, phase_t)
            img.paste(sprite, (x, h - 6 - SPRITE), sprite)
        images.append(img)
        t += STEP
    return images


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["zig", "build", "frames", f"-Dframes-dir={tmp}"], cwd=ROOT, check=True)
        frames = load(pathlib.Path(tmp))

    width = 3 * (SPRITE + 60)
    show = [("walk", 2.4, True), ("idle", 1.4, False), ("happy", 1.6, False),
            ("work", 1.6, False), ("angry", 1.2, False), ("bat", 1.4, False),
            ("sleep", 2.7, False)]
    save(OUT / "pets.gif", scene(frames, show, width), STEP)

    for pet in PETS:
        seq = frames[(pet, "walk")]
        imgs = []
        for img in seq:
            c = canvas(SPRITE + 24, SPRITE + 18)
            c.paste(img, (12, 12), img)
            imgs.append(c)
        save(OUT / f"{pet}-walk.gif", imgs, TIMING["walk"])

    for anim in ["happy", "angry", "work", "sleep", "alert", "bat"]:
        n = max(len(frames[(p, anim)]) for p in PETS)
        secs = max(TIMING[anim] * n, 1.0)
        imgs, t = [], 0.0
        while t < secs:
            c = canvas(3 * (SPRITE // 2 + 8) + 8, SPRITE // 2 + 14)
            for i, pet in enumerate(PETS):
                s = at(frames, pet, anim, t).resize((SPRITE // 2, SPRITE // 2), Image.NEAREST)
                c.paste(s, (8 + i * (SPRITE // 2 + 8), 8), s)
            imgs.append(c)
            t += min(TIMING[anim], 0.1)
        save(OUT / f"react-{anim}.gif", imgs, min(TIMING[anim], 0.1))


if __name__ == "__main__":
    sys.exit(main())
