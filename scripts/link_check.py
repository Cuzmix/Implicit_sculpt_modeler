#!/usr/bin/env python3
"""The Blender link's round trip with Blender itself: the app, the add-on in
tools/blender/sculpt_link driven by bpy, and the app again.

    python scripts/export_check.py --setup      # once: bpy, into build/export-tools
    python scripts/link_check.py                # needs build/sculpt (build.bat / ./build.sh)
    python scripts/link_check.py --package      # build/sculpt_link.zip, to install in Blender

1. The app starts with two spheres, moves and turns the first, sends it (`send_to_blender`) and saves the
   scene, which keeps the link's token. The scene's third light is made a point light and
   switched on first, so the send lists three lights.
2. In Blender the add-on's Get from Sculpt brings it in: the counts and the placement (Y up
   turned to Z up) are checked, and the lights: two suns at the watts a glTF export gives
   them and a point light. Its first vertex is raised, the object moved one unit
   along Blender's X, and a cube of quads made beside it; Send to Sculpt sends both. A
   second Get from Sculpt must update the same object rather than make another. Then the
   add-on is enabled as a person enables it, and its two buttons run.
3. The app opens the scene and runs `get_from_blender`: one object's vertices moved, one
   object added. The scene is saved and opened again, and the sphere's mesh and place are
   checked: the raised vertex exactly where Blender put it, every other vertex untouched,
   and the move along Blender's X a move along the app's X.

Each check prints PASS or FAIL; a missing bpy prints SKIP and exits 0 (with --require,
1). Like export_check, it is a development aid outside the gate: nothing of Blender ships
with the app. SCULPT_BPY_PYTHON points at another Python with bpy.
"""

import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WINDOWS = os.name == "nt"
VENV_PYTHON = os.path.join(ROOT, "build", "export-tools", "venv", "Scripts" if WINDOWS else "bin", "python.exe" if WINDOWS else "python")
APP = os.path.join(ROOT, "build", "sculpt.exe" if WINDOWS else "sculpt")
WORK = os.path.join(ROOT, "build", "link_check")
ADDON = os.path.join(ROOT, "tools", "blender")
# The fill light's Intensity in a fresh install (render.FILL_STRENGTH).
FILL_STRENGTH = 0.3

# Run by the Python that has bpy, with the add-on importable; prints one JSON line.
BLENDER_PY = r"""
import bpy, json, sys
import numpy as np
from sculpt_link import get_from_sculpt, send_to_sculpt
folder = sys.argv[-1]
bpy.ops.wm.read_factory_settings(use_empty=True)
got = get_from_sculpt(folder)
if isinstance(got, str):
    print(json.dumps({"error": got}))
    sys.exit(0)
sphere = got[0]
out = {"objects": len(got), "vertices": len(sphere.data.vertices), "triangles": len(sphere.data.polygons),
       "matrix": [list(r) for r in sphere.matrix_world], "name": sphere.name}
# The app's lights that are on, in their collection, as Blender's glTF importer gives them.
shown = bpy.data.collections.get("Sculpt lights")
out["lights"] = [[o.name, o.data.type, round(o.data.energy, 4), list(o.matrix_world.to_3x3() @ __import__("mathutils").Vector((0, 0, -1)))]
                 for o in sorted(shown.objects, key=lambda o: o.name)] if shown else []
v = sphere.data.vertices[0]
v.co.z += 0.25
out["raised"] = list(v.co)
sphere.location.x += 1
bpy.context.view_layer.update()
mesh = bpy.data.meshes.new("Cube")
mesh.from_pydata([(x, y, z) for x in (-0.5, 0.5) for y in (-0.5, 0.5) for z in (-0.5, 0.5)], [],
                 [(0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3)])
cube = bpy.data.objects.new("Cube", mesh)
bpy.context.scene.collection.objects.link(cube)
cube.location = (4, 0, 0)
# Mirrored, which the app's objects cannot be: it goes into the positions, facing out.
cube.scale = (-1, 1, 1)
# A copy keeps the custom properties: it goes as a new object, not as the sphere again.
copy = sphere.copy()
copy.data = sphere.data.copy()
bpy.context.scene.collection.objects.link(copy)
copy.location.y += 3
bpy.context.view_layer.update()
out["sent"] = send_to_sculpt(folder, [sphere, cube, copy])
# A second get updates the same object, not a new one.
again = get_from_sculpt(folder)
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
out["again_same"] = not isinstance(again, str) and again[0] == sphere and len(meshes) == 3 and len(shown.objects) == len(out["lights"])
# As a person runs it: the add-on enabled, its panel's buttons, on a copy of the folder
# so the send above stays for the app.
import addon_utils, shutil
bpy.ops.wm.read_factory_settings(use_empty=True)
addon_utils.enable("sculpt_link", default_set=True)
shutil.copytree(folder, folder + "-buttons")
bpy.context.preferences.addons["sculpt_link"].preferences.folder = folder + "-buttons"
out["operators"] = [list(bpy.ops.sculpt_link.get())]
for o in bpy.data.objects:
    o.select_set(True)
out["operators"].append(list(bpy.ops.sculpt_link.send()))
addon_utils.disable("sculpt_link")
print(json.dumps(out))
"""


def report(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'} {name}{': ' + detail if detail else ''}")
    return ok


def app(*args):
    """Runs the app with these arguments and returns its exit stats as a dict."""
    run = subprocess.run([APP, *args], cwd=ROOT, capture_output=True, text=True, timeout=600)
    stats = {}
    for line in run.stdout.splitlines():
        for word in line.split():
            key, eq, value = word.partition("=")
            if eq:
                stats[key] = value
    # --check-mesh writes a line an object: how many of them face inward.
    stats["inverted_objects"] = str(sum(1 for line in run.stdout.splitlines() if "mesh_inverted=true" in line))
    stats["checked_objects"] = str(sum(1 for line in run.stdout.splitlines() if "mesh_inverted=" in line))
    if run.returncode != 0:
        sys.exit(f"FAIL app {' '.join(args)}: exit code {run.returncode}\n{run.stderr[-2000:]}")
    return stats


def package():
    """Writes the add-on as a Blender extension: its files at the archive's root, as
    Edit > Preferences > Get Extensions > Install from Disk wants them."""
    import zipfile
    source = os.path.join(ADDON, "sculpt_link")
    target = os.path.join(ROOT, "build", "sculpt_link.zip")
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(source)):
            if name.endswith((".py", ".toml")):
                z.write(os.path.join(source, name), name)
    print(f"ok package: {target}")
    return 0


def ply_positions(path):
    data = open(path, "rb").read()
    end = data.index(b"end_header\n") + len(b"end_header\n")
    head = data[:end].decode()
    n = int(head.split("element vertex ")[1].split()[0])
    stride = 15 if "property uchar red" in head else 12
    return [struct.unpack_from("<3f", data, end + stride * v) for v in range(n)]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--require", action="store_true", help="a missing bpy fails rather than skips")
    parser.add_argument("--package", action="store_true", help="only write build/sculpt_link.zip, the add-on as Blender installs it")
    args = parser.parse_args()
    if args.package:
        return package()
    python = os.environ.get("SCULPT_BPY_PYTHON") or VENV_PYTHON
    if not os.path.exists(python):
        print(f"SKIP blender: no Python with bpy at {python} (python scripts/export_check.py --setup)")
        return 1 if args.require else 0
    if not os.path.exists(APP):
        sys.exit(f"FAIL: no app at {APP}: build it first")
    shutil.rmtree(WORK, ignore_errors=True)
    os.makedirs(WORK)
    settings = os.path.join(WORK, "run.txt")
    folder = os.path.join(WORK, "run-link")
    scene, got = os.path.join(WORK, "scene.sculpt"), os.path.join(WORK, "got.sculpt")
    before, after = os.path.join(WORK, "before.ply"), os.path.join(WORK, "after.ply")
    ok = True

    s = app(f"--settings-file={settings}", "--spheres=2", "--subdiv=3", "--frames=2", "--script=select 1; move 1 2 3; rotate 10 20 30; set light3_kind point; set light3_on on; wait 1; send_to_blender", f"--save={scene}", f"--export={before}")
    ok &= report("send", s.get("link_sent") == "1" and s.get("link_token") == "1", f"link_sent={s.get('link_sent')} link_token={s.get('link_token')}")
    placed = [float(x) for x in s.get("transform", "0,0,0,0,0,0,1").split(",")]

    env = dict(os.environ, PYTHONPATH=ADDON + os.pathsep + os.environ.get("PYTHONPATH", ""))
    run = subprocess.run([python, "-c", BLENDER_PY, folder], capture_output=True, text=True, env=env, timeout=600)
    line = next((l for l in reversed(run.stdout.splitlines()) if l.startswith("{")), None)
    if line is None:
        return report("blender", False, (run.stderr or run.stdout)[-2000:]) and 0 or 1
    b = json.loads(line)
    if "error" in b:
        return report("blender get", False, b["error"]) and 0 or 1
    ok &= report("blender get", b["objects"] == 1 and b["vertices"] == 642 and b["triangles"] == 1280,
                 f"{b['objects']} object, {b['vertices']} vertices, {b['triangles']} triangles")
    # The app's (x, y, z) is Blender's (x, -z, y): the sphere's place, turned to Z up.
    m = b["matrix"]
    where = (m[0][3], m[1][3], m[2][3])
    want = (placed[0], -placed[2], placed[1])
    ok &= report("blender placement", all(abs(p - q) < 1e-5 for p, q in zip(where, want)), f"{where} against {want}")
    # The key and fill suns at pi watts a square metre times their Intensity, and the point
    # light made from the third, each as its own light in the Sculpt lights collection.
    kinds = [l[1] for l in b["lights"]]
    energies = [l[2] for l in b["lights"]]
    ok &= report("blender lights", kinds == ["SUN", "SUN", "POINT"] and abs(energies[0] - math.pi) < 1e-3 and abs(energies[1] - math.pi * FILL_STRENGTH) < 1e-3 and energies[2] > 0,
                 f"{[(l[0], l[1], l[2]) for l in b['lights']]}")
    ok &= report("blender send", b["sent"] == 3 and b["again_same"], f"sent {b['sent']}, a second get kept one object: {b['again_same']}")
    ok &= report("blender add-on", b["operators"] == [["FINISHED"], ["FINISHED"]], f"enabled, Get from Sculpt and Send to Sculpt gave {b['operators']}")

    s = app(f"--settings-file={settings}", f"--open={scene}", "--frames=2", "--script=get_from_blender", f"--save={got}")
    ok &= report("get", s.get("link_moved") == "1" and s.get("link_added") == "2" and s.get("link_swapped") == "0" and s.get("objects") == "4",
                 f"link_moved={s.get('link_moved')} link_added={s.get('link_added')} link_swapped={s.get('link_swapped')} objects={s.get('objects')}")

    s = app(f"--settings-file={settings}", f"--open={got}", "--frames=2", "--script=select 1", f"--export={after}", "--check-mesh")
    ok &= report("every object faces out", s["inverted_objects"] == "0" and s["checked_objects"] == "4", f"{s['inverted_objects']} of {s['checked_objects']} objects face inward")
    old, new = ply_positions(before), ply_positions(after)
    moved = [v for v in range(len(old)) if old[v] != new[v]]
    raised = tuple(struct.unpack("<f", struct.pack("<f", x))[0] for x in b["raised"])
    ok &= report("the raised vertex", moved == [0] and new[0] == raised, f"moved {moved[:5]}, vertex 0 {new[0]} against {raised}")
    now = [float(x) for x in s.get("transform", "0,0,0,0,0,0,1").split(",")]
    ok &= report("the move", abs(now[0] - (placed[0] + 1)) < 1e-4 and all(abs(now[k] - placed[k]) < 1e-4 for k in range(1, 7)),
                 f"transform {now} against {placed} moved 1 along x")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
