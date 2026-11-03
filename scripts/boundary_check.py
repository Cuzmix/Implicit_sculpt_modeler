#!/usr/bin/env python3
"""Fails when a package other than src/gpu talks to a GPU API, when one other than src/render
imports src/gpu, when one other than src/gpu names SDL_GPU's types, or when anything calls
SDL_GPU at all.

Only src/gpu talks to the GPU: it holds the seam (hal.odin) and the Vulkan, Metal and
WebGPU backends behind it, and only src/render imports it (AGENTS.md, package
boundaries). Everything else holds render's handles (render.Cmd, render.Texture,
render.Fence, render.Sample_Count) and calls its procs, so a GPU backend changes one
package. SDL itself is allowed in src/app
only in the files that hold the windows, the events, the pen, the file dialogs and the
system's services (APP_SDL_FILES); the tools, panels, commands and files name keys by the
app's own Key (keys.odin) and ask platform.odin for the rest, and no other package
imports SDL at all. SDL_GPU no longer draws: the seam (src/gpu/hal.odin, gpu.create_texture
for sdl.CreateGPUTexture and so on) hands every call to a backend, and no file calls one of
SDL_GPU's procs. The seam speaks the gpu package's own types (src/gpu/types.odin): render
names none of SDL_GPU's, and only the backends still hold SDL's opaque handle types
underneath, until the GPU abstraction's own handles replace them
(notes/gpu-own-model/design.md, G1b).
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
# SDL_GPU's types (sdl.GPUTexture, sdl.GPUTextureFormat), which render no longer names.
GPU_TYPE = re.compile(r"\bsdl\.GPU\w*")
GPU_CALL = re.compile(r"\bsdl\.((?!GPU)\w*GPU\w*|GPU\w*Supports\w*)\(")
SDL_IMPORT = re.compile(r'^\s*import\s+(\w+\s+)?"vendor:sdl3[^"]*"', re.M)
# The files of src/app that may import SDL: the run, its frame and its windows, the device
# and its events, touch, the pen and its bridges, the input diagnostics, the file dialogs,
# frame pacing and idling, the kit's window glue, and the system services.
APP_SDL_FILES = {
    "android.odin", "device.odin", "diagnostics.odin", "diagnostics_test.odin", "files.odin", "frame_rate.odin",
    "frame.odin", "help_labels.odin", "idle.odin", "idle_test.odin", "ios.odin", "keys_sdl.odin", "main.odin", "navigate.odin", "new_ui.odin",
    "pen_samples.odin", "pen_samples_test.odin", "pen_samples_windows.odin", "pencil.odin", "pencil_test.odin",
    "platform.odin", "touch.odin", "view_window.odin", "web.odin",
}
GPU_IMPORT = re.compile(r'^\s*import\s+(\w+\s+)?"vendor:(vulkan|directx/[^"]+|darwin/Metal\w*|wgpu)"', re.M)
GPU_PACKAGE_IMPORT = re.compile(r'^\s*import\s+(\w+\s+)?"[./]*gpu"', re.M)


def main() -> int:
    bad = []
    for path in sorted((ROOT / "src").rglob("*.odin")):
        rel = path.relative_to(ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            for m in GPU_CALL.finditer(line):
                bad.append(f"{rel}:{n}: sdl.{m.group(1)} calls SDL_GPU, which no longer draws; call its proc in src/gpu/hal.odin")
        in_gpu, in_render = rel.startswith("src/gpu/"), rel.startswith("src/render/")
        if not in_render and not in_gpu and GPU_PACKAGE_IMPORT.search(text):
            bad.append(f"{rel}: imports src/gpu, which only render may")
        if in_render:
            for m in GPU_IMPORT.finditer(text):
                bad.append(f"{rel}: imports {m.group(0).strip()}; only src/gpu talks to the GPU")
            for n, line in enumerate(text.splitlines(), 1):
                if not line.lstrip().startswith("//") and GPU_TYPE.search(line):
                    bad.append(f"{rel}:{n}: names SDL_GPU's type {GPU_TYPE.search(line).group(0)}; use the gpu package's (src/gpu/types.odin)")
        if in_gpu or in_render:
            continue
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("//"):
                continue
            if GPU_NAME.search(line):
                bad.append(f"{rel}:{n}: {line.strip()}")
        for m in GPU_IMPORT.finditer(text):
            bad.append(f"{rel}: imports {m.group(0).strip()}")
        allowed = rel.startswith("src/app/") and path.name in APP_SDL_FILES
        if not allowed and SDL_IMPORT.search(text):
            bad.append(f"{rel}: imports SDL; use the app's Key (keys.odin) or platform.odin, or add a device file to APP_SDL_FILES")
    if bad:
        print("boundary: only src/gpu talks to the GPU and only render imports it, nothing calls SDL_GPU, and only the app's platform files import SDL:")
        for b in bad:
            print("  " + b)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
