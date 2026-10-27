#!/usr/bin/env python3
"""Builds Luau, the language of script plugins (README "Script plugins"), into deps/luau.

    python scripts/build_luau.py        # setup_deps runs it; on Windows, cl must be on PATH

It clones luau-lang/luau at LUAU_TAG (scripts/versions.env) into deps/luau-src and compiles
its compiler and VM (Common, Ast, Bytecode, Compiler and VM) into one static library:
deps/luau/libluau.a with clang++ on Linux, deps/luau/luau.lib with cl on Windows. The
build is Luau's own LUAU_EXTERN_C one: a Luau error is a longjmp, never a C++ exception
through Odin's frames, and the API has C names. A library built from the same tag is
kept, so a second run does nothing.
"""

import concurrent.futures
import glob
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.join(ROOT, "deps")
SRC = os.path.join(DEPS, "luau-src")
OUT = os.path.join(DEPS, "luau")
WINDOWS = os.name == "nt"
LIBRARY = os.path.join(OUT, "luau.lib" if WINDOWS else "libluau.a")
STAMP = os.path.join(OUT, "tag.txt")
# The parts the app needs: no analysis, code generation, Require or command-line tools.
PARTS = ["Common", "Ast", "Bytecode", "Compiler", "VM"]
DEFINES = ["LUA_USE_LONGJMP=1", 'LUA_API=extern "C"', 'LUACODE_API=extern "C"']


def tag():
    with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
        for line in f:
            key, eq, value = line.strip().partition("=")
            if eq and key == "LUAU_TAG":
                return value
    sys.exit("build_luau: no LUAU_TAG in scripts/versions.env")


def compile_command(source, obj):
    includes = [os.path.join(SRC, part, "include") for part in PARTS] + [os.path.join(SRC, "VM", "src")]
    if WINDOWS:
        return (["cl", "/nologo", "/c", "/MT", "/EHsc", "/O2", "/std:c++17", "/W0", f"/Fo{obj}"]
                + [f"/D{d}" for d in DEFINES] + [f"/I{i}" for i in includes] + [source])
    return (["clang++", "-c", "-O2", "-std=c++17", "-fPIC", "-w", "-o", obj]
            + [f"-D{d}" for d in DEFINES] + [f"-I{i}" for i in includes] + [source])


def main():
    want = tag()
    if os.path.exists(LIBRARY) and os.path.exists(STAMP) and open(STAMP).read().strip() == want:
        print(f"Luau {want}: {LIBRARY} is built")
        return 0
    print(f"== Luau {want}")
    shutil.rmtree(SRC, ignore_errors=True)
    subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "-q", "--depth", "1", "-b", want, "https://github.com/luau-lang/luau.git", SRC], check=True)
    objects_dir = os.path.join(OUT, "obj")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(objects_dir)
    sources = sorted(s for part in PARTS for s in glob.glob(os.path.join(SRC, part, "src", "*.cpp")))
    # Two parts may name a file alike, so each object takes its part's name too.
    jobs = [(s, os.path.join(objects_dir, f"{os.path.basename(os.path.dirname(os.path.dirname(s)))}_{os.path.splitext(os.path.basename(s))[0]}{'.obj' if WINDOWS else '.o'}")) for s in sources]

    def build(job):
        run = subprocess.run(compile_command(*job), capture_output=True, text=True)
        return job[0], run.returncode, run.stdout + run.stderr

    failed = False
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for source, code, output in pool.map(build, jobs):
            if code != 0:
                failed = True
                print(f"build_luau: {os.path.relpath(source, SRC)} failed:\n{output}", file=sys.stderr)
    if failed:
        return 1
    objects = [obj for _, obj in jobs]
    archive = ["lib", "/nologo", f"/OUT:{LIBRARY}"] + objects if WINDOWS else ["ar", "rcs", LIBRARY] + objects
    subprocess.run(archive, check=True)
    shutil.rmtree(objects_dir)
    with open(STAMP, "w") as f:
        f.write(want + "\n")
    print(f"Luau {want}: {len(sources)} files into {LIBRARY}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
