---
name: web-wasm-build
description: Web (WASM) version of the sculpt app, started 2026-11-01: route chosen, Odin/toolchain gotchas found, stages, how to build/verify
metadata:
  type: project
  modified: 2026-11-03T01:20:00.000Z
---

Bolt asked 2026-11-01 (thread "Build a web (WASM) version") for the sculpting tool in the browser. Plan: /mnt/project-files/notes/web/plan.md.

Route: Odin's own `-target:js_wasm64p32` (int stays 64-bit; pointers 32) + Odin js runtime (core:sys/wasm/js events) + WebGPU via vendor:wgpu js backend. Not Emscripten (no Odin target; the emsdk installer was refused by the auto-mode classifier anyway), not WebGL2 (no compute/storage/indirect). Slang emits WGSL for 32/38 shaders (6 ray tracing fail).

Stage 1 (branch claude/project-thread-sm2n48): src/web (entry, input), src/render/webgpu (own small WGSL viewport), web/index.html, scripts/web_build.py (--check/--serve/--test), scripts/web_check.mjs (headless Chromium), `./build.sh web|webcheck`, check runs webcheck, gate step `web`.

Gotchas (pinned Odin dev-2026-10):
- Odin compiles *_test.odin into normal builds; core:testing/os fail on js -> web_build mirrors src without tests into build/web/tree.
- Global slice literal (`X := []u8{..}`) crashes the compiler on wasm64p32 (llvm_backend_const.cpp:184): core:compress/zlib -> core:image/png can't build; geom's image readers moved to a `#+build !js` file.
- runtime.heap_allocator unimplemented on js -> web/odin_overlay replaces base/runtime/heap_allocator_other.odin in an Odin root under build/web.
- core:os panics on js (jobs core count split into cores.odin / cores_js.odin; pool has 0 workers).
- odin.js get_element_value_string breaks with intSize 8 (BigInt); wgpu.js reads requiredLimits 8 bytes off -> use default limits (256 MB buffers).
- Headless Chromium: use `--enable-features=Vulkan --use-vulkan=swiftshader --use-webgpu-adapter=swiftshader --disable-vulkan-surface` or screenshots of WebGPU canvases are blank.

Next stages: WebGPU backend for render's hal.odin + WGSL shaders; app on a web platform layer (files via picker/OPFS); worker threads (COOP/COEP); Luau/ufbx/AutoRemesher for wasm.

2026-11-02 23:41 Bolt (stage 2 go, then "do all the changes thats needed i will be away... come back here and the webgpu build app is ready"): goal = the FULL app (real renderer + UI) in the browser on WebGPU, built autonomously. Approach: src/render/wgpu_*.odin backend behind hal.odin (WEBGPU :: ODIN_OS == .JS), scripts/shaders_wgsl.py (committed .wgsl, binding n->2n, split sampler 2n+1, "// not on the web:" stubs), SDL procs on js become wasm imports from module "sdl3" (-define:SDL3_WASM_LIB=sdl3) answered by a small JS shim; wgpu.js requiredLimits read 8 bytes on -> pass pointer 8 bytes before Limits.

Stage 2 built 2026-11-03, PR #522: whole app (src/app, entry web.odin: unwind at frame loop, step per rAF) in browser; web/sdl_web.js = SDL+files(IndexedDB, Save->download)+page imports; src/web and render/webgpu retired; web_check.mjs drives Home/Start/stroke/undo/redo/turn/Ctrl+S. Fresh install shows grey studio look (look_first_run), not a bug.
More pinned-Odin wasm64p32 gotchas: constant slice in any global/@(static) asserts -> use [?]T arrays; #load as []u8 asserts -> #load(path, string)+transmute; f16 vectors crash LLVM above -o:minimal (build uses -o:minimal; -o:speed needs the f16 loops changed); stb's wasm objects take 32-bit size_t -> build rewrites libc-shim uint->u32. Odin wgpu.js AdapterGetInfo/DeviceGetAdapterInfo pass no info -> index.html overrides. Slang WGSL: strip @interpolate off non-@location members; add `diagnostic(off, derivative_uniformity);`.
Open: real GPUs/Safari/Firefox untried; one thread; FBX/Luau/AutoRemesher not on web; next = worker threads (COOP/COEP), -o:speed.
