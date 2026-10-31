#!/usr/bin/env python3
"""Fails when a package other than src/render names the GPU API, or when render calls
SDL_GPU anywhere but its seam.

Only src/render talks to the GPU (AGENTS.md, package boundaries): everything else holds
render's handles (render.Cmd, render.Texture, render.Fence, render.Sample_Count) and calls
its procs, so a second GPU backend changes one package. SDL itself stays allowed in
src/app for windows, events and the pen. Inside render, SDL_GPU's procs are called only
from the seam (src/render/hal.odin, gpu_create_texture for sdl.CreateGPUTexture and so on),
which a second backend answers too; its types and info structs are used everywhere.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
# SDL_GPU's names (sdl.GPUTexture, sdl.AcquireGPUCommandBuffer, sdl.WaitForGPUIdle, ...)
# and the native GPU bindings Odin ships.
GPU_NAME = re.compile(r"\bsdl\.\w*GPU\w*")
# A call of one of SDL_GPU's procs: they start with a verb (sdl.CreateGPUTexture,
# sdl.WaitForGPUIdle) or ask what it supports (sdl.GPUTextureSupportsFormat), its types
# with GPU, so a conversion such as sdl.GPUSampleCount(x) is not one.
GPU_CALL = re.compile(r"\bsdl\.((?!GPU)\w*GPU\w*|GPU\w*Supports\w*)\(")
GPU_IMPORT = re.compile(r'^\s*import\s+(\w+\s+)?"vendor:(vulkan|directx/[^"]+|darwin/Metal\w*|wgpu)"', re.M)


def main() -> int:
    bad = []
    for path in sorted((ROOT / "src" / "render").glob("*.odin")):
        if path.name == "hal.odin":
            continue
        rel = path.relative_to(ROOT).as_posix()
        for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for m in GPU_CALL.finditer(line):
                bad.append(f"{rel}:{n}: sdl.{m.group(1)} outside the seam; call its gpu_ proc in hal.odin")
    for path in sorted((ROOT / "src").rglob("*.odin")):
        rel = path.relative_to(ROOT).as_posix()
        if rel.startswith("src/render/"):
            continue
        text = path.read_text(encoding="utf-8")
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            if GPU_NAME.search(line):
                bad.append(f"{rel}:{n}: {line.strip()}")
        for m in GPU_IMPORT.finditer(text):
            bad.append(f"{rel}: imports {m.group(0).strip()}")
    if bad:
        print("boundary: only src/render may name the GPU API, and only its seam calls it:")
        for b in bad:
            print("  " + b)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
