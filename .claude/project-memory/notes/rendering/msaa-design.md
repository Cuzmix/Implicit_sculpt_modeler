# MSAA for the viewport (roadmap 1.4): design

Goal: silhouettes, creases seen edge-on and wireframe lines stop stair-stepping. Off, 2x, 4x (default 4x on
desktop, 2x on Android), in Settings > Performance > Display and `set msaa 4x`. Off must give today's dumps
bit for bit. Partial redraw, the idle cache, Studio render, thumbnails and the navigation head keep working.

## SDL_GPU facts (SDL 3.4.18, checked in deps/sdl3-src/src/gpu/SDL_gpu.c)
- An MSAA texture cannot be sampled, cannot have mips, and cannot be a blit source.
- Depth cannot be resolved. Colour resolves with store_op RESOLVE or RESOLVE_AND_STORE into a 1-sample texture.
- CopyGPUTextureToTexture has no sample-count check; the app is Vulkan-only (SPIR-V), and vkCmdCopyImage
  allows equal sample counts. Verified under validation by `smoke` with MSAA on.
- Pipelines carry their sample count, so a pipeline can only draw into targets of that count.
- Support is per format: GPUTextureSupportsSampleCount for VIEWPORT_COLOR_FORMAT and r.depth_format.

## Renderer
- `Renderer.samples: sdl.GPUSampleCount` (what the viewport uses now). The mesh, wire and clear pipelines
  are created twice: a 1-sample set for thumbnails and the navigation head, and a set at `samples` for the
  viewport (the same set when samples is 1). `renderer_set_msaa(r, want) -> got` falls back 4x -> 2x -> off
  to what both formats support, waits for the GPU, rebuilds the viewport set, and returns what it got.
- `Viewport_Target` gains `samples` and, when samples > 1, `ms_color` and `ms_depth` (MSAA, target-only
  usage). `vt.color` stays the 1-sample, sampled texture everything downstream reads (UI composite,
  download, studio); it becomes the resolve target. `vt.depth` stays 1-sample and is only created when
  samples is 1 (it is what Studio samples then). viewport_target_resize recreates everything when the size
  or the renderer's sample count changes.
- `begin_mesh_pass` takes the target: MSAA colour with store_op RESOLVE_AND_STORE into vt.color (the MSAA
  contents are kept because the next partial frame LOADs them), MSAA depth with STORE.
- The idle cache: cache.color and cache.depth at the same sample count; the cache pass draws into them with
  STORE (no resolve); the copy pass copies MSAA -> MSAA as today; the live pass loads and resolves.
- Partial redraw: unchanged logic; the pass loads the MSAA targets, clears the scissored rect with the
  MSAA clear pipeline, draws, and resolves (the resolve covers the whole target: there is no partial
  resolve, so its cost is a full-screen resolve per partial frame, about 0.1 ms at 1080p on a desktop GPU).
- Frame keys: the sample count goes into both headers, so changing it redraws everything.

## Studio render
It samples camera depth. With samples > 1 the studio owns a 1-sample viewport-sized depth (and a scratch
colour, as the 1-sample mesh pipeline has a colour target) and fills it on the first sample after a change
with the 1-sample pipelines and the same culled draws (draw_items, so hidden parts stay hidden). That frame
render_viewport drew nothing (nothing changed), so prepare_draws' indirect buffers are free to rewrite.
It runs once per still view, never during a stroke or orbit.

## Interface and settings
- SETTINGS row `msaa` (enum Msaa: Off, X2, X4; written "off", "x2", "x4"; script `set msaa x4`). Applied at
  the start of the next frame like vsync; if the device gives less, the setting shows what it got.
- Settings > Performance > Display: "Anti-aliasing" tabs Off / 2x / 4x with a sentence on cost.
- `--gpubench` keeps measuring with whatever the setting is; its header names the sample count. Flags:
  none new (scripts replace flags).

## Cost (estimates; the VM's llvmpipe timings are meaningless)
At 1080p 4x: colour LOAD + RESOLVE_AND_STORE ~75 MB and depth LOAD + STORE ~66 MB a frame, roughly
0.25-0.35 ms on a 3060 Ti; the 10M stroke from 0.41 to about 0.7 ms GPU. Memory: +~130 MB with the cache at
1080p 4x. Tiled mobile GPUs pay for every LOAD, hence 2x by default on Android.

## Verification
- `set msaa off` dumps are bit-identical to before the change (A/B against the parent commit).
- 4x dump: probe a sphere's silhouette, edge pixels take in-between values; same flags twice give 0 diff;
  `--no-partial` vs partial 0 diff with MSAA on; cache on vs off 0 diff.
- `smoke` clean under validation with 4x (the MSAA copy in particular), studio render on with 4x.
- Bolt: `build.bat gpubench` with 4x and off on the RTX 3060 Ti; acceptance 10M stroke <= 0.75 ms, orbit <= 0.9 ms.

## After the architect review (2026-10-27)
- Pipelines: a `Mesh_Pipelines{mesh, wire, clear}` per sample count, chosen from the target's `samples` and
  passed to begin_mesh_pass, draw_items and render_rect (they bind r.mesh_pipeline etc. directly today).
- `viewport_target_resize(..., samples := ._1)`: only the main viewport passes r.samples; thumbnails and the
  navigation head stay 1-sample (the UI samples the nav head's texture; thumbnails copy into a 1-sample atlas).
- A failed MSAA allocation retries at 1 sample with a warning instead of ending the app.
- Studio: its own 1-sample camera depth, refilled whenever `st.samples == 0` (covers resize, reset, turning
  on), with a depth-only pipeline through the culled draws.
- Fallback goes to the nearest supported count (Vulkan guarantees 1 and 4, not 2).
- `cycle_resolve_texture = true` when the resolve overwrites vt.color, as `cycle = !load` does today.
- Cost adds the idle cache's two MSAA copies a frame (~133 MB at 1080p 4x); gpubench gets a two-object case.
