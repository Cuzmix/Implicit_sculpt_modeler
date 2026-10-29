#!/usr/bin/env python3
"""Builds ufbx, the FBX reader Import uses (README "Files"), into deps/ufbx.

    python scripts/build_ufbx.py        # setup_deps runs it; on Windows, cl must be on PATH

It clones ufbx/ufbx at UFBX_TAG (scripts/versions.env) into deps/ufbx-src (its data/
folder of FBX files is what src/fbx's tests read) and compiles src/fbx/fbx_shim.c, which
includes ufbx.c whole, into one static library: deps/ufbx/libufbx.a with clang on Linux and
macOS, deps/ufbx/ufbx.lib with cl /MT on Windows. Android's CMakeLists and `build.sh ios`
compile the same file themselves. A library built from the same tag and shim is kept, so a
second run does nothing.
"""

import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.join(ROOT, "deps")
SRC = os.path.join(DEPS, "ufbx-src")
OUT = os.path.join(DEPS, "ufbx")
SHIM = os.path.join(ROOT, "src", "fbx", "fbx_shim.c")
WINDOWS = os.name == "nt"
LIBRARY = os.path.join(OUT, "ufbx.lib" if WINDOWS else "libufbx.a")
STAMP = os.path.join(OUT, "tag.txt")


def tag():
    with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
        for line in f:
            key, eq, value = line.strip().partition("=")
            if eq and key == "UFBX_TAG":
                return value
    sys.exit("build_ufbx: no UFBX_TAG in scripts/versions.env")


def main():
    want = tag()
    with open(SHIM, "rb") as f:
        # The shim is ours and changes with the app, so the stamp names its contents too.
        stamp = f"{want} {hashlib.sha256(f.read()).hexdigest()}"
    if os.path.exists(LIBRARY) and os.path.exists(STAMP) and open(STAMP).read().strip() == stamp:
        print(f"ufbx {want}: {LIBRARY} is built")
        return 0
    have = os.path.join(SRC, "tag.txt")
    if not (os.path.exists(have) and open(have).read().strip() == want):
        print(f"== ufbx {want}")
        shutil.rmtree(SRC, ignore_errors=True)
        subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "-b", want, "https://github.com/ufbx/ufbx.git", SRC], check=True)
        with open(have, "w") as f:
            f.write(want + "\n")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    obj = os.path.join(OUT, "fbx_shim.obj" if WINDOWS else "fbx_shim.o")
    if WINDOWS:
        compile_cmd = ["cl", "/nologo", "/c", "/MT", "/O2", "/W0", f"/I{SRC}", f"/Fo{obj}", SHIM]
        archive = ["lib", "/nologo", f"/OUT:{LIBRARY}", obj]
    else:
        compile_cmd = ["clang", "-c", "-O2", "-fPIC", "-w", f"-I{SRC}", "-o", obj, SHIM]
        archive = ["ar", "rcs", LIBRARY, obj]
    subprocess.run(compile_cmd, check=True)
    subprocess.run(archive, check=True)
    os.remove(obj)
    with open(STAMP, "w") as f:
        f.write(stamp + "\n")
    print(f"ufbx {want}: {LIBRARY}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
