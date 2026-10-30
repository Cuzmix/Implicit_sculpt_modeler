#!/usr/bin/env python3
"""Builds AutoRemesher's core, the Quad Remesh engine (README "Quad Remesh engine"), into deps/autoremesher.

    python scripts/build_autoremesher.py        # setup_deps runs it; on Windows, cl must be on PATH

It fetches huxingyi/autoremesher at AUTOREMESHER_COMMIT (scripts/versions.env) into
deps/autoremesher-src and compiles the core (src/AutoRemesher), its bundled isotropicremesher
and the two meshoptimizer files it calls, and the app's own boundary src/quadmesh/quadmesh_shim.cpp,
into one static library: deps/autoremesher/libautoremesher.a with clang++ on Linux and macOS,
deps/autoremesher/autoremesher.lib with cl /MT on Windows. Eigen is the bundled headers under
EIGEN_MPL2_ONLY; TBB is replaced by src/quadmesh/shim/tbb. Qt, which only the GUI and CLI use,
is not needed. A library built from the same commit and shim is kept, so a second run does
nothing. Eigen's templates make the first build take a few minutes.
"""

import concurrent.futures
import glob
import hashlib
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEPS = os.path.join(ROOT, "deps")
SRC = os.path.join(DEPS, "autoremesher-src")
OUT = os.path.join(DEPS, "autoremesher")
SHIM = os.path.join(ROOT, "src", "quadmesh")
WINDOWS = os.name == "nt"
LIBRARY = os.path.join(OUT, "autoremesher.lib" if WINDOWS else "libautoremesher.a")
STAMP = os.path.join(OUT, "commit.txt")
# The core, the isotropic remesher it runs first, and the meshoptimizer calls it makes
# (meshopt_simplifyWithAttributes and the vertex remap), relative to the source tree.
SOURCES = (
    ["src/AutoRemesher/*.cpp"]
    + ["thirdparty/isotropicremesher/*.cpp"]
    + ["thirdparty/meshoptimizer/src/simplifier.cpp", "thirdparty/meshoptimizer/src/indexgenerator.cpp"]
)
INCLUDES = ["include", "src", "thirdparty/eigen", "thirdparty/isotropicremesher", "thirdparty/meshoptimizer/src"]
# EIGEN_MPL2_ONLY refuses Eigen's LGPL parts at compile time (the core uses none);
# EIGEN_DONT_PARALLELIZE keeps Eigen off OpenMP, since the shim's threads are the only ones.
DEFINES = ["EIGEN_MPL2_ONLY", "EIGEN_DONT_PARALLELIZE"]


def pin():
    with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
        for line in f:
            key, eq, value = line.strip().partition("=")
            if eq and key == "AUTOREMESHER_COMMIT":
                return value
    sys.exit("build_autoremesher: no AUTOREMESHER_COMMIT in scripts/versions.env")


def shim_hash():
    h = hashlib.sha256()
    for path in sorted(glob.glob(os.path.join(SHIM, "quadmesh_shim.*")) + glob.glob(os.path.join(SHIM, "shim", "tbb", "*.h"))):
        with open(path, "rb") as f:
            h.update(os.path.basename(path).encode() + b"\0" + f.read() + b"\0")
    return h.hexdigest()


def fetch(commit):
    have = os.path.join(SRC, "commit.txt")
    if os.path.exists(have) and open(have).read().strip() == commit:
        return
    print(f"== AutoRemesher {commit[:12]}")
    shutil.rmtree(SRC, ignore_errors=True)
    os.makedirs(SRC)
    # A commit cannot be cloned shallowly by name, so fetch just it into a fresh repository.
    git = ["git", "-C", SRC, "-c", "advice.detachedHead=false"]
    subprocess.run(git + ["init", "-q"], check=True)
    subprocess.run(git + ["remote", "add", "origin", "https://github.com/huxingyi/autoremesher.git"], check=True)
    subprocess.run(git + ["fetch", "-q", "--depth", "1", "origin", commit], check=True)
    subprocess.run(git + ["checkout", "-q", "FETCH_HEAD"], check=True)
    with open(have, "w") as f:
        f.write(commit + "\n")


def compile_command(source, obj):
    includes = [os.path.join(SRC, i) for i in INCLUDES] + [os.path.join(SHIM, "shim")]
    if WINDOWS:
        # /FIcstdint: meshseparator.cpp uses uint64_t without including <cstdint>.
        # _USE_MATH_DEFINES: the core uses M_PI, which MSVC's <cmath> only declares when asked.
        return (["cl", "/nologo", "/c", "/MT", "/EHsc", "/O2", "/std:c++17", "/W0", "/FIcstdint", "/D_USE_MATH_DEFINES", f"/Fo{obj}"]
                + [f"/D{d}" for d in DEFINES] + [f"/I{i}" for i in includes] + [source])
    return (["clang++", "-c", "-O2", "-std=c++17", "-fPIC", "-w", "-include", "cstdint", "-o", obj]
            + [f"-D{d}" for d in DEFINES] + [f"-I{i}" for i in includes] + [source])


def main():
    commit = pin()
    stamp = f"{commit} {shim_hash()}"
    if os.path.exists(LIBRARY) and os.path.exists(STAMP) and open(STAMP).read().strip() == stamp:
        print(f"AutoRemesher {commit[:12]}: {LIBRARY} is built")
        return 0
    fetch(commit)
    sources = sorted(s for pattern in SOURCES for s in glob.glob(os.path.join(SRC, pattern)))
    sources.append(os.path.join(SHIM, "quadmesh_shim.cpp"))
    objects_dir = os.path.join(OUT, "obj")
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(objects_dir)
    ext = ".obj" if WINDOWS else ".o"
    # Two files are named isotropicremesher.cpp, so each object takes its folder's name too.
    jobs = [(s, os.path.join(objects_dir, f"{os.path.basename(os.path.dirname(s))}_{os.path.splitext(os.path.basename(s))[0]}{ext}")) for s in sources]

    def build(job):
        run = subprocess.run(compile_command(*job), capture_output=True, text=True)
        return job[0], run.returncode, run.stdout + run.stderr

    failed = False
    with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count() or 4) as pool:
        for source, code, output in pool.map(build, jobs):
            if code != 0:
                failed = True
                print(f"build_autoremesher: {os.path.relpath(source, ROOT)} failed:\n{output}", file=sys.stderr)
    if failed:
        return 1
    objects = [obj for _, obj in jobs]
    archive = ["lib", "/nologo", f"/OUT:{LIBRARY}"] + objects if WINDOWS else ["ar", "rcs", LIBRARY] + objects
    subprocess.run(archive, check=True)
    shutil.rmtree(objects_dir)
    with open(STAMP, "w") as f:
        f.write(stamp + "\n")
    print(f"AutoRemesher {commit[:12]}: {len(sources)} files into {LIBRARY}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
