#!/usr/bin/env python3
"""Makes the WGSL of every committed shader for the web version, and checks that it is current.

    python scripts/shaders_wgsl.py           # remake each .wgsl whose .spv changed (needs deps/slang)
    python scripts/shaders_wgsl.py --all     # remake every .wgsl
    python scripts/shaders_wgsl.py --check   # fail on a missing or stale .wgsl, without slangc (build check runs it)

The web version draws with WebGPU (src/gpu/wgpu_*.odin), which takes WGSL, so each
src/render/shaders/name.stage.slang has a name.stage.wgsl beside its .spv and .msl (but one
whose first line is "// vulkan only", which the web never loads), made by
slangc's own WGSL target with the flags the .spv is made with, and the web build embeds those
(src/render/shaders.odin). The first line names the .spv made from the same source and its
SHA-256, so --check finds a missing or stale one with no slangc installed, as shaders_msl.py
does for Metal.

The bindings keep SDL_GPU's SPIR-V sets as WGSL groups (vertex resources 0, vertex uniforms 1,
fragment resources 2, fragment uniforms 3; compute read-only 0, read-write 1, uniforms 2), but
WGSL has no combined texture and sampler: slangc splits each into a texture at the binding the
source gave and a sampler at the next, which collides with the binding after. So every binding
is renumbered here: the resource at SPIR-V binding n goes to 2n and a split sampler to 2n + 1,
the rule the WebGPU backend binds by (wgpu_binding in src/gpu/wgpu_resources.odin).

Some shaders cannot be WGSL: ray queries, barycentrics and read-write storage textures of
some formats have no WebGPU form. Their .wgsl is the header and a second line

    // not on the web: <slangc's reason>

which the backend refuses with that reason, as the renderer already handles a device without
those features (it never asks for the barycentric or ray query pipelines there, and render
mode says it cannot start).
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADERS = os.path.join(ROOT, "src", "render", "shaders")
STAGES = {"vert": "vertex", "frag": "fragment", "comp": "compute"}
SLANGC = os.path.join(ROOT, "deps", "slang", "bin", "slangc.exe" if os.name == "nt" else "slangc")
if not os.path.exists(SLANGC):
    SLANGC = shutil.which("slangc") or SLANGC
HEADER = re.compile(r"^// slangc wgsl from (\S+) sha256 ([0-9a-f]{64})$")
UNAVAILABLE = "// not on the web: "
DECL = re.compile(r"^@binding\((\d+)\) @group\((\d+)\) var(<[^>]*>)? (\w+)\b")


def sha256(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def vulkan_only(source):
    """Whether the Slang source marks itself as the Vulkan backend's alone (its first line),
    as shaders_msl.py reads it: the web build never loads one, so it has no .wgsl."""
    with open(os.path.join(SHADERS, source), encoding="utf-8") as f:
        return f.readline().startswith("// vulkan only")


def sources():
    return sorted(f for f in os.listdir(SHADERS)
                  if f.endswith(".slang") and f.split(".")[-2] in STAGES and not vulkan_only(f))


def problem(source):
    """Why name.stage.slang's .wgsl is not current, or "" when it is."""
    name = source[:-len(".slang")]
    spv, wgsl = name + ".spv", name + ".wgsl"
    if not os.path.exists(os.path.join(SHADERS, spv)):
        return f"{spv} is missing, so {wgsl} cannot be checked"
    try:
        with open(os.path.join(SHADERS, wgsl), encoding="utf-8") as f:
            match = HEADER.match(f.readline().rstrip("\r\n"))
    except FileNotFoundError:
        return f"{wgsl} is missing"
    if not match:
        return f"{wgsl} has no slangc header"
    if match.group(1) != spv or match.group(2) != sha256(os.path.join(SHADERS, spv)):
        return f"{wgsl} was made from an older {spv}"
    return ""


def renumber(body):
    """SDL_GPU's binding n becomes 2n, and the sampler slangc split from a combined texture
    at n becomes 2n + 1 (see the module's note)."""
    lines = body.split("\n")
    decls = {}
    for i, line in enumerate(lines):
        m = DECL.match(line)
        if m:
            decls[m.group(4)] = (i, int(m.group(1)), int(m.group(2)))
    out = {}
    for name, (i, binding, group) in decls.items():
        sampler = re.match(r"^(\w+)_sampler_(\d+)$", name)
        sibling = f"{sampler.group(1)}_texture_{sampler.group(2)}" if sampler else None
        if sibling in decls and decls[sibling][2] == group:
            out[i] = 2 * decls[sibling][1] + 1
        else:
            out[i] = 2 * binding
    seen = set()
    for i, binding in out.items():
        group = int(DECL.match(lines[i]).group(2))
        if (group, binding) in seen:
            raise RuntimeError(f"two resources at group {group} binding {binding} after renumbering")
        seen.add((group, binding))
        lines[i] = re.sub(r"^@binding\(\d+\)", f"@binding({binding})", lines[i])
    return "\n".join(lines)


# WGSL refuses a texture sample whose derivatives depend on control flow that may differ
# between neighbouring pixels, which SPIR-V and Metal leave to the shader's author; the
# shaders sample in such branches on the desktop too (a split view's two halves, a masked
# area), where the derivatives are what the GPU gives, so the web takes them alike.
UNIFORMITY = "diagnostic(off, derivative_uniformity);\n"


def strip_interpolation(body):
    """slangc copies a flat varying's @interpolate onto the plain struct the shader keeps its
    inputs in, a member with no @location, which WGSL refuses; the entry's own input struct
    keeps it where it counts."""
    return re.sub(r"(?m)^(\s*)@interpolate\(\w+\)\s+(?!.*@location)", r"\1", body)


def remake(source):
    name = source[:-len(".slang")]
    spv = name + ".spv"
    stage = STAGES[name.split(".")[-1]]
    with open(os.path.join(SHADERS, source), encoding="utf-8") as f:
        first = f.readline()
    flags = ["-fp-mode", "precise"] if first.startswith("// slangc: -fp-mode precise") else []
    header = f"// slangc wgsl from {spv} sha256 {sha256(os.path.join(SHADERS, spv))}\n"
    with tempfile.TemporaryDirectory() as scratch:
        out = os.path.join(scratch, "s.wgsl")
        run = subprocess.run([SLANGC, source, "-target", "wgsl", "-matrix-layout-row-major", "-O0", "-stage", stage,
                              "-entry", "main", *flags, "-o", out], capture_output=True, text=True, cwd=SHADERS)
        if run.returncode != 0 or not os.path.exists(out):
            errors = [l for l in (run.stdout + run.stderr).splitlines() if "error" in l]
            reason = errors[0].split(":", 1)[-1].strip() if errors else "slangc failed"
            text = f"{header}{UNAVAILABLE}{reason}\n"
            unavailable = True
        else:
            with open(out, encoding="utf-8") as f:
                text = header + UNIFORMITY + renumber(strip_interpolation(f.read().replace("\r\n", "\n")))
            unavailable = False
    with open(os.path.join(SHADERS, name + ".wgsl"), "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return unavailable


def main(argv):
    all_sources = sources()
    if "--check" in argv:
        problems = [p for p in (problem(s) for s in all_sources) if p]
        names = {s[:-len(".slang")] for s in all_sources}
        problems += [f"{w} has no .slang beside it" for w in sorted(os.listdir(SHADERS))
                     if w.endswith(".wgsl") and w[:-len(".wgsl")] not in names]
        for p in problems:
            print(f"shaders_wgsl: {p}", file=sys.stderr)
        if problems:
            print("shaders_wgsl: run python scripts/shaders_wgsl.py (needs deps/slang)", file=sys.stderr)
            return 1
        print(f"shaders_wgsl: {len(all_sources)} WGSL shaders current")
        return 0
    if not os.path.exists(SLANGC):
        print("shaders_wgsl: slangc missing (scripts/setup_deps.sh): using the committed .wgsl")
        return 0
    todo = all_sources if "--all" in argv else [s for s in all_sources if problem(s)]
    failed = []
    for s in todo:
        try:
            if remake(s):
                failed.append(s)
        except RuntimeError as e:
            print(f"shaders_wgsl: {s}: {e}", file=sys.stderr)
            return 1
    print(f"shaders_wgsl: made {len(todo)} of {len(all_sources)} WGSL shaders"
          + (f" ({len(failed)} not on the web: {', '.join(failed)})" if failed else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
