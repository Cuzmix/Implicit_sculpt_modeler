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
shader on the iPad. Without the tool, remaking prints a note and leaves the committed files as
they are, as the build does with the .spv when slangc is missing.
"""

import hashlib
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHADERS = os.path.join(ROOT, "src", "render", "shaders")
TOOL = os.path.join(ROOT, "deps", "shadercross", "shadercross.exe" if os.name == "nt" else "shadercross")
STAGES = {"vert": "vertex", "frag": "fragment", "comp": "compute"}
HEADER = re.compile(r"^// SDL_shadercross ([0-9a-f]{12}) from (\S+) sha256 ([0-9a-f]{64})$")


def pinned_commit():
    with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
        for line in f:
            key, eq, value = line.strip().partition("=")
            if eq and key == "SHADERCROSS_COMMIT":
                return value[:12]
    sys.exit("shaders_msl: no SHADERCROSS_COMMIT in scripts/versions.env")


def spv_files():
    return sorted(f for f in os.listdir(SHADERS) if f.endswith(".spv") and f.split(".")[-2] in STAGES)


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
        for p in problems:
            print(f"shaders_msl: {p}", file=sys.stderr)
        if problems:
            print("shaders_msl: run python scripts/build_shadercross.py once, then python scripts/shaders_msl.py", file=sys.stderr)
            return 1
        print(f"shaders_msl: {len(spvs)} Metal shaders current")
        return 0
    if not os.path.exists(TOOL):
        print("shaders_msl: SDL_shadercross missing (python scripts/build_shadercross.py): using the committed .msl")
        return 0
    todo = spvs if "--all" in argv else [s for s in spvs if problem(s, commit)]
    failed = [s for s in todo if not remake(s, commit)]
    print(f"shaders_msl: made {len(todo) - len(failed)} of {len(spvs)} Metal shaders")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
