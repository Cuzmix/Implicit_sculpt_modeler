#!/usr/bin/env python3
"""One command for a run on a real machine: builds the app, runs a short list of scripted
checks on this computer's own GPU and screen (sculpting at 1M and 10M, orbiting, Remesh
and Quad Remesh, voxels, render mode, an HDRI, an import, the GPU's validation), and
writes what it saw to build/try_it/: report.md (a line a check, its numbers and what
failed), each check's screenshot and log, and try_it.zip holding them all, to drop into
the chat. A container can only run these on a software GPU, so this is how a series that
"awaits a Windows try" gets one in a few minutes.

    python scripts\\try_it.py                 # release build, every check (about 5 minutes)
    python scripts\\try_it.py --debug         # the debug build: slower, and a leak fails a check
    python scripts\\try_it.py --no-build      # the app already built
    python scripts\\try_it.py sculpt_10m      # only the named checks (--list names them)
    python scripts\\try_it.py --gpubench      # also the GPU benchmark's tables (minutes more)

The iPad and Android tablets run no scripts: their list is the device checklist in
.claude/skills/sm-touch-testing/SKILL.md.
"""
import argparse
import os
import platform
import subprocess
import sys
import time
import zipfile

import headless

ROOT = headless.ROOT
WINDOWS = headless.WINDOWS
OUT = os.path.join(ROOT, "build", "try_it")
EXE = os.path.join(ROOT, "build", "sculpt.exe" if WINDOWS else "sculpt")
SKY = os.path.join(ROOT, "src", "hdri", "testdata", "exr", "sky_half_zip.exr")
RIG = os.path.join(ROOT, "src", "app", "testdata", "import", "rig.gltf")
# The exit stats every report line shows, where the run printed them.
SHOWN = ["gpu_backend", "vertices", "dabs", "frame_ms_p50", "frame_ms_p99", "cpu_ms_p50",
         "gpu_frame_ms_p50", "peak_rss_mb"]


def stat_is(key, want):
    return (f"{key} is {want}", lambda s: s.get(key) == want)


def stat_at_least(key, least):
    def ok(s):
        try:
            return float(s.get(key, "nan")) >= least
        except ValueError:
            return False
    return (f"{key} at least {least}", ok)


# Each check: its name, what it shows, the app's flags (a screenshot is added) and what
# its exit stats must say beyond a clean exit.
CHECKS = [
    ("start", "the app opens, draws 120 frames and closes", ["--frames=120"],
     [stat_is("gpu_backend", "metal" if sys.platform == "darwin" else "vulkan")]),
    ("sculpt_1m", "a 120-frame stroke on a 1M sphere", ["--vertices=1000000", "--bench-stroke=120"],
     [stat_at_least("dabs", 1)]),
    ("sculpt_10m", "the same stroke on 10M (40k with four levels)", ["--vertices=40000", "--subdivide=4", "--bench-stroke=120"],
     [stat_at_least("dabs", 1), stat_at_least("vertices", 9_000_000)]),
    ("orbit_5m", "one full turn round a 5M sphere", ["--vertices=5000000", "--orbit", "--frames=240"], []),
    ("remesh", "Remesh of a 200k sphere to 100k, then the mesh checked",
     ["--vertices=200000", "--script=set rebuild_even 100000; rebuild", "--frames=30", "--check-mesh"],
     [stat_is("mesh_closed", "true"), stat_is("mesh_non_manifold_edges", "0")]),
    ("quad_remesh", "Quad Remesh of a 100k sphere, then the mesh checked",
     ["--vertices=100000", "--script=retopologize", "--frames=30", "--check-mesh"], [stat_at_least("objects", 2)]),
    ("voxels", "a stroke on a 256 voxel sphere", ["--voxels=256", "--bench-stroke=60"], [stat_at_least("voxel_objects", 1)]),
    ("render_mode", "render mode for 90 frames", ["--script=shading_mode rendered", "--frames=90"], []),
    ("environment", "an OpenEXR sky as the environment, in Material Preview",
     [f"--script=environment \"{SKY}\"; set environment_background on; shading_mode material_preview", "--frames=30"],
     [stat_is("environment", "image")]),
    ("import", "a glTF with a rig imported, then the meshes checked", [f"--import={RIG}", "--frames=30", "--check-mesh"],
     [stat_at_least("objects", 1)]),
    ("validation", "120 frames under the GPU's validation layer (needs the Vulkan SDK on Windows)",
     ["--gpu-debug", "--frames=120"], []),
]


def parse_stats(text):
    stats = {}
    for line in text.splitlines():
        if line.startswith("["):
            continue
        for word in line.split():
            key, eq, value = word.partition("=")
            if eq:
                stats[key] = value
    return stats


def build(debug):
    mode = "debug" if debug else "release"
    cmd = ["cmd", "/c", os.path.join(ROOT, "build.bat"), mode] if WINDOWS else [os.path.join(ROOT, "build.sh"), mode]
    print(f"building ({mode})...", flush=True)
    done = subprocess.run(cmd, cwd=ROOT)
    return done.returncode == 0


def run_check(name, what, args, checks, debug):
    shot = os.path.join(OUT, f"{name}.png")
    cmd = headless.wrap([EXE, *args, f"--dump-screen={shot}"])
    start = time.monotonic()
    try:
        done = subprocess.run(cmd, cwd=ROOT, env=headless.env(), capture_output=True, text=True, errors="replace", timeout=600)
        out, code = done.stdout + done.stderr, done.returncode
    except subprocess.TimeoutExpired as e:
        parts = [p.decode(errors="replace") if isinstance(p, bytes) else p for p in (e.stdout, e.stderr) if p]
        out, code = "".join(parts), "timeout (10 minutes)"
    seconds = time.monotonic() - start
    with open(os.path.join(OUT, f"{name}.log"), "w", encoding="utf-8") as f:
        f.write(out)
    stats = parse_stats(out)
    failed = []
    if code != 0:
        failed.append(f"exit {code}")
    if debug and "no leaks" not in out:
        failed.append("leaks (see the log)")
    errors = [line for line in out.splitlines() if line.startswith("[ERROR]")]
    if errors:
        failed.append(f"{len(errors)} error lines, the first: {errors[0][:160]}")
    for label, ok in checks:
        if not ok(stats):
            failed.append(f"wanted {label}")
    return {"name": name, "what": what, "seconds": seconds, "failed": failed, "stats": stats,
            "shot": shot if os.path.exists(shot) else None}


def report(results, gpubench):
    lines = [f"# Try it: {platform.system()} {platform.release()}, {platform.machine()}", ""]
    passed = sum(1 for r in results if not r["failed"])
    lines.append(f"{passed} of {len(results)} checks passed.")
    lines.append("")
    lines.append("| Check | Result | Seconds | " + " | ".join(SHOWN) + " |")
    lines.append("|---|---|---|" + "---|" * len(SHOWN))
    for r in results:
        result = "pass" if not r["failed"] else "FAIL: " + "; ".join(r["failed"])
        values = " | ".join(r["stats"].get(k, "") for k in SHOWN)
        lines.append(f"| {r['name']} | {result} | {r['seconds']:.0f} | {values} |")
    lines.append("")
    for r in results:
        lines.append(f"- **{r['name']}**: {r['what']}" + (f" ({os.path.basename(r['shot'])})" if r["shot"] else ""))
    if gpubench:
        lines += ["", "GPU benchmark: gpubench.md", ""]
    text = "\n".join(lines) + "\n"
    with open(os.path.join(OUT, "report.md"), "w", encoding="utf-8") as f:
        f.write(text)
    return text


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("names", nargs="*", help="only these checks")
    ap.add_argument("--debug", action="store_true", help="build and run the debug app (a leak fails a check)")
    ap.add_argument("--no-build", action="store_true", help="run the app already built")
    ap.add_argument("--gpubench", action="store_true", help="also run the GPU benchmark")
    ap.add_argument("--list", action="store_true", help="list the checks and stop")
    a = ap.parse_args()
    if a.list:
        for name, what, _, _ in CHECKS:
            print(f"{name:14} {what}")
        return 0
    unknown = [n for n in a.names if n not in {c[0] for c in CHECKS}]
    if unknown:
        print("no such check: " + ", ".join(unknown) + " (--list names them)")
        return 2
    if headless.mode() == "none":
        print("no way to open a window here (no display, no offscreen SDL, no Xvfb)")
        return 2
    if not a.no_build and not build(a.debug):
        return 1
    if not os.path.exists(EXE):
        print(f"{EXE} is missing: build the app first")
        return 1
    os.makedirs(OUT, exist_ok=True)
    for f in os.listdir(OUT):
        os.remove(os.path.join(OUT, f))
    results = []
    for name, what, args, checks in CHECKS:
        if a.names and name not in a.names:
            continue
        r = run_check(name, what, args, checks, a.debug)
        print(f"{'PASS' if not r['failed'] else 'FAIL'} {name:14} {r['seconds']:5.0f} s  " + "; ".join(r["failed"]), flush=True)
        results.append(r)
    if a.gpubench:
        print("GPU benchmark...", flush=True)
        subprocess.run(headless.wrap([EXE, f"--gpubench={os.path.join(OUT, 'gpubench.md')}"]), cwd=ROOT, env=headless.env())
    text = report(results, a.gpubench)
    archive = os.path.join(ROOT, "build", "try_it.zip")
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(os.listdir(OUT)):
            z.write(os.path.join(OUT, f), f)
    print()
    print(text)
    print(f"Everything is in {archive}: drop it into the chat.")
    return 0 if all(not r["failed"] for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
