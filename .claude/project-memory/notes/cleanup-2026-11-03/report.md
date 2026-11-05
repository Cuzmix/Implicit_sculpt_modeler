# Cleanup sweep, 2026-11-03

From `odin-sculpt` at `3fa95db`; read-only, nothing edited. Three sweeps (render, app, everything
else) plus a grep of every top-level declaration. Spot-checked claims are marked ✓. Line counts are
rough. The GPU abstraction itself is in `notes/gpu-own-model/design.md` and is not repeated here.

## The short version

- **The GPU layer** is the biggest structural debt (design already written).
- **The interface still carries twins** of the "one UI per thing" kind: two card-group systems, two
  Settings UIs, two section enums, two Home pages, two pack pages. These are Bolt's calls.
- **Dead and test-only code** is modest: about 64 procs and constants, ~1,000 lines.
- **Duplication** clusters in render's helpers (buffer growth, full-screen passes, submit-and-wait,
  atlases), the sRGB curve (5 copies), the package list (7 places), dependency scripts and CI.
- **Generated files nobody loads**: ~540 WGSL lines for Vulkan-only shaders, ~3,300 MSL/WGSL lines
  for GPU-sculpt kernels that only run on Vulkan.
- **Compatibility shims** still exist despite the no-compat rule (a handful, all small).
- **Docs and skills** name ~20 procs and scenarios that no longer exist.

## A. Safe, mechanical, no decision needed (one or two PRs)

| # | What | Where | Saves |
|---|---|---|---|
| A1 | Delete 32 declarations nothing references | grep list: `ui.modifier_button`, `ui.shadow_circle`, `poly.mesh_from_triangles`, `poly.edit_find`, `app.panel_summary`, `app.dock_on`, `app.row_toggles`, `render.lights_turn`, `geom.bvh_query_sphere`, `sculpt.sculptor_is_dynamic`, ... (keep `srgb_table`, `gear_init` (`@init`), `Mtl_Objc_Anchor` (Odin objc workaround), luau C fields) | ~250 |
| A2 | Procs alive only through tests: delete with their tests, or move into the test | `ui.tree_row` + `Tree_Row_Result` (replaced by `thumb_row`, ~250 with tests), `geom.curve_tube`/`curve_resample` (replaced by `bezier_tube`, ~110), `poly.shortest_*_path`, `geom.chunk_bvh_any_hit`, `bezier_nearest`, `app.preset_pick`, `history_forget`, ... Keep the shader-mirror maths in `render/finish.odin` (test oracles), marked private | ~600 |
| A3 | `palette_rows` result overwritten before use ✓ | `app/palette.odin:633` vs `:677`; `PALETTE_ROWS` dead | 12 |
| A4 | Duplicate unreachable `when WEBGPU` branches ✓ | `render/hal.odin:794-795, 821-822` | 2 |
| A5 | Stop generating WGSL for `// vulkan only` shaders ✓ and delete the 4 files | `scripts/shaders_wgsl.py`; `cull_count/cull_write.comp.wgsl`, two stubs | ~540 generated |
| A6 | Load GPU-sculpt kernels only `when VULKAN` ✓ (their only backend), mark sources vulkan only | `render/sculpt_gpu.odin:39-45, 288` | ~3,300 generated, smaller iPad/web binaries |
| A7 | Unused caps: `subgroup_size`, `int64_atomics` (one exit stat reads them; comments say "nothing uses it yet") | `render/caps.odin:25-34`, three backends | ~30 |
| A8 | Unused formats in the three format tables (stencil formats, RG, 10-10-10-2) and the stencil code they imply | `vk_device.odin:500`, `mtl_device.odin:127`, `wgpu_device.odin:270` | ~30 |
| A9 | Always-`.SDR` composition argument; GPU name passed through an SDL property bag | `gpu_set_swapchain_parameters`; `gpu_get_device_properties` | ~30 |
| A10 | Compatibility shims the AGENTS.md rule forbids: `Workspace:Focus/Inspect/Studio` aliases ✓, `custom_material` optional 7th field, Objects card kept "so old workspaces keep working", `add_shape`/`add_voxel` set only by settings | `app/keymap.odin:203`, `settings.odin:826`, `kit_objects_card.odin:73-91` (+ `Kit_Window.Objects`), `new_ui.odin:416` | ~100 |
| A11 | Graphics failure text tells a web user to get Vulkan 1.3 (small bug) | `app/graphics.odin:19-23` | fix |

## B. Shared helpers instead of copies (render and scripts; one PR each, 0 px)

| # | What | Where | Saves |
|---|---|---|---|
| B1 | One `buffer_fit` for 5 grow-a-buffer helpers and 2 inline copies (one releases without waiting, the others wait: the policy differs) | `ui_pass.odin:297`, `sculpt_gpu.odin:998/1011`, `smooth_compute.odin:250`, `path.odin:1178`, `trace.odin:676, 774` | ~80 |
| B2 | One `fullscreen_pass` for ~12 copies; delete `create_prefilter_pipeline` (equal to `create_fullscreen_pipeline`); one shader-pair maker | `finish.odin:169`, `live_ao`, `studio`, `path`, `trace`, `environment.odin:192` | ~145 |
| B3 | One submit-and-wait for 6 copies; `texture_download` on top of `readback_start` | `smooth_compute.odin:267`, `matcap.odin:59`, `environment.odin:117`, ... | ~50 |
| B4 | One `Atlas` for thumbs, step pictures and pictures | `thumbs.odin`, `step_pictures.odin`, `pictures.odin` | ~45 |
| B5 | One batched upload loop | `path.odin:1198`, `trace.odin:791` | ~25 |
| B6 | sRGB curve: 5 copies though `geom/srgb.odin` says it is the one home | `geom/bake.odin:555`, `gltf_read.odin:595`, `mesh_look.odin:203`, `sculpt/preview.odin:277,283` | ~30 |
| B7 | `geom.triangle_normal` for 3 private copies; one `peak_rss_mb` | `retopo/thin_parts.odin:279`, `sculpt/mask_by.odin:311`, `brush.odin:2184`; `app/main.odin:1041` vs `bench/rss_*` | ~40 |
| B8 | One package list, read by build.sh, build.bat, gate.py, .vscode (it has drifted: VS Code misses hdri and retopo) | 7 places | drift |
| B9 | `scripts/deps_common.py` for the 5 copies of the versions.env parser and the compiler-command code | `build_luau.py`, `build_ufbx.py`, `build_autoremesher.py`, ... | ~100 |
| B10 | ipad.yml and mac.yml share ~80% (reusable workflow); input-tests.yml copies setup_deps and has a dead concurrency key | `.github/workflows/` | ~105 |

These GPU helpers (B1-B5) mostly disappear inside the GPU abstraction's G2 step, so do them there
rather than twice.

## C. Twins in the interface: Bolt's calls (one UI per thing)

| # | Twin | Where | Saves | Suggested |
|---|---|---|---|---|
| C1 | Two card-group systems: rail groups (tabs/stacked, folds, colours) and stack groups (tabs/sections, folds); a rail button docks into the stack column | `rail_groups.odin` (498 + 141 test), `rail_dock.odin` (127), `stack_groups.odin` (392) ✓ | ~700-800 | Keep stack groups; a rail button opens a stack group's card |
| C2 | A card button docks on the rail but pops out as a window elsewhere | `rail_dock.odin:7-13` vs `card_pop.odin:7-15` | ~130 | One behaviour, decided with C1 |
| C3 | Two Settings UIs with different category lists (5 tabs vs 10 sections) | `kit_settings.odin`, `lens_settings.odin`, `settings_blocks.odin:86` | ~250-300 | Keep the 10 sections; narrow windows drill down |
| C4 | Two enums for the same cards (`Kit_Section`, `Panel_Kind`) mirrored by tables; two "Open card" commands | `new_ui.odin:~580`, `lens_stack.odin:26`, `panel_kind.odin:51`, `commands.odin:2209-2235` | ~200-300 | One enum, one `Open_Card` |
| C5 | Two pack pages: Library's Pack category and a separate Library panel | `kit_library.odin`, `kit_brushes.odin` | ~150 | Install/Remove inside Library |
| C6 | Two Home pages (narrow and wide) | `kit_home.odin`, `lens_home.odin` | ~150-200 | One page that reflows |
| C7 | One feature, four names: thumbnail, mini view, second view; does it overlap view panes and view windows? | `thumbnail.odin`, `lens_chrome.odin:172`, `Second_View` | ? | Bolt to say what it should be |
| C8 | Display link "Pace with the display (trial)": opt-in for days, never measured | `render/mtl_link.odin` (299), settings, caps | ~330 | Measure on the iPad, then make it a real setting or delete |

## D. Structure (no lines saved, easier to work in)

- `app/main.odin` `run` 429 lines with ~50 `defer`s; `frame_step` 549; `scene_apply` 392;
  `settings_load` 360; `exit_stats_print` 731 (224 of 865 keys read by nothing).
- `App` 343 field lines, `Kit_State` ~400: group by feature.
- `render/renderer.odin` 2,518 lines: split pipelines, mesh buffers, viewport, lights, readback.
- `scripts/touch_check.py` 14,377 lines, 797 scenarios: split by area with one runner; a few dead
  helpers; PNG writer and stats parser copied (`ppm.write_png`, `headless.py`).
- Code in the wrong package: `decimate_mirrored` (app → geom), polygon helpers in `model_tool.odin`
  and `model.odin` (app → poly), `geom/usd_write.odin` (→ usd), `--ui-events` test plumbing out of
  `new_ui.odin`.
- Two Catmull-Clark rule sets (`poly/subdivide.odin`, `sculpt/levels_cc.odin`); sharing them is
  possible but risky (levels must stay bit-exact).

## E. Words

- "tray", "palette", "Lens", "the own backend" (61 times), "trial" name things that changed;
  some are on screen ("Each section of the tray...", the "Main palette" command).
- Skills name ~20 procs and touch scenarios that no longer exist (sm-ui, lens-layout.md, sm-render,
  sm-touch-testing); sm-build's test-picker count is wrong.
- README describes compatibility shims and history ("...is gone").
- Developer flags only README mentions (~22: timelapse, turntable, bench-tilt, strokes record/replay,
  `--no-pre-rotate`, `--async-compute`, ...): keep the ones used by hand, drop the rest.

## Suggested order

1. A (two PRs: code, then generated shaders + caps + formats) and E's skill/README fixes.
2. Bolt decides C1-C8; build each as its own PR.
3. The GPU abstraction (G0-G7), absorbing B1-B5.
4. B6-B10 and D as touched.

Checked and not findings: the two BVHs (CPU vs GPU layout), simplify/decimate (one builds on the
other), surface nets vs marching cubes, `geom/retopo.odin` (the fallback where AutoRemesher is not
built), every `Command_Id` and `Panel_Kind` value is referenced, `src/uv`'s LSCM code is unused only
because the UV series is in progress.
