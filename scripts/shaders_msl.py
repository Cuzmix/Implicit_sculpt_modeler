#!/usr/bin/env python3
"""Makes the Metal source of every committed shader with slangc, and checks that it is current.

    python scripts/shaders_msl.py           # remake each .msl whose .spv changed (needs slangc)
    python scripts/shaders_msl.py --all     # remake every .msl
    python scripts/shaders_msl.py --check   # fail on a missing or stale .msl, without slangc (build check runs it)

The Metal backend (src/gpu/mtl_*.odin) on Apple's platforms takes Metal source, so each
src/render/shaders/name.stage.slang has a name.stage.msl beside its .spv, made by slangc's own
Metal target with the flags the .spv is made with, which the Mac and iPad builds embed instead
(src/render/shaders.odin). slangc renames `main`, which Metal refuses as a function name, to
`main_0`.

slangc numbers the Metal slots its own way, so the file's second line says where each binding
went: from both targets' reflection, each sampled texture (its texture slot, then its sampler's),
read-only and read-write texture and buffer, uniform block and acceleration structure, in the
order of its SPIR-V set and binding within each kind (the order the renderer binds them in and
shaders_gen.odin counts them by), to the slot slangc gave it, as

    // slots s=T:S,T:S rt=T wt=T rb=B wb=B u=B a=B

which mtl_slots_parse reads when a shader or kernel is made. The sets are SDL_GPU's, as the
counts are (scripts/shaders_gen.py): a vertex shader's resources set 0 and uniforms set 1, a
fragment shader's resources set 2 and uniforms set 3, a kernel's read-only resources set 0,
read-write ones set 1, uniforms set 2 and its acceleration structure set 3. A fragment shader's
own uniform set alone is named: the mesh fragment shaders also declare the vertex stage's
Frame_Uniforms (set 1), which the Metal backend never binds for them.

Remaking also refuses a shader whose Metal reflection lays out a uniform block or a storage
buffer's element differently from its SPIR-V (the renderer writes one layout for both), and a
vertex shader whose buffers reach the slots the Metal backend binds vertex buffers at
(MTL_FIRST_VERTEX_BUFFER).

The first line names the .spv made from the same source and its SHA-256, so --check finds a
missing or stale one with no slangc installed, and a shader changed without its Metal source
fails `build.bat check` / `./build.sh check` instead of drawing the old shader on the iPad. A
shader whose Slang source starts with "// vulkan only" (an array of textures indexed per pixel)
has no .msl: only the own Vulkan backend loads it. Without slangc, remaking prints a note and
leaves the committed files as they are, as the build does with the .spv.

Metal refuses an intersection_query (a ray query) as a struct's field or a function's return
value, and slangc puts a module-level static into a context struct it passes around, so a ray
query shared at module level compiles for Vulkan and fails only on the Mac and iPad builds.
--check (and remaking) refuses a .msl that declares one either way, naming the line of the .msl
and of the Slang source it came from. The Metal compile defines METAL, so a shader can keep a
shared query for Vulkan and declare one where it is used for Metal (render_trace.slang).
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADERS = os.path.join(ROOT, "src", "render", "shaders")
STAGES = {"vert": "vertex", "frag": "fragment", "comp": "compute"}
# deps/slang on Linux and macOS; on Windows the Vulkan SDK puts slangc on PATH, as build.bat finds it.
SLANGC = os.path.join(ROOT, "deps", "slang", "bin", "slangc.exe" if os.name == "nt" else "slangc")
if not os.path.exists(SLANGC):
    SLANGC = shutil.which("slangc") or SLANGC
LINE = re.compile(r'^#line (\d+)(?: "([^"]*)")?')
QUERY = "intersection_query<"
HEADER = re.compile(r"^// slangc metal from (\S+) sha256 ([0-9a-f]{64})$")
# The Metal backend's first vertex buffer slot (src/gpu/mtl_resources.odin).
FIRST_VERTEX_BUFFER = 14
# Each stage's SPIR-V sets: (resources, read-write resources, uniforms).
SETS = {"vert": (0, None, 1), "frag": (2, None, 3), "comp": (0, 1, 2)}


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def first_line(source):
    with open(os.path.join(SHADERS, source), encoding="utf-8") as f:
        return f.readline()


def sources():
    return sorted(f for f in os.listdir(SHADERS)
                  if f.endswith(".slang") and len(f.split(".")) == 3 and f.split(".")[1] in STAGES
                  and not first_line(f).startswith("// vulkan only"))


def problem(source):
    """Why name.stage.slang's .msl is not current, or "" when it is."""
    name = source[:-len(".slang")]
    spv, msl = name + ".spv", name + ".msl"
    if not os.path.exists(os.path.join(SHADERS, spv)):
        return f"{spv} is missing, so {msl} cannot be checked"
    try:
        with open(os.path.join(SHADERS, msl), encoding="utf-8") as f:
            match = HEADER.match(f.readline().rstrip("\r\n"))
            slots = f.readline()
    except FileNotFoundError:
        return f"{msl} is missing"
    if not match:
        return f"{msl} has no slangc header"
    if match.group(1) != spv or match.group(2) != sha256(os.path.join(SHADERS, spv)):
        return f"{msl} was made from an older {spv}"
    if not slots.startswith("// slots "):
        return f"{msl} has no slot table on its second line"
    with open(os.path.join(SHADERS, msl), encoding="utf-8") as f:
        misuses = query_misuses(f.read())
    if misuses:
        return f"{msl}: " + f"; {msl}: ".join(misuses)
    return ""


def query_misuses(text):
    """Each ray query the Metal source declares as a struct's field or returns from a function,
    as "line N (source.slang:M): what", where M is slangc's #line for it."""
    found, depth, struct_depth, src, src_line = [], 0, None, "?", 0
    for n, line in enumerate(text.split("\n"), 1):
        directive = LINE.match(line)
        if directive:
            src_line = int(directive.group(1)) - 1
            if directive.group(2):
                src = os.path.basename(directive.group(2))
            continue
        src_line += 1
        code = line.split("//")[0].strip()
        if QUERY in code:
            where = f"line {n} ({src}:{src_line})"
            if struct_depth is not None and depth == struct_depth + 1 and code.endswith(";") and "(" not in code:
                found.append(f"{where}: a ray query is a struct field, which Metal refuses")
            elif depth == 0 and "(" in code and code.index(QUERY) < code.index("("):
                found.append(f"{where}: a function returns a ray query, which Metal refuses")
        if struct_depth is None and re.match(r"^(struct|class)\b", code):
            struct_depth = depth
        depth += code.count("{") - code.count("}")
        if struct_depth is not None and depth <= struct_depth and "}" in code:
            struct_depth = None
    return found


def slangc(source, target, out, reflection):
    """One slangc run with the flags build.sh compiles the .spv with; its reflection."""
    stage = source.split(".")[1]
    line = first_line(source)
    flags = ["-warnings-disable", "41012,40100"]
    if line.startswith("// slangc: -fp-mode precise"):
        flags += ["-fp-mode", "precise"]
    args = [SLANGC, os.path.join(SHADERS, source), "-target", target, "-entry", "main", "-stage", STAGES[stage],
            "-matrix-layout-row-major", "-O0", "-o", out, "-reflection-json", reflection] + flags
    if target == "spirv":
        args += ["-profile", "spirv_1_3"]
    else:
        args += ["-D", "METAL"]
    run = subprocess.run(args, capture_output=True, text=True)
    if run.returncode != 0:
        raise RuntimeError(f"slangc {target} failed:\n{run.stdout}{run.stderr}")
    with open(reflection, encoding="utf-8") as f:
        return json.load(f)["parameters"]


def layout(t, prefix=""):
    """A struct's fields (and arrays' strides) as {path: (offset, size)}, to compare targets."""
    out = {}
    if t.get("kind") == "struct":
        for field in t["fields"]:
            b = field.get("binding", {})
            out[prefix + field["name"]] = (b.get("offset"), b.get("size"))
            out.update(layout(field["type"], prefix + field["name"] + "."))
    elif t.get("kind") == "array":
        out[prefix + "[]"] = (t.get("elementCount"), t.get("uniformStride"))
        out.update(layout(t["elementType"], prefix + "[]."))
    return out


def layouts(parameters):
    found = {}
    for p in parameters:
        t = p["type"]
        if t["kind"] == "constantBuffer":
            found[p["name"]] = layout(t["elementType"])
        elif t.get("baseShape") == "structuredBuffer":
            found[p["name"]] = layout(t.get("resultType", {}))
    return found


def slots(source, metal, spirv):
    """The slots line (the module docstring has the rules)."""
    stage = source.split(".")[1]
    resources, writes, uniforms = SETS[stage]
    where = {p["name"]: p.get("binding", p.get("bindings")) for p in metal}
    kinds = {k: [] for k in ("s", "rt", "wt", "rb", "wb", "u", "a")}
    # Specialization constants (Metal's function constants) take no slot.
    bound = [p for p in spirv if p["binding"].get("kind") != "specializationConstant"]
    for p in sorted(bound, key=lambda p: (p["binding"].get("space", 0), p["binding"]["index"])):
        space, t, m = p["binding"].get("space", 0), p["type"], where[p["name"]]
        if t["kind"] == "constantBuffer":
            if space == uniforms:
                kinds["u"].append(str(m["index"]))
            continue
        shape = t.get("baseShape")
        if stage == "comp" and space == 3 and shape == "accelerationStructure":
            kinds["a"].append(str(m["index"]))
            continue
        if space not in (resources, writes):
            raise RuntimeError(f"{p['name']}: set {space} has no Metal slot here")
        write = space == writes
        if shape == "texture2D" and t.get("combined"):
            tex = next(x["index"] for x in m if x["kind"] == "shaderResource")
            samp = next(x["index"] for x in m if x["kind"] == "samplerState")
            kinds["s"].append(f"{tex}:{samp}")
        elif shape == "texture2D":
            kinds["wt" if write else "rt"].append(str(m["index"]))
        elif shape == "structuredBuffer":
            kinds["wb" if write else "rb"].append(str(m["index"]))
        else:
            raise RuntimeError(f"{p['name']}: a {shape} has no Metal slot here")
    if stage == "vert":
        reach = [int(x) for k in ("rb", "u") for x in kinds[k]]
        if reach and max(reach) >= FIRST_VERTEX_BUFFER:
            raise RuntimeError(f"its buffers reach slot {max(reach)}, where the Metal backend binds vertex buffers from {FIRST_VERTEX_BUFFER}")
    return "// slots " + " ".join(f"{k}={','.join(v)}" for k, v in kinds.items())


def remake(source):
    name = source[:-len(".slang")]
    spv = name + ".spv"
    with tempfile.TemporaryDirectory() as scratch:
        metal = slangc(source, "metal", os.path.join(scratch, "k.metal"), os.path.join(scratch, "m.json"))
        spirv = slangc(source, "spirv", os.path.join(scratch, "k.spv"), os.path.join(scratch, "s.json"))
        lm, ls = layouts(metal), layouts(spirv)
        for block, fields in ls.items():
            moved = [f for f in fields if lm.get(block, {}).get(f) != fields[f]]
            if moved:
                raise RuntimeError(f"{block} is laid out differently for Metal ({', '.join(moved[:4])})")
        table = slots(source, metal, spirv)
        with open(os.path.join(scratch, "k.metal"), encoding="utf-8") as f:
            body = f.read().replace("\r\n", "\n")
        misuses = query_misuses(body)
        if misuses:
            raise RuntimeError("; ".join(misuses))
    with open(os.path.join(SHADERS, name + ".msl"), "w", encoding="utf-8", newline="\n") as f:
        f.write(f"// slangc metal from {spv} sha256 {sha256(os.path.join(SHADERS, spv))}\n{table}\n")
        f.write(body)


def main(argv):
    all_sources = sources()
    names = {s[:-len(".slang")] for s in all_sources}
    if "--check" in argv:
        problems = [p for p in (problem(s) for s in all_sources) if p]
        problems += [f"{m} has no .slang beside it" for m in sorted(os.listdir(SHADERS))
                     if m.endswith(".msl") and m[:-len(".msl")] not in names]
        problems += [f"{m} is no longer made (every shader's Metal source is its .msl)" for m in sorted(os.listdir(SHADERS))
                     if m.endswith(".metal")]
        for p in problems:
            print(f"shaders_msl: {p}", file=sys.stderr)
        if problems:
            print("shaders_msl: run python scripts/shaders_msl.py (needs deps/slang)", file=sys.stderr)
            return 1
        print(f"shaders_msl: {len(all_sources)} Metal shaders current")
        return 0
    if not os.path.exists(SLANGC):
        print("shaders_msl: slangc missing (scripts/setup_deps.sh): using the committed .msl")
        return 0
    todo = all_sources if "--all" in argv else [s for s in all_sources if problem(s)]
    for s in todo:
        try:
            remake(s)
        except (RuntimeError, KeyError, StopIteration) as e:
            print(f"shaders_msl: {s}: {e}", file=sys.stderr)
            return 1
    print(f"shaders_msl: made {len(todo)} of {len(all_sources)} Metal shaders")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
