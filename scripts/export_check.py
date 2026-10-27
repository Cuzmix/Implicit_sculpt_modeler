#!/usr/bin/env python3
"""Checks an exported .glb, .usda or .stl with the tools other programs will read it with.

    python scripts/export_check.py --setup                        # once: the tools, into build/export-tools
    python scripts/export_check.py build/out.glb
    python scripts/export_check.py build/out.usda --keys "Layer 1=1.5"
    python scripts/export_check.py build/out.glb --vertices 642 --triangles 1280 \\
        --keys "Layer 1=1.5,Layer 2=0" --colors --material "Gold,1,0.3" --require
    python scripts/export_check.py build/out.glb --face-materials "Gold=2,Steel=10"
    python scripts/export_check.py build/out.usda --lights "SUN=3.1416,POINT=145.08"
    python scripts/export_check.py build/out.stl --vertices 642 --triangles 1280

Two checks for each, each reported on its own line as PASS, FAIL or SKIP:
- validator: for .glb, the Khronos glTF validator (npm package gltf-validator, run with
  node); for .usda, USD's own validators (UsdValidation, from the usd-core wheel); for
  .stl, a check of the binary layout here (the length the count gives, a header that does
  not start as a text file's does, finite numbers, each normal of unit length and on the
  side its corners wind to). Any error fails; warnings are listed.
- blender: Blender itself (the bpy wheel from PyPI, Python 3.13) imports the file into an
  empty scene, and the check reads back what a person would see: the mesh's vertices and
  triangles, its shape keys with their values, whether it has a colour attribute, and the
  objects the import made (for USD at frame 1, where the weights are keyed), and the first
  material's base colour, metallic and roughness and its image textures, the UV maps, and
  how many faces each material shades, and each light's type and energy. The --vertices,
  --triangles, --keys, --colors, --material, --uv, --textures, --face-materials and --lights options say
  what to expect; without them the check only needs the import to succeed.

A tool that is not installed is reported as SKIP, never as PASS, and the exit code is 0
unless something failed (or, with --require, something was skipped). The tools are
development aids only: nothing of them ships with the app. --setup installs them into
build/export-tools (a Python venv with bpy and usd-core, and node_modules with the glTF
validator); the
SCULPT_BPY_PYTHON and SCULPT_NODE_PATH environment variables point at others instead.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "build", "export-tools")
WINDOWS = os.name == "nt"
VENV_PYTHON = os.path.join(TOOLS, "venv", "Scripts" if WINDOWS else "bin", "python.exe" if WINDOWS else "python")
NODE_MODULES = os.path.join(TOOLS, "node_modules")

VALIDATE_JS = r"""
const v = require('gltf-validator');
const fs = require('fs');
v.validateBytes(new Uint8Array(fs.readFileSync(process.argv[1]))).then(r => {
  console.log(JSON.stringify({errors: r.issues.numErrors, warnings: r.issues.numWarnings,
    messages: r.issues.messages.slice(0, 8).map(m => m.code + ' ' + (m.pointer || '') + ' ' + m.message)}));
}, e => { console.log(JSON.stringify({crash: String(e)})); });
"""

# Run by the Python that has bpy; prints one JSON line.
BLENDER_PY = r"""
import bpy, json, sys
path = sys.argv[-1]
bpy.ops.wm.read_factory_settings(use_empty=True)
importer = {'.glb': bpy.ops.import_scene.gltf, '.stl': bpy.ops.wm.stl_import}.get(path.lower()[-4:], bpy.ops.wm.usd_import)
importer(filepath=path)
# Blender keys a USD file's blend shape weights in an action, which applies once the
# scene is at a frame.
bpy.context.scene.frame_set(1)
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
out = {'objects': sorted(o.type for o in bpy.data.objects), 'version': bpy.app.version_string}
# The lights, by their objects' names: each one's type and energy (a sun's strength in
# watts a square metre, a point's or spot's power in watts).
out['lights'] = [[o.data.type, round(o.data.energy, 4)] for o in sorted(bpy.data.objects, key=lambda o: o.name) if o.type == 'LIGHT']
if meshes:
    me = meshes[0].data
    out['vertices'] = len(me.vertices)
    out['triangles'] = sum(len(p.vertices) - 2 for p in me.polygons)
    out['colors'] = [a.name for a in me.color_attributes]
    keys = me.shape_keys.key_blocks if me.shape_keys else []
    out['keys'] = [[k.name, round(k.value, 6)] for k in keys if k != me.shape_keys.reference_key]
    # How many faces each material slot shades, by the material's name.
    faces = {}
    for p in me.polygons:
        slot = meshes[0].material_slots[p.material_index] if p.material_index < len(meshes[0].material_slots) else None
        name = slot.material.name if slot and slot.material else ''
        faces[name] = faces.get(name, 0) + 1
    out['face_materials'] = faces
    out['uv_layers'] = [l.name for l in me.uv_layers]
    # The first material's Principled BSDF as the import set it up: its base colour (or
    # what feeds it), metallic and roughness.
    mat = meshes[0].active_material
    if mat and mat.use_nodes:
        bsdf = next((n for n in mat.node_tree.nodes if n.type == 'BSDF_PRINCIPLED'), None)
        if bsdf:
            def value(name):
                socket = bsdf.inputs[name]
                if socket.is_linked:
                    return 'linked:' + socket.links[0].from_node.type
                v = socket.default_value
                return [round(x, 4) for x in v[:3]] if hasattr(v, '__len__') else round(v, 4)
            out['material'] = {'name': mat.name, 'base': value('Base Color'), 'metallic': value('Metallic'), 'roughness': value('Roughness')}
        out['images'] = sorted(set(n.image.name for n in mat.node_tree.nodes if n.type == 'TEX_IMAGE' and n.image))
        out['normal_map'] = bsdf is not None and bsdf.inputs['Normal'].is_linked
print('RESULT ' + json.dumps(out))
"""


def setup():
    """Installs the validator and the bpy wheel into build/export-tools."""
    os.makedirs(TOOLS, exist_ok=True)
    npm = shutil.which("npm")
    if npm:
        subprocess.run([npm, "install", "--prefix", TOOLS, "--no-save", "gltf-validator"], check=True)
    else:
        print("setup: npm is not installed; the validator check will be skipped")
    if not os.path.exists(VENV_PYTHON):
        subprocess.run([sys.executable, "-m", "venv", os.path.join(TOOLS, "venv")], check=True)
    # bpy's wheel needs the Python version its Blender release was built against.
    if subprocess.run([VENV_PYTHON, "-m", "pip", "install", "bpy"]).returncode != 0:
        print("setup: pip could not install bpy here (it wants Python 3.13); the blender check will be skipped")
    if subprocess.run([VENV_PYTHON, "-m", "pip", "install", "usd-core"]).returncode != 0:
        print("setup: pip could not install usd-core; the USD validator check will be skipped")
    return 0


def check_stl(path):
    """The binary STL layout, read here: no tool is needed."""
    import math
    import struct
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 84:
        return "FAIL", "%d bytes, shorter than the header" % len(data)
    count = struct.unpack_from("<I", data, 80)[0]
    if len(data) != 84 + 50 * count:
        return "FAIL", "%d bytes, but %d triangles take %d" % (len(data), count, 84 + 50 * count)
    errors = []
    if data[:5].lower() == b"solid":
        errors.append("the header starts with 'solid', as a text file does")
    zero = 0
    for t in range(count):
        row = struct.unpack_from("<12fH", data, 84 + 50 * t)
        if not all(math.isfinite(x) for x in row[:12]):
            errors.append("triangle %d has a NaN or infinite number" % t)
            break
        n, a, b, c = row[0:3], row[3:6], row[6:9], row[9:12]
        length = math.sqrt(sum(x * x for x in n))
        if length == 0:
            zero += 1
            continue
        u = [b[k] - a[k] for k in range(3)]
        v = [c[k] - a[k] for k in range(3)]
        cross = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
        if abs(length - 1) > 1e-3 or sum(n[k] * cross[k] for k in range(3)) <= 0:
            errors.append("triangle %d's normal is not of unit length on its winding's side" % t)
            break
    detail = "%d triangles, %d with a zero normal" % (count, zero)
    if errors:
        return "FAIL", "; ".join(errors) + " (" + detail + ")"
    return "PASS", detail


def bpy_python():
    """A Python that can import bpy, or None."""
    for python in (os.environ.get("SCULPT_BPY_PYTHON"), VENV_PYTHON, sys.executable):
        if python and os.path.exists(python):
            if subprocess.run([python, "-c", "import bpy"], capture_output=True).returncode == 0:
                return python
    return None


def node_path():
    """Where node finds gltf-validator, or None."""
    node = shutil.which("node")
    if not node:
        return None, None
    for path in (os.environ.get("SCULPT_NODE_PATH"), NODE_MODULES):
        if path and os.path.isdir(os.path.join(path, "gltf-validator")):
            return node, path
    return None, None


def check_validator(path):
    node, modules = node_path()
    if not node:
        return "SKIP", "node or the gltf-validator package is not installed (--setup)"
    env = dict(os.environ, NODE_PATH=modules)
    run = subprocess.run([node, "-e", VALIDATE_JS, path], capture_output=True, text=True, env=env)
    try:
        result = json.loads(run.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return "FAIL", "the validator printed nothing readable: " + (run.stderr.strip() or run.stdout.strip())[:300]
    if "crash" in result:
        return "FAIL", result["crash"]
    detail = "%d errors, %d warnings" % (result["errors"], result["warnings"])
    if result["messages"]:
        detail += ": " + "; ".join(result["messages"])
    return ("FAIL" if result["errors"] else "PASS"), detail


# Run by a Python that has pxr (usd-core); prints one JSON line.
USD_VALIDATE_PY = r"""
import json, sys
from pxr import Usd, UsdValidation
stage = Usd.Stage.Open(sys.argv[-1])
validators = UsdValidation.ValidationRegistry().GetOrLoadAllValidators()
errors = UsdValidation.ValidationContext(validators).Validate(stage)
print('RESULT ' + json.dumps({'validators': len(validators), 'errors': [e.GetErrorAsString() for e in errors][:8], 'count': len(errors)}))
"""


def check_usd(path):
    for python in (os.environ.get("SCULPT_BPY_PYTHON"), VENV_PYTHON, sys.executable):
        if python and os.path.exists(python) and subprocess.run([python, "-c", "from pxr import UsdValidation"], capture_output=True).returncode == 0:
            break
    else:
        return "SKIP", "no Python with usd-core (--setup)"
    run = subprocess.run([python, "-c", USD_VALIDATE_PY, path], capture_output=True, text=True)
    lines = [line for line in run.stdout.splitlines() if line.startswith("RESULT ")]
    if not lines:
        return "FAIL", "USD could not open the file: " + run.stderr.strip()[-400:]
    got = json.loads(lines[-1][len("RESULT "):])
    detail = "%d validators, %d errors" % (got["validators"], got["count"])
    if got["errors"]:
        detail += ": " + "; ".join(got["errors"])
    return ("FAIL" if got["count"] else "PASS"), detail


def check_blender(path, args):
    python = bpy_python()
    if not python:
        return "SKIP", "no Python with bpy (--setup, or SCULPT_BPY_PYTHON)"
    run = subprocess.run([python, "-c", BLENDER_PY, path], capture_output=True, text=True)
    lines = [line for line in run.stdout.splitlines() if line.startswith("RESULT ")]
    if run.returncode != 0 or not lines:
        return "FAIL", "the import failed: " + run.stderr.strip()[-400:]
    got = json.loads(lines[-1][len("RESULT "):])
    wrong = []
    if "vertices" not in got:
        wrong.append("no mesh imported")
    else:
        if args.vertices is not None and got["vertices"] != args.vertices:
            wrong.append("%d vertices, expected %d" % (got["vertices"], args.vertices))
        if args.triangles is not None and got["triangles"] != args.triangles:
            wrong.append("%d triangles, expected %d" % (got["triangles"], args.triangles))
        if args.colors and not got["colors"]:
            wrong.append("no colour attribute")
        if args.material is not None:
            want = args.material.split(",")
            m = got.get("material")
            if not m:
                wrong.append("no material")
            else:
                if m["name"] != want[0]:
                    wrong.append("material %s, expected %s" % (m["name"], want[0]))
                for key, text in zip(("metallic", "roughness"), want[1:3]):
                    if isinstance(m[key], str) or abs(m[key] - float(text)) > 1e-3:
                        wrong.append("material %s %s, expected %s" % (key, m[key], text))
        if args.uv and not got.get("uv_layers"):
            wrong.append("no UV map")
        if args.textures is not None and len(got.get("images", [])) != args.textures:
            wrong.append("%d image textures, expected %d" % (len(got.get("images", [])), args.textures))
        if args.textures and not got.get("normal_map"):
            wrong.append("nothing feeds the normal")
        if args.face_materials is not None:
            want = {}
            for item in filter(None, args.face_materials.split(",")):
                name, _, count = item.rpartition("=")
                want[name] = int(count)
            if got["face_materials"] != want:
                wrong.append("faces by material %s, expected %s" % (got["face_materials"], want))
        if args.lights is not None:
            want = []
            for item in filter(None, args.lights.split(",")):
                kind, _, energy = item.partition("=")
                want.append((kind, float(energy)))
            lights = got.get("lights", [])
            if [k for k, _ in lights] != [k for k, _ in want]:
                wrong.append("lights %s, expected %s" % ([k for k, _ in lights], [k for k, _ in want]))
            else:
                for (kind, energy), (_, expect) in zip(lights, want):
                    if abs(energy - expect) > 0.01 * abs(expect) + 1e-4:
                        wrong.append("a %s light of %g, expected %g" % (kind, energy, expect))
        if args.keys is not None:
            expected = []
            for item in filter(None, args.keys.split(",")):
                name, _, value = item.rpartition("=")
                expected.append((name, float(value)))
            keys = [(name, value) for name, value in got["keys"]]
            if [name for name, _ in keys] != [name for name, _ in expected]:
                wrong.append("shape keys %s, expected %s" % ([n for n, _ in keys], [n for n, _ in expected]))
            else:
                for (name, value), (_, want) in zip(keys, expected):
                    if abs(value - want) > 1e-4:
                        wrong.append("shape key %s at %g, expected %g" % (name, value, want))
    detail = "Blender %s: %s vertices, %s triangles, shape keys %s, colours %s, objects %s" % (
        got.get("version"), got.get("vertices"), got.get("triangles"),
        ", ".join("%s=%g" % (n, v) for n, v in got.get("keys", [])) or "none",
        ", ".join(got.get("colors", [])) or "none", ", ".join(got["objects"]))
    if got.get("lights"):
        detail += ", lights %s" % ", ".join("%s=%g" % (k, e) for k, e in got["lights"])
    if "material" in got:
        detail += ", material %s" % json.dumps(got["material"])
    if got.get("uv_layers"):
        detail += ", UV maps %s" % ", ".join(got["uv_layers"])
    if got.get("images"):
        detail += ", images %s%s" % (", ".join(got["images"]), ", normal map wired" if got.get("normal_map") else "")
    if len(got.get("face_materials", {})) > 1:
        detail += ", faces by material %s" % json.dumps(got["face_materials"], sort_keys=True)
    if wrong:
        return "FAIL", "; ".join(wrong) + " (" + detail + ")"
    return "PASS", detail


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("file", nargs="?", help="the exported .glb, .usda or .stl")
    parser.add_argument("--setup", action="store_true", help="install the tools into build/export-tools")
    parser.add_argument("--vertices", type=int)
    parser.add_argument("--triangles", type=int)
    parser.add_argument("--keys", help='the shape keys in order with their values: "Layer 1=1.5,Layer 2=0"')
    parser.add_argument("--colors", action="store_true", help="expect a colour attribute")
    parser.add_argument("--material", help='the first material: "NAME,METALLIC,ROUGHNESS" (the base colour is reported)')
    parser.add_argument("--uv", action="store_true", help="expect a UV map")
    parser.add_argument("--textures", type=int, help="how many distinct pictures the first material's image textures show (and that one feeds the normal)")
    parser.add_argument("--face-materials", help='the faces each material shades: "Gold=2,Steel=10"')
    parser.add_argument("--lights", help='the lights by name, each its type and energy to 1%%: "SUN=3.14,SPOT=290"')
    parser.add_argument("--require", action="store_true", help="a skipped check fails the run")
    args = parser.parse_args()
    if args.setup:
        return setup()
    if not args.file:
        parser.error("name the file to check")
    if not os.path.exists(args.file):
        print("FAIL file     %s does not exist" % args.file)
        return 1
    path = os.path.abspath(args.file)
    results = []
    if path.lower().endswith(".glb"):
        results.append(("validator",) + check_validator(path))
    elif path.lower().endswith(".stl"):
        results.append(("validator",) + check_stl(path))
    else:
        results.append(("validator",) + check_usd(path))
    results.append(("blender",) + check_blender(path, args))
    for name, verdict, detail in results:
        print("%-4s %-9s %s" % (verdict, name, detail))
    failed = any(v == "FAIL" or (args.require and v == "SKIP") for _, v, _ in results)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
