#!/usr/bin/env python3
"""Fetch the X11 headers and libraries needed to cross-compile `pet`.

    python3 tools/cross_sysroot.py ARCH [DIR]    ARCH: x86_64 or aarch64
                                                 DIR default: .cache/sysroot/ARCH

Downloads Ubuntu 20.04 (focal) .deb packages over HTTPS, checks them against
the SHA256 in the mirror's package index, and unpacks them into DIR with
dpkg-deb. Then:

    zig build -Dtarget=aarch64-linux-gnu.2.31 -Dx11-sysroot=DIR

Focal is old on purpose: its glibc is 2.31, the version release builds
target, so nothing in the sysroot is newer than the binary claims to need.
Prints DIR on success. Re-running with an existing DIR does nothing.
"""
import hashlib
import lzma
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import urllib.request

RELEASE = "focal"
MIRRORS = {
    "x86_64": ("amd64", "https://archive.ubuntu.com/ubuntu"),
    "aarch64": ("arm64", "https://ports.ubuntu.com/ubuntu-ports"),
}
# Link-time .so symlinks (-dev) and the libraries they point at, plus the
# headers Xrandr.h and Xlib.h pull in.
PACKAGES = [
    "libx11-6", "libx11-dev",
    "libxext6", "libxext-dev",
    "libxfixes3", "libxfixes-dev",
    "libxrandr2", "libxrandr-dev",
    "libxrender1", "libxrender-dev",
    "x11proto-dev", "x11proto-core-dev", "x11proto-xext-dev",
    "x11proto-fixes-dev", "x11proto-randr-dev", "x11proto-render-dev",
]


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def index(arch, mirror):
    out = {}
    for comp in ("main",):
        raw = lzma.decompress(fetch(f"{mirror}/dists/{RELEASE}/{comp}/binary-{arch}/Packages.xz"))
        for stanza in raw.decode("utf-8", "replace").split("\n\n"):
            fields = {}
            for line in stanza.splitlines():
                if line and not line[0].isspace() and ":" in line:
                    k, v = line.split(":", 1)
                    fields[k] = v.strip()
            if "Package" in fields and "Filename" in fields:
                out[fields["Package"]] = fields
    return out


def main():
    if len(sys.argv) not in (2, 3) or sys.argv[1] not in MIRRORS:
        sys.exit(__doc__)
    arch_name = sys.argv[1]
    root = pathlib.Path(__file__).resolve().parent.parent
    dest = pathlib.Path(sys.argv[2] if len(sys.argv) == 3 else root / ".cache" / "sysroot" / arch_name).resolve()
    stamp = dest / ".complete"
    if stamp.exists():
        print(dest)
        return
    arch, mirror = MIRRORS[arch_name]
    pkgs = index(arch, mirror)
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name in PACKAGES:
            info = pkgs.get(name)
            if info is None:
                # Some protos are virtual or merged into x11proto-dev.
                continue
            data = fetch(f"{mirror}/{info['Filename']}")
            if hashlib.sha256(data).hexdigest() != info["SHA256"]:
                sys.exit(f"cross_sysroot: checksum mismatch for {name}")
            deb = os.path.join(tmp, f"{name}.deb")
            with open(deb, "wb") as f:
                f.write(data)
            subprocess.run(["dpkg-deb", "-x", deb, str(dest)], check=True)
    stamp.touch()
    print(dest)


if __name__ == "__main__":
    main()
