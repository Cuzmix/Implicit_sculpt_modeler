#!/usr/bin/env python3
"""UV flattening against Blender's: the same fixtures unwrapped by both and measured by
the same stretch code.

    python scripts/export_check.py --setup      # once: bpy, into build/export-tools
    python scripts/uv_check.py [triangles...]   # needs build/bench (build.bat bench / ./build.sh bench)

1. `bench --uv --write=build/uv_check` flattens its fixtures (a cut tube, a dome, the dome
   cut into tiles) at each size, 100,000 triangles by default, and writes each with our
   ABF++ UVs as OBJ, so its islands are in the file.
2. bpy imports each OBJ, marks seams from those islands, unwraps with Angle Based and
   with Conformal (margin 0, as Blender's Unwrap with Fill Holes off) and exports it again
   with Blender's UVs.
3. `bench --measure=FILE.obj` measures each export's UVs and ours on the same islands, and
   the rows are printed together: Blender's as "file", ours as Abf and Lscm.

A missing bpy prints SKIP and only our table (with --require, exit 1). Like export_check
it is a development aid outside the gate. SCULPT_BPY_PYTHON points at another Python
with bpy.
"""

import argparse
import glob
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
VENV_PYTHON = os.path.join(ROOT, "build", "export-tools", "venv", "Scripts" if WINDOWS else "bin", "python.exe" if WINDOWS else "python")
BENCH = os.path.join(ROOT, "build", "bench.exe" if WINDOWS else "bench")
WORK = os.path.join(ROOT, "build", "uv_check")

# Run by the Python that has bpy: sys.argv[-3:] are the OBJ in, the method and the OBJ out.
BLENDER_PY = r"""
import bpy, sys
path, method, out = sys.argv[-3:]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=path)
obj = bpy.context.selected_objects[0]
bpy.context.view_layer.objects.active = obj
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.uv.select_all(action="SELECT")
bpy.ops.uv.seams_from_islands()
bpy.ops.uv.unwrap(method=method, fill_holes=False, correct_aspect=True, margin=0.0)
bpy.ops.object.mode_set(mode="OBJECT")
bpy.ops.wm.obj_export(filepath=out, export_selected_objects=True, export_uv=True, export_normals=False,
                      export_materials=False, export_triangulated_mesh=True)
print("uv_check: done")
"""


def bpy_python():
    python = os.environ.get("SCULPT_BPY_PYTHON") or (VENV_PYTHON if os.path.exists(VENV_PYTHON) else sys.executable)
    probe = subprocess.run([python, "-c", "import bpy"], capture_output=True)
    return python if probe.returncode == 0 else None


def rows(text):
    return [line for line in text.splitlines() if line.startswith("| ") and not line.startswith("| Fixture") and not line.startswith("| ---")]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("sizes", nargs="*", type=int, default=[100_000])
    parser.add_argument("--require", action="store_true", help="fail when bpy is missing")
    args = parser.parse_args()
    if not os.path.exists(BENCH):
        print(f"uv_check: {BENCH} is missing; build it first (build.bat bench / ./build.sh bench)")
        return 1
    os.makedirs(WORK, exist_ok=True)
    for old in glob.glob(os.path.join(WORK, "*.obj")):
        os.remove(old)
    ours = subprocess.run([BENCH, "--uv", f"--write={WORK}"] + [str(s) for s in args.sizes], capture_output=True, text=True)
    if ours.returncode != 0:
        print(ours.stdout + ours.stderr)
        return 1
    header = [line for line in ours.stdout.splitlines() if line.startswith("| Fixture") or line.startswith("| ---")]
    print("\n".join(header + rows(ours.stdout)))
    python = bpy_python()
    if python is None:
        print("SKIP: no Python with bpy (python scripts/export_check.py --setup, or SCULPT_BPY_PYTHON)")
        return 1 if args.require else 0
    print()
    print("Blender's unwrap (file) against ours on the same islands:")
    print("\n".join(header))
    failed = False
    for path in sorted(glob.glob(os.path.join(WORK, "*.obj"))):
        if "_blender_" in path:
            continue
        for method in ("ANGLE_BASED", "CONFORMAL"):
            out = path[:-4] + f"_blender_{method.lower()}.obj"
            run = subprocess.run([python, "-c", BLENDER_PY, path, method, out], capture_output=True, text=True)
            if run.returncode != 0 or not os.path.exists(out):
                print(f"FAIL: Blender's {method} unwrap of {os.path.basename(path)}: {run.stderr.strip()[-400:]}")
                failed = True
                continue
            measured = subprocess.run([BENCH, f"--measure={out}"], capture_output=True, text=True)
            if measured.returncode != 0 or not rows(measured.stdout):
                print(f"FAIL: measuring {os.path.basename(out)}: {measured.stdout}{measured.stderr}")
                failed = True
                continue
            print("\n".join(rows(measured.stdout)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
