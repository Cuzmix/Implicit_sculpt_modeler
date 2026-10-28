#!/usr/bin/env python3
"""Draws a fixed set of scenes and compares them with a baseline, pixel for pixel.

A change that must not move a pixel (a shader compiler, a GPU backend) is checked by
drawing every pass the app has in both versions:

    python scripts/parity_check.py --out build/parity/base            # with the old build
    python scripts/parity_check.py --out build/parity/new --compare build/parity/base
    python scripts/parity_check.py --out build/parity/vk --compare build/parity/base -- --gpu=vulkan

Each case writes the viewport (--dump-viewport) and the whole window (--dump-screen) as
PPM; --compare runs scripts/ppm.py diff on each pair and fails on any differing pixel.
Needs a display (Xvfb on Linux) and a built app (build/sculpt or build\\sculpt.exe).
"""
import argparse
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Name, start-up script, frames, and an exit stat the run must print (that the pass ran).
# Every case starts from the same sphere with no remembered settings; the accumulating
# passes (studio, render mode) run until their sample count is reached, after which the
# image is the same every run however fast the frames went.
CASES = [
    ("default", "", 20, ""),
    ("msaa_off", "set msaa off", 20, ""),
    ("wire_flat", "set wireframe on\nset flat on", 20, ""),
    ("floor_gradient", "set floor_grid on\nset background_gradient on", 20, ""),
    ("styled", "set styled on\nset rim 0.5\nset underside 0.4\nset cavity 1\nset ridge 1\nset exposure 0.5", 20, ""),
    ("groups_ortho", "set show_groups on\nset ortho on", 20, ""),
    ("pbr_gold", "set material Gold", 20, ""),
    ("pbr_clay", "set material PBR clay", 20, ""),
    ("matcap", "set material Clay MatCap", 20, ""),
    ("pass_normals", "view_pass normals", 20, ""),
    ("pass_depth", "view_pass depth", 20, ""),
    ("pass_curvature", "view_pass curvature", 20, ""),
    ("live_ao", "set live_ao on", 20, ""),
    ("live_ao_msaa_off", "set msaa off\nset live_ao on", 20, ""),
    ("studio", "set studio_ao 1\nset studio_shadow 1\nstudio_render on", 420, "studio=1"),
    ("render_full", "set render_samples 4\nset render_half off\nrender_mode on", 900, "render_samples=4 "),
    ("render_half", "set render_samples 4\nset render_half on\nrender_mode on", 600, "render_samples=4 "),
    ("render_dof", "set render_samples 4\nset render_half on\nset render_dof on\nrender_mode on", 600, "render_samples=4 "),
    ("thumbnail", "set thumbnail on", 30, ""),
]


def app_path(given) -> pathlib.Path:
    exe = pathlib.Path(given) if given else ROOT / "build" / ("sculpt.exe" if os.name == "nt" else "sculpt")
    if not exe.exists():
        sys.exit(f"parity: {exe} is missing: build the app first")
    return exe


def run_case(exe, out, name, script, frames, want, extra) -> bool:
    view = out / f"{name}.viewport.ppm"
    screen = out / f"{name}.screen.ppm"
    # Three spheres side by side, so occlusion and shadows have something to fall on; the
    # interface's clock moves by frames, so its animations land the same every run.
    args = [str(exe), "--vertices=100000", "--spheres=3", f"--frames={frames}", "--no-settings", "--no-vsync", "--ui-dt=0.016",
            f"--dump-viewport={view}", f"--dump-screen={screen}"]
    if script:
        args.append(f"--script={script}")
    args += extra
    r = subprocess.run(args, capture_output=True, text=True)
    text = r.stdout + r.stderr
    (out / f"{name}.log").write_text(text)
    # A run under --gpu=vulkan --gpu-debug logs every validation message; any fails the case.
    if "Vulkan validation:" in text:
        print(f"FAIL {name}: Vulkan validation messages (see {name}.log)")
        return False
    if r.returncode != 0 or not view.exists() or not screen.exists() or (script and "script_failed=0" not in text) or want not in text:
        tail = text.strip().splitlines()[-5:]
        print(f"FAIL {name}: exit {r.returncode}" + (f", no {want.strip()!r} in the stats" if want not in text else ""))
        for line in tail:
            print("    " + line)
        return False
    return True


def diff(a, b) -> tuple[bool, str]:
    r = subprocess.run([sys.executable, str(ROOT / "scripts" / "ppm.py"), "diff", str(a), str(b)],
                       capture_output=True, text=True)
    text = (r.stdout + r.stderr).strip()
    return r.returncode == 0 and "within 0" in text, text


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--out", required=True, help="folder for this run's images")
    p.add_argument("--compare", help="baseline folder to compare with")
    p.add_argument("--only", help="comma-separated case names")
    p.add_argument("--app", help="the app to run (default build/sculpt)")
    p.add_argument("extra", nargs="*", help="app arguments after --")
    a = p.parse_args()
    out = pathlib.Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    exe = app_path(a.app)
    only = set(a.only.split(",")) if a.only else None
    failed = 0
    for name, script, frames, want in CASES:
        if only and name not in only:
            continue
        if not run_case(exe, out, name, script, frames, want, a.extra):
            failed += 1
            continue
        if not a.compare:
            print(f"ok   {name}")
            continue
        for kind in ("viewport", "screen"):
            same, text = diff(out / f"{name}.{kind}.ppm", pathlib.Path(a.compare) / f"{name}.{kind}.ppm")
            print(f"{'ok  ' if same else 'DIFF'} {name} {kind}: {text}")
            if not same:
                failed += 1
    print(f"parity: {failed} failing" if failed else "parity: all cases match")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
