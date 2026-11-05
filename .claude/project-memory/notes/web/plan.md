# Web (WASM) build: options, blockers, stages

2026-11-01, thread "Build a web (WASM) version". Measured in the container with Odin dev-2026-10.

## Options compared

| Question | Picked | Against | Why |
|---|---|---|---|
| Compiler target | Odin's own `js_wasm64p32` | `js_wasm32`; Emscripten (Odin object + emcc link) | wasm64p32 keeps `int` 64-bit as on desktop (wasm32 breaks ~10 `max(u32)`/`1<<31` sites and risks silent overflow), pointers stay 32-bit so browsers run it. Odin has no Emscripten target: its core:os and core:thread are unsupported on js either way, so emcc buys SDL3 but not threads or files for Odin code, and adds a 1 GB toolchain (its installer was also refused here). |
| Platform layer | Odin's js runtime (`core:sys/wasm/js`: pointer events with pressure, tilt and pointer type; keys; wheel; resize; rAF `step`) | SDL3 on Emscripten | No extra toolchain; pointer events give pen pressure/tilt natively. Cost: the app's SDL files need a web twin (keys, pointer, files). |
| GPU | WebGPU (`vendor:wgpu`, its js backend) | WebGL2 | The renderer is compute + storage buffers + indirect draws (GPU cull, Smooth all): WebGPU has all three, WebGL2 none. Slang already emits WGSL: 32 of 38 shaders compile today (`-target wgsl`); the 6 that fail are ray tracing, which WebGPU lacks. Browsers: Chrome/Edge (desktop + Android), Safari 26 (iPad/Mac), Firefox 141+ (Windows). |
| Threads | Serial on the main thread first | wasm threads + SharedArrayBuffer workers | Odin's core:thread does not run on js. Serial == parallel bit for bit (hard rule), so the web sculpts identically, just slower. Workers need COOP/COEP headers and an own jobs backend: stage 4. |
| Files | Browser file picker + download, IndexedDB/OPFS for autosave | WASI shim | core:os panics on js; the app's file code needs a seam. |
| C/C++ deps (Luau, ufbx, AutoRemesher) | Off on the web (`AVAILABLE = false`) | wasi-sdk / emcc builds | Each is already optional per platform; bringing them back needs a C toolchain for wasm (stage 5). |

## Blockers found (and the way round)

1. Odin compiles every `_test.odin` file into a normal build, and core:testing/core:os do not build for js: the web build compiles a copy of `src` without test files (`scripts/web_build.py`).
2. Odin dev-2026-10 crashes (llvm_backend_const.cpp:184) on any global slice literal (`X := []u8{...}`) for js_wasm64p32; core:compress/zlib has one, so core:image/png cannot be built for the web. geom's picture readers moved to a `#+build !js` file; PNG via the browser's decoder later. Worth reporting upstream.
3. core:os is unsupported on js: jobs' core count moved to a `!js` file (the web pool has no workers).
4. No Emscripten: not needed on this route.

## Stages

1. **This PR**: `./build.sh web` builds `build/web/` (index.html + sculpt.wasm + odin.js + wgpu.js). The real geom/sculpt/camera packages sculpt a geodesic sphere in the browser on WebGPU: brushes, pen pressure, orbit/pan/zoom, undo/redo, symmetry. Own small WGSL viewport in `src/web` (temporary; replaced by stage 2).
2. WebGPU backend for render's `hal.odin` (`wgpu_*.odin`), shaders' `.wgsl` committed next to `.spv`/`.msl`; render compiles for js.
3. The app on the web: a web twin of the SDL files (keys, pointer, touch, pen, dialogs, platform), files through the picker/downloads and OPFS autosave, the whole UI.
4. Threads: Web Workers sharing memory (COOP/COEP), a jobs backend over them.
5. Luau, ufbx, AutoRemesher built for wasm; hosting (GitHub Pages or any static host with COOP/COEP).
