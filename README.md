# Sculpt

A performance-focused sculpting prototype in Odin, using SDL3 + SDL_GPU for rendering and Dear ImGui for the surrounding interface.

## Layout

| Path | Owns |
| --- | --- |
| `src/app` | Entry point, frame loop, ImGui panels, input routing into `Viewport_Input` |
| `src/render` | Every GPU object the app creates: device, pipeline, viewport target, mesh buffers, shaders |
| `src/geom` | CPU sculpt geometry (structure-of-arrays triangle mesh); no rendering or UI imports |
| `src/camera` | Orbit camera math; no rendering or UI imports |

The 3D viewport is rendered by `render` into an offscreen texture that the `Viewport` panel displays. ImGui never owns sculpt state: panels read and edit `App` fields through pointers each frame, and the viewport panel reports mouse input as a plain struct the camera (and later the brush) consumes.

## Pinned versions

See `scripts/versions.env`: Odin `dev-2026-10`, SDL `3.4.18` (Linux; Windows uses the SDL3 shipped with Odin), odin-imgui `a116eb1` (Dear ImGui `1.92.8-docking`).

## Linux

```sh
# once: system packages are listed at the top of the script
./scripts/setup_deps.sh

./build.sh            # debug build with allocation tracking -> build/sculpt
./build.sh release    # optimized build
./build.sh test       # unit tests (geom, camera)
./build.sh run -- --subdiv=7
./build.sh smoke      # 300 frames in GPU debug mode; non-zero exit on assert, GPU error or leak
```

Headless (CI or containers): run under `Xvfb` with Mesa's llvmpipe Vulkan driver (`mesa-vulkan-drivers`).

## Windows (untested so far)

From an "x64 Native Tools Command Prompt for VS" with git and python on PATH:

```bat
scripts\setup_deps.bat
build.bat            :: or: build.bat release | test | run | smoke
```

Shaders are recompiled when `glslangValidator` (Vulkan SDK) is on PATH; otherwise the committed `.spv` files are used.

## App flags

`--frames=N` exit after N frames, `--gpu-debug` GPU debug/validation mode, `--subdiv=N` icosphere level (default 6: 40,962 vertices), `--width`, `--height`.

## Controls

Orbit: right drag or Alt + left drag. Pan: middle drag or Shift + right drag. Zoom: mouse wheel. Left drag is reserved for the brush.
