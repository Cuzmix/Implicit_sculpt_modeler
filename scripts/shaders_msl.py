#!/usr/bin/env python3
"""Makes the Metal source of every committed shader, and checks that it is current.

    python scripts/shaders_msl.py           # remake each .msl whose .spv changed (needs deps/shadercross)
    python scripts/shaders_msl.py --all     # remake every .msl
    python scripts/shaders_msl.py --check   # fail on a missing or stale .msl, without the tool (build check runs it)

SDL_GPU draws through Metal on Apple's platforms, which takes Metal source, so each
src/render/shaders/name.stage.spv (made from its Slang source by build.sh or build.bat) has a
name.stage.msl beside it, and the iPad build embeds those instead (src/render/shaders.odin).
They are made by SDL_shadercross (scripts/build_shadercross.py builds it into deps/shadercross),
which maps SDL's SPIR-V sets and bindings to the Metal slots SDL_GPU binds and renames `main`,
which Metal refuses, to `main0`. Metal language 1.2, the tool's default, and no culling of
unused bindings: every binding the renderer declares stays where it says.

Each .msl starts with a line naming the tool's commit and the SHA-256 of the .spv it was made
from, so --check finds a missing or stale one with no tool installed, and a shader changed
without its Metal source fails `build.bat check` / `./build.sh check` instead of drawing the old
shader on the iPad. A shader whose Slang source starts with "// vulkan only" (an array of
textures indexed per pixel, which shadercross cannot map to SDL's Metal slots) has no .msl:
only the own Vulkan backend loads it, so both modes skip it. Without the tool, remaking prints a note and leaves the committed files as
they are, as the build does with the .spv when slangc is missing.

A shader whose Slang source starts with "// ray query" traces against an acceleration
structure, which SDL_shadercross's Metal language (1.2) cannot name and SDL_GPU cannot bind.
Its Metal source, name.stage.metal, is made by slangc's own Metal target instead, for the own
Metal backend alone (src/render/mtl_accel.odin). slangc numbers the Metal slots its own way,
so the file's second line maps SDL's: from both targets' reflection, each sampler, read-only
and read-write texture and buffer, uniform block and the structure (set 3, binding 0) in
SDL_GPU's order, to the slot slangc gave it, as

    // slots s=T:S,T:S rt=T wt=T rb=B wb=B u=B a=B

which mtl_slots_parse reads when the pipeline is made. Its first line carries the hash of the
.spv made from the same source, so --check finds it stale exactly as an .msl; remaking it needs
deps/slang (scripts/setup_deps.sh).
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
TOOL = os.path.join(ROOT, "deps", "shadercross", "shadercross.exe" if os.name == "nt" else "shadercross")
STAGES = {"vert": "vertex", "frag": "fragment", "comp": "compute"}
HEADER = re.compile(r"^// SDL_shadercross ([0-9a-f]{12}) from (\S+) sha256 ([0-9a-f]{64})$")
# deps/slang on Linux and macOS; on Windows the Vulkan SDK puts slangc on PATH, as build.bat finds it.
SLANGC = os.path.join(ROOT, "deps", "slang", "bin", "slangc.exe" if os.name == "nt" else "slangc")
if not os.path.exists(SLANGC):
    SLANGC = shutil.which("slangc") or SLANGC
SLANG_HEADER = re.compile(r"^// slangc metal from (\S+) sha256 ([0-9a-f]{64})$")


def pinned_commit():
    with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
        for line in f:
            key, eq, value = line.strip().partition("=")
            if eq and key == "SHADERCROSS_COMMIT":
                return value[:12]
    sys.exit("shaders_msl: no SHADERCROSS_COMMIT in scripts/versions.env")


def first_line(spv):
    try:
        with open(os.path.join(SHADERS, spv[:-len(".spv")] + ".slang"), encoding="utf-8") as f:
            return f.readline()
    except FileNotFoundError:
        return ""


def vulkan_only(spv):
    """Whether name.stage.spv's Slang source marks it as the own Vulkan backend's alone."""
    return first_line(spv).startswith("// vulkan only")


def ray_query(spv):
    """Whether name.stage.spv's Slang source traces with ray queries (made by slangc for Metal)."""
    return first_line(spv).startswith("// ray query")


def spv_files():
    return sorted(f for f in os.listdir(SHADERS)
                  if f.endswith(".spv") and f.split(".")[-2] in STAGES and not vulkan_only(f) and not ray_query(f))


def rq_files():
    return sorted(f for f in os.listdir(SHADERS) if f.endswith(".comp.spv") and ray_query(f))


def rq_problem(spv):
    """Why a ray query kernel's .metal is not current, or "" when it is."""
    metal = spv[:-len(".spv")] + ".metal"
    try:
        with open(os.path.join(SHADERS, metal), encoding="utf-8") as f:
            match = SLANG_HEADER.match(f.readline().rstrip("\r\n"))
    except FileNotFoundError:
        return f"{metal} is missing"
    if not match:
        return f"{metal} has no slangc header"
    if match.group(1) != spv or match.group(2) != sha256(os.path.join(SHADERS, spv)):
        return f"{metal} was made from an older {spv}"
    return ""


def slangc_json(source, target, out, reflection):
    args = [SLANGC, source, "-target", target, "-entry", "main", "-stage", "compute", "-matrix-layout-row-major",
            "-o", out, "-reflection-json", reflection, "-warnings-disable", "41012,40100"]
    if target == "spirv":
        args += ["-profile", "spirv_1_3"]
    run = subprocess.run(args, capture_output=True, text=True, cwd=SHADERS)
    if run.returncode != 0:
        raise RuntimeError(f"slangc {target} failed:\n{run.stdout}{run.stderr}")
    with open(reflection, encoding="utf-8") as f:
        return {p["name"]: p.get("binding", p.get("bindings")) for p in json.load(f)["parameters"]}


def rq_slots(metal, spirv):
    """The slots line: SDL_GPU's order of each kind, from the SPIR-V sets and bindings, mapped to
    the Metal slots slangc gave the same parameters."""
    def where(binding):
        return binding.get("space", 0), binding["index"]
    kinds = {k: [] for k in ("s", "rt", "wt", "rb", "wb", "u", "a")}
    for name, b in sorted(spirv.items(), key=lambda item: where(item[1])):
        space, _ = where(b)
        m = metal[name]
        if isinstance(m, list):
            tex = next(x["index"] for x in m if x["kind"] == "shaderResource")
            samp = next(x["index"] for x in m if x["kind"] == "samplerState")
            kinds["s"].append(f"{tex}:{samp}")
            continue
        slot = str(m["index"])
        texture = m["kind"] == "shaderResource"
        if space == 0:
            kinds["rt" if texture else "rb"].append(slot)
        elif space == 1:
            kinds["wt" if texture else "wb"].append(slot)
        elif space == 2:
            kinds["u"].append(slot)
        elif space == 3 and b["index"] == 0:
            kinds["a"].append(slot)
        else:
            raise RuntimeError(f"{name}: set {space} has no Metal slot here")
    return "// slots " + " ".join(f"{k}={','.join(v)}" for k, v in kinds.items())


def rq_remake(spv):
    name = spv[:-len(".spv")]
    source = name + ".slang"
    with tempfile.TemporaryDirectory() as scratch:
        try:
            metal_slots = slangc_json(source, "metal", os.path.join(scratch, "k.metal"), os.path.join(scratch, "m.json"))
            spirv_slots = slangc_json(source, "spirv", os.path.join(scratch, "k.spv"), os.path.join(scratch, "s.json"))
            slots = rq_slots(metal_slots, spirv_slots)
        except (RuntimeError, KeyError, StopIteration) as e:
            print(f"shaders_msl: {source} failed: {e}", file=sys.stderr)
            return False
        with open(os.path.join(scratch, "k.metal"), encoding="utf-8") as f:
            body = f.read().replace("\r\n", "\n")
    with open(os.path.join(SHADERS, name + ".metal"), "w", encoding="utf-8", newline="\n") as f:
        f.write(f"// slangc metal from {spv} sha256 {sha256(os.path.join(SHADERS, spv))}\n{slots}\n")
        f.write(body)
    return True


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def header_of(msl_path):
    """The (commit, spv name, hash) an .msl was made from, or None when it has no header."""
    try:
        with open(msl_path, encoding="utf-8") as f:
            match = HEADER.match(f.readline().rstrip("\r\n"))
    except FileNotFoundError:
        return None
    return match.groups() if match else None


def problem(spv, commit):
    """Why name.stage.spv's .msl is not current, or "" when it is."""
    msl = spv[:-len(".spv")] + ".msl"
    made = header_of(os.path.join(SHADERS, msl))
    if made is None:
        return f"{msl} is missing" if not os.path.exists(os.path.join(SHADERS, msl)) else f"{msl} has no SDL_shadercross header"
    if made[1] != spv or made[2] != sha256(os.path.join(SHADERS, spv)):
        return f"{msl} was made from an older {spv}"
    if made[0] != commit:
        return f"{msl} was made by SDL_shadercross {made[0]}, not the pinned {commit}"
    return ""


def remake(spv, commit):
    msl = spv[:-len(".spv")] + ".msl"
    stage = STAGES[spv.split(".")[-2]]
    with tempfile.TemporaryDirectory() as scratch:
        out = os.path.join(scratch, msl)
        run = subprocess.run([TOOL, os.path.join(SHADERS, spv), "-s", "SPIRV", "-d", "MSL", "-t", stage, "-o", out],
                             capture_output=True, text=True)
        if run.returncode != 0 or not os.path.exists(out):
            print(f"shaders_msl: {spv} failed:\n{run.stdout}{run.stderr}", file=sys.stderr)
            return False
        with open(out, encoding="utf-8") as f:
            body = f.read().replace("\r\n", "\n")
    with open(os.path.join(SHADERS, msl), "w", encoding="utf-8", newline="\n") as f:
        f.write(f"// SDL_shadercross {commit} from {spv} sha256 {sha256(os.path.join(SHADERS, spv))}\n")
        f.write(body)
    return True


def main(argv):
    commit = pinned_commit()
    spvs = spv_files()
    if "--check" in argv:
        problems = [p for p in (problem(s, commit) for s in spvs) if p]
        orphans = [m for m in sorted(os.listdir(SHADERS)) if m.endswith(".msl") and m[:-len(".msl")] + ".spv" not in spvs]
        problems += [f"{m} has no .spv beside it" for m in orphans]
        rqs = rq_files()
        problems += [p for p in (rq_problem(s) for s in rqs) if p]
        problems += [f"{m} has no ray query .spv beside it" for m in sorted(os.listdir(SHADERS))
                     if m.endswith(".metal") and m[:-len(".metal")] + ".spv" not in rqs]
        for p in problems:
            print(f"shaders_msl: {p}", file=sys.stderr)
        if problems:
            print("shaders_msl: run python scripts/build_shadercross.py once, then python scripts/shaders_msl.py", file=sys.stderr)
            return 1
        print(f"shaders_msl: {len(spvs)} Metal shaders and {len(rqs)} ray query kernels current")
        return 0
    rq_failed = []
    if os.path.exists(SLANGC):
        rqs = rq_files()
        rq_todo = rqs if "--all" in argv else [s for s in rqs if rq_problem(s)]
        rq_failed = [s for s in rq_todo if not rq_remake(s)]
        print(f"shaders_msl: made {len(rq_todo) - len(rq_failed)} of {len(rqs)} ray query kernels' Metal source")
    else:
        print("shaders_msl: slangc missing (scripts/setup_deps.sh): using the committed .metal")
    if not os.path.exists(TOOL):
        print("shaders_msl: SDL_shadercross missing (python scripts/build_shadercross.py): using the committed .msl")
        return 1 if rq_failed else 0
    todo = spvs if "--all" in argv else [s for s in spvs if problem(s, commit)]
    failed = [s for s in todo if not remake(s, commit)]
    print(f"shaders_msl: made {len(todo) - len(failed)} of {len(spvs)} Metal shaders")
    return 1 if failed or rq_failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
