#!/usr/bin/env python3
"""What a GPU's compiler makes of the renderer's compute kernels, measured with no GPU (Linux).

    python scripts/kernel_stats.py render_trace.comp render_trace_rq.comp
    python scripts/kernel_stats.py render_trace.comp --set plain=0:0,1:0,2:0,3:0 --set textured=0:8
    python scripts/kernel_stats.py render_trace.comp --family gfx1100

Mesa's RADV driver compiles for an AMD family it is told to pretend to be
(RADV_FORCE_FAMILY), with no card present, and reports what it made through
VK_KHR_pipeline_executable_properties. This script builds scripts/kernel_stats.c against the
system's Vulkan loader into build/kernel_stats, runs it on each named kernel
(src/render/shaders/NAME.spv), once with no specialization constants (the general kernel) and
once per --set, and prints a markdown table: registers a thread (VGPRs), waves a SIMD keeps in
flight, instructions, the driver's estimate of the cycles a wave takes (inverse throughput), and
scratch memory. Fewer registers mean more waves in flight, which hides memory latency, which is
where a path tracer's time goes. The default family is navi22 (RDNA2, an RX 6700 XT, the class
of an RTX 3060 Ti); gfx1100 is RDNA3.

A set is NAME=ID:VALUE,ID:VALUE (render_trace.slang's RT_ constants: 0 the item flags any item
may carry, 1 an image environment, 2 the lens, 3 lights with a place).

It needs a C compiler and, from Ubuntu's packages, mesa-vulkan-drivers and libvulkan-dev, and
says which is missing. The numbers are one AMD compiler's; NVIDIA's and Apple's differ in
detail but follow the same code, so a kernel that loses half its instructions here loses most
of them there too.
"""
import argparse
import os
import pathlib
import platform
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHADERS = ROOT / "src" / "render" / "shaders"
SOURCE = ROOT / "scripts" / "kernel_stats.c"
BINARY = ROOT / "build" / "kernel_stats"
# Debian and Ubuntu name the driver's manifest radeon_icd.json, Fedora by its architecture.
RADV = next((p for p in (pathlib.Path("/usr/share/vulkan/icd.d/radeon_icd.json"),
                         pathlib.Path(f"/usr/share/vulkan/icd.d/radeon_icd.{platform.machine()}.json")) if p.exists()),
            pathlib.Path("/usr/share/vulkan/icd.d/radeon_icd.json"))
COLUMNS = [("VGPRs", "VGPRs"), ("Subgroups per SIMD", "Waves/SIMD"), ("Instructions", "Instructions"),
           ("Inverse Throughput", "Cycles/wave"), ("Scratch size", "Scratch B"), ("Spilled VGPRs", "Spilled")]


def build():
    """Compiles the measuring program when it is missing or older than its source."""
    if BINARY.exists() and BINARY.stat().st_mtime >= SOURCE.stat().st_mtime:
        return
    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if not cc:
        sys.exit("kernel_stats: no C compiler (cc, gcc or clang)")
    if not pathlib.Path("/usr/include/vulkan/vulkan.h").exists():
        sys.exit("kernel_stats: Vulkan headers missing: apt-get install libvulkan-dev")
    BINARY.parent.mkdir(parents=True, exist_ok=True)
    run = subprocess.run([cc, "-O1", "-o", str(BINARY), str(SOURCE), "-lvulkan"], capture_output=True, text=True)
    if run.returncode != 0:
        sys.exit("kernel_stats: the measuring program did not compile:\n" + run.stderr)


def measure(spv, constants, family):
    """The driver's statistics for one kernel with the given constants, as a dict."""
    env = dict(os.environ, VK_ICD_FILENAMES=str(RADV), RADV_FORCE_FAMILY=family,
               MESA_SHADER_CACHE_DISABLE="1", XDG_RUNTIME_DIR=os.environ.get("XDG_RUNTIME_DIR", "/tmp"))
    args = [str(BINARY), str(spv)] + [f"{i}={v}" for i, v in constants]
    run = subprocess.run(args, capture_output=True, text=True, env=env)
    if run.returncode != 0:
        sys.exit(f"kernel_stats: {spv.name}: {(run.stdout + run.stderr).strip()}")
    stats = {}
    for field in run.stdout.split("\t"):
        if "=" in field:
            name, value = field.rsplit("=", 1)
            stats[name.strip()] = value.strip()
    return stats


def parse_set(text):
    name, _, pairs = text.partition("=")
    if not pairs:
        sys.exit(f"kernel_stats: a set is NAME=ID:VALUE,...: {text}")
    constants = []
    for pair in pairs.split(","):
        i, _, v = pair.partition(":")
        constants.append((int(i, 0), int(v, 0)))
    return name, constants


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("kernels", nargs="+", help="kernels by name, as render_trace.comp")
    parser.add_argument("--set", action="append", default=[], help="NAME=ID:VALUE,... constants to measure")
    parser.add_argument("--family", default="navi22", help="the AMD family RADV compiles for (default navi22)")
    args = parser.parse_args(argv)
    if not RADV.exists():
        sys.exit("kernel_stats: Mesa's RADV driver missing: apt-get install mesa-vulkan-drivers")
    build()
    sets = [("general", [])] + [parse_set(s) for s in args.set]
    print(f"| Kernel | Constants | {' | '.join(label for _, label in COLUMNS)} |")
    print("|---|---|" + "---|" * len(COLUMNS))
    for kernel in args.kernels:
        spv = SHADERS / (kernel if kernel.endswith(".spv") else kernel + ".spv")
        if not spv.exists():
            sys.exit(f"kernel_stats: no {spv}")
        for name, constants in sets:
            stats = measure(spv, constants, args.family)
            print(f"| {kernel} | {name} | {' | '.join(stats.get(key, '') for key, _ in COLUMNS)} |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
