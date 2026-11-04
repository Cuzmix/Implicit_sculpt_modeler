#!/usr/bin/env python3
"""Writes src/render/shaders_gen.odin from the shaders' own reflection, and checks that it is current.

    python scripts/shaders_gen.py           # reflect each shader whose .spv changed (needs slangc)
    python scripts/shaders_gen.py --all     # reflect every shader
    python scripts/shaders_gen.py --check   # fail on a missing or stale entry, without slangc (build check runs it)

Each src/render/shaders/name.stage.slang gets one constant in shaders_gen.odin: a
gpu.Shader_Desc for a vertex or fragment shader, a gpu.Compute_Pipeline_Desc for a kernel, named
NAME_STAGE (mesh.vert is MESH_VERT), holding the code this platform embeds (render/shaders.odin)
and every count the backends build their binding layouts from, taken from slangc's reflection
of the source rather than written by hand beside each pipeline. A kernel's thread group size
comes from its [numthreads] the same way.

The counts follow SDL_GPU's sets, which every backend binds by. A vertex shader's resources are
set 0 and its uniforms set 1; a fragment shader's resources set 2 and its uniforms set 3; a
kernel's sampled textures and read-only storage set 0, its read-write storage set 1 and its
uniforms set 2. A sampled texture (a texture and sampler combined) counts as a sampler, any other
texture as a storage texture and a structured buffer as a storage buffer. Only the stage's own
uniform set is counted: the mesh fragment shaders also read the vertex stage's Frame_Uniforms at
set 1, which the backends bind for both stages. Set 3 of a kernel holds what only the own
backends bind (an acceleration structure, an array of textures), which their _traced and _array
pipeline makers add, so it is not counted either.

A shader whose first line is "// vulkan only" has no Metal or WGSL source, so its constant
exists only in the Vulkan build (`when gpu.VULKAN`) and embeds its .spv. One whose first line is
"// ray query" embeds the ray query code and entry point (RQ_EXT, RQ_ENTRY).

Each entry is preceded by a line naming its .spv and that file's SHA-256, so --check finds a
missing or stale one with no slangc installed, as shaders_msl.py and shaders_wgsl.py do, and
remaking reflects only the shaders whose .spv changed, keeping the other entries as they are.
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
OUT = os.path.join(ROOT, "src", "render", "shaders_gen.odin")
STAGES = {"vert": "vertex", "frag": "fragment", "comp": "compute"}
# deps/slang on Linux and macOS; on Windows the Vulkan SDK may put slangc on PATH, as build.bat finds it.
SLANGC = os.path.join(ROOT, "deps", "slang", "bin", "slangc.exe" if os.name == "nt" else "slangc")
if not os.path.exists(SLANGC):
    SLANGC = shutil.which("slangc") or SLANGC
ENTRY_HEADER = re.compile(r"^// (\S+\.spv) sha256 ([0-9a-f]{64})$")

PREAMBLE = """package render

// Written by scripts/shaders_gen.py from each shader's slangc reflection: never edit it by hand.
// `build.sh` and `build.bat` remake it with the shaders, and `check` fails on a stale entry.

import "../gpu"
"""


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def first_line(source):
    with open(os.path.join(SHADERS, source), encoding="utf-8") as f:
        return f.readline()


def sources():
    return sorted(f for f in os.listdir(SHADERS)
                  if f.endswith(".slang") and len(f.split(".")) == 3 and f.split(".")[1] in STAGES)


def constant_name(source):
    return source[:-len(".slang")].replace(".", "_").upper()


def reflect(source):
    """slangc's reflection of one shader, with the flags build.sh compiles its .spv with."""
    stage = STAGES[source.split(".")[1]]
    line = first_line(source)
    flags = []
    if line.startswith("// slangc: -fp-mode precise"):
        flags += ["-fp-mode", "precise"]
    if line.startswith(("// vulkan only", "// ray query", "// barycentric")):
        flags += ["-warnings-disable", "41012"]
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "reflection.json")
        run = subprocess.run([SLANGC, os.path.join(SHADERS, source), "-target", "spirv", "-profile", "spirv_1_3",
                              "-matrix-layout-row-major", "-O0", "-stage", stage, "-entry", "main",
                              "-o", os.path.join(tmp, "out.spv"), "-reflection-json", out] + flags,
                             capture_output=True, text=True)
        if run.returncode != 0:
            raise RuntimeError((run.stdout + run.stderr).strip() or "slangc failed")
        with open(out, encoding="utf-8") as f:
            return json.load(f)


def counts(source, reflection):
    """The counts of one shader by SDL_GPU's sets (the module docstring has the rules)."""
    stage = source.split(".")[1]
    c = {"samplers": 0, "ro_textures": 0, "ro_buffers": 0, "rw_textures": 0, "rw_buffers": 0, "uniforms": 0}
    resources, writes, uniforms = {"vert": (0, None, 1), "frag": (2, None, 3), "comp": (0, 1, 2)}[stage]
    for p in reflection["parameters"]:
        binding, kind = p["binding"], p["type"]
        space = binding.get("space", 0)
        if kind["kind"] == "constantBuffer":
            if space == uniforms:
                c["uniforms"] += 1
            continue
        if kind["kind"] != "resource" or space not in (resources, writes):
            continue
        shape = kind.get("baseShape")
        if shape == "texture2D":
            if kind.get("combined"):
                c["samplers"] += 1
            else:
                c["rw_textures" if space == writes else "ro_textures"] += 1
        elif shape == "structuredBuffer":
            c["rw_buffers" if space == writes else "ro_buffers"] += 1
        elif shape != "accelerationStructure":
            raise RuntimeError(f"{source}: {p['name']} is a {shape}, which shaders_gen.py does not count")
    group = reflection["entryPoints"][0].get("threadGroupSize") or [1, 1, 1]
    return c, group


def entry(source, digest, reflection):
    """The lines of one shader's entry in shaders_gen.odin: its header and its constant."""
    name, stage = constant_name(source), source.split(".")[1]
    line = first_line(source)
    vulkan_only, ray_query = line.startswith("// vulkan only"), line.startswith("// ray query")
    base = source[:-len(".slang")]
    if vulkan_only:
        code, entrypoint = f'#load("shaders/{base}.spv", string)', 'cstring("main")'
    elif ray_query:
        code, entrypoint = f'#load("shaders/{base}" + RQ_EXT, string)', "RQ_ENTRY"
    else:
        code, entrypoint = f'#load("shaders/{base}" + SHADER_EXT, string)', "SHADER_ENTRY"
    c, group = counts(source, reflection)
    fields = [f"code = {code}", f"entrypoint = {entrypoint}", "format = SHADER_FORMAT"]
    if stage == "comp":
        fields += [f"num_samplers = {c['samplers']}", f"num_readonly_storage_textures = {c['ro_textures']}",
                   f"num_readonly_storage_buffers = {c['ro_buffers']}", f"num_readwrite_storage_textures = {c['rw_textures']}",
                   f"num_readwrite_storage_buffers = {c['rw_buffers']}", f"num_uniform_buffers = {c['uniforms']}",
                   f"threadcount_x = {group[0]}", f"threadcount_y = {group[1]}", f"threadcount_z = {group[2]}"]
        kind = "gpu.Compute_Pipeline_Desc"
    else:
        fields += [f"stage = .{'Vertex' if stage == 'vert' else 'Fragment'}", f"num_samplers = {c['samplers']}",
                   f"num_storage_textures = {c['ro_textures']}", f"num_storage_buffers = {c['ro_buffers']}",
                   f"num_uniform_buffers = {c['uniforms']}"]
        kind = "gpu.Shader_Desc"
    body = "{\n" + "".join(f"\t{f},\n" for f in fields) + "}"
    constant = f"{name} :: {kind}{body}"
    if vulkan_only:
        constant = "when gpu.VULKAN {\n" + "\n".join("\t" + l for l in constant.split("\n")) + "\n}"
    return f"// {base}.spv sha256 {digest}\n{constant}\n"


def existing():
    """The entries shaders_gen.odin holds now, by .spv name: (its hash, its text)."""
    try:
        with open(OUT, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return {}
    found, current = {}, None
    for line in text.split("\n"):
        match = ENTRY_HEADER.match(line)
        if match:
            current = match.group(1)
            found[current] = [match.group(2), line + "\n"]
        elif current is not None:
            if line == "":
                current = None
            else:
                found[current][1] += line + "\n"
    return found


def problems(all_sources, entries):
    out = []
    for s in all_sources:
        spv = s[:-len(".slang")] + ".spv"
        if not os.path.exists(os.path.join(SHADERS, spv)):
            out.append(f"{spv} is missing")
        elif spv not in entries:
            out.append(f"{spv} has no entry in shaders_gen.odin")
        elif entries[spv][0] != sha256(os.path.join(SHADERS, spv)):
            out.append(f"{spv} changed since its entry was written")
    names = {s[:-len(".slang")] + ".spv" for s in all_sources}
    out += [f"shaders_gen.odin has an entry for {spv}, which has no .slang" for spv in sorted(entries) if spv not in names]
    return out


def main(argv):
    all_sources = sources()
    entries = existing()
    if "--check" in argv:
        found = problems(all_sources, entries)
        for p in found:
            print(f"shaders_gen: {p}", file=sys.stderr)
        if found:
            print("shaders_gen: run python scripts/shaders_gen.py (needs deps/slang)", file=sys.stderr)
            return 1
        print(f"shaders_gen: {len(all_sources)} shader descriptions current")
        return 0
    if not os.path.exists(SLANGC):
        print("shaders_gen: slangc missing (scripts/setup_deps.sh): using the committed shaders_gen.odin")
        return 0
    made, text = 0, [PREAMBLE]
    for s in all_sources:
        spv = s[:-len(".slang")] + ".spv"
        digest = sha256(os.path.join(SHADERS, spv))
        if "--all" in argv or spv not in entries or entries[spv][0] != digest:
            try:
                text.append(entry(s, digest, reflect(s)))
            except RuntimeError as e:
                print(f"shaders_gen: {s}: {e}", file=sys.stderr)
                return 1
            made += 1
        else:
            text.append(entries[spv][1])
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(text))
    print(f"shaders_gen: reflected {made} of {len(all_sources)} shaders")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
