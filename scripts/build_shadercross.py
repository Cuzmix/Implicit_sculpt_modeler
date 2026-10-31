#!/usr/bin/env python3
"""Builds SDL_shadercross's command-line tool into deps/shadercross, for shader authors.

    python scripts/build_shadercross.py     # setup_deps.sh runs it; needs cmake, git and a C/C++ compiler

The iPad build draws through SDL_GPU's Metal backend, which takes Metal source (MSL), not
SPIR-V, so every committed name.stage.spv has a name.stage.msl beside it, made by
scripts/shaders_msl.py with this tool. SDL_shadercross is SDL's own translator: Metal has no
descriptor sets, and it maps each of SDL's SPIR-V sets and bindings to the Metal slot
SDL_GPU binds, which plain spirv-cross does not.

Three CMake builds go into one private prefix (deps/shadercross/prefix), all from pinned
sources: SPIRV-Cross at SPIRV_CROSS_COMMIT (the commit SDL_shadercross's own submodule
names), SDL3 from deps/sdl3-src at SDL_TAG, both static, and then SDL_shadercross at
SHADERCROSS_COMMIT with its HLSL compiler off and its tool linked statically, so the one
executable runs alone. Its vendored mode is not used: that one wants the DirectX shader
compiler's whole source even with HLSL off. A tool built from the same commits is kept, so
a second run does nothing.
"""

import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.join(ROOT, "deps")
SRC = os.path.join(DEPS, "shadercross-src")
SDL_SRC = os.path.join(DEPS, "sdl3-src")
OUT = os.path.join(DEPS, "shadercross")
PREFIX = os.path.join(OUT, "prefix")
WINDOWS = os.name == "nt"
TOOL = os.path.join(OUT, "shadercross.exe" if WINDOWS else "shadercross")
STAMP = os.path.join(OUT, "commit.txt")


def pins():
    out = {}
    with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
        for line in f:
            key, eq, value = line.strip().partition("=")
            if eq and not key.startswith("#"):
                out[key] = value
    for key in ("SHADERCROSS_COMMIT", "SPIRV_CROSS_COMMIT", "SDL_TAG"):
        if key not in out:
            sys.exit(f"build_shadercross: no {key} in scripts/versions.env")
    return out


def git(*args, cwd=None):
    subprocess.run(["git", "-c", "advice.detachedHead=false", *args], cwd=cwd, check=True)


def fetch(url, commit, folder):
    """Checks out exactly `commit` of `url` into `folder`, without its history."""
    shutil.rmtree(folder, ignore_errors=True)
    os.makedirs(folder)
    git("init", "-q", cwd=folder)
    git("fetch", "-q", "--depth", "1", url, commit, cwd=folder)
    git("checkout", "-q", "FETCH_HEAD", cwd=folder)


def cmake_build(source, build, options):
    """Configures, builds and installs one project into PREFIX, release and static."""
    generator = ["-G", "Ninja"] if shutil.which("ninja") else []
    flags = [
        f"-DCMAKE_INSTALL_PREFIX={PREFIX}",
        f"-DCMAKE_PREFIX_PATH={PREFIX}",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        # Visual Studio's static runtime, so the tool needs no runtime DLL; GCC ignores it.
        "-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded",
    ]
    if WINDOWS and not shutil.which("cl") and shutil.which("gcc"):
        # MinGW's GCC links its own runtime as DLLs unless told otherwise.
        flags.append("-DCMAKE_EXE_LINKER_FLAGS=-static")
    subprocess.run(["cmake", "-S", source, "-B", build, *generator, *flags, *options], check=True)
    subprocess.run(["cmake", "--build", build, "--config", "Release", "--parallel"], check=True)


def main():
    p = pins()
    want = f"{p['SHADERCROSS_COMMIT']} {p['SPIRV_CROSS_COMMIT']} {p['SDL_TAG']}"
    if os.path.exists(TOOL) and os.path.exists(STAMP) and open(STAMP).read().strip() == want:
        print(f"SDL_shadercross: {TOOL} is built")
        return 0
    for needed in ("cmake", "git"):
        if not shutil.which(needed):
            sys.exit(f"build_shadercross: {needed} is not on PATH")
    print(f"== SDL_shadercross {p['SHADERCROSS_COMMIT'][:12]}")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT)
    if not os.path.exists(os.path.join(SDL_SRC, "CMakeLists.txt")):
        # The same checkout setup_deps.sh and setup_android.bat make.
        git("clone", "-q", "--depth", "1", "-b", p["SDL_TAG"], "https://github.com/libsdl-org/SDL.git", SDL_SRC)
    fetch("https://github.com/libsdl-org/SDL_shadercross.git", p["SHADERCROSS_COMMIT"], SRC)
    spirv_cross = os.path.join(SRC, "external", "SPIRV-Cross")
    fetch("https://github.com/KhronosGroup/SPIRV-Cross.git", p["SPIRV_CROSS_COMMIT"], spirv_cross)
    builds = os.path.join(OUT, "build")

    cmake_build(spirv_cross, os.path.join(builds, "spirv-cross"), [
        "-DSPIRV_CROSS_SHARED=OFF", "-DSPIRV_CROSS_STATIC=ON", "-DSPIRV_CROSS_CLI=OFF",
        "-DSPIRV_CROSS_ENABLE_TESTS=OFF",
    ])
    subprocess.run(["cmake", "--install", os.path.join(builds, "spirv-cross"), "--config", "Release"], check=True)
    # The tool opens no window, so a Linux machine without the X11 and Wayland development
    # packages (a cloud container) builds SDL with the offscreen video driver only, as
    # setup_deps.sh does for the app's own SDL.
    headless = sys.platform.startswith("linux") and not os.path.exists("/usr/include/X11/Xcursor/Xcursor.h") \
        and not os.path.exists("/usr/include/wayland-client.h")
    cmake_build(SDL_SRC, os.path.join(builds, "sdl3"), [
        "-DSDL_SHARED=OFF", "-DSDL_STATIC=ON", "-DSDL_TEST_LIBRARY=OFF", "-DSDL_TESTS=OFF",
        "-DSDL_EXAMPLES=OFF",
    ] + (["-DSDL_X11=OFF", "-DSDL_WAYLAND=OFF", "-DSDL_OFFSCREEN=ON", "-DSDL_UNIX_CONSOLE_BUILD=ON"] if headless else []))
    subprocess.run(["cmake", "--install", os.path.join(builds, "sdl3"), "--config", "Release"], check=True)
    cmake_build(SRC, os.path.join(builds, "shadercross"), [
        "-DSDLSHADERCROSS_VENDORED=OFF", "-DSDLSHADERCROSS_DXC=OFF",
        "-DSDLSHADERCROSS_SPIRVCROSS_SHARED=OFF", "-DSDLSHADERCROSS_SHARED=OFF",
        "-DSDLSHADERCROSS_STATIC=ON", "-DSDLSHADERCROSS_CLI=ON", "-DSDLSHADERCROSS_CLI_STATIC=ON",
        "-DSDLSHADERCROSS_INSTALL=OFF", "-DSDLSHADERCROSS_TESTS=OFF",
    ])
    name = os.path.basename(TOOL)
    found = glob.glob(os.path.join(builds, "shadercross", "**", name), recursive=True)
    if not found:
        sys.exit(f"build_shadercross: the build made no {name}")
    shutil.copy2(found[0], TOOL)
    shutil.rmtree(builds)
    with open(STAMP, "w") as f:
        f.write(want + "\n")
    print(f"SDL_shadercross: {TOOL}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
