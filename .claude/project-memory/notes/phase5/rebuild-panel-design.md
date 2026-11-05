# Phase 5 item 6: Rebuild panel with a density checkerboard preview

Roadmap row: "Rebuild panel with density checkerboard preview" (P13, N007), done when "Preview cost < 1 ms". The IA
(08 section 3) puts Remesh, Decimate and Retopology under Object > Shape > Rebuild: "one panel, three goals: Even,
Fewer, Quads; density preview". Findings #19, #47, #65 and #67 say that today remesh size is picked blind, as a vertex
count from a list of presets (41k, 500k, 1M, 5M, 10M, 25M).

## What exists
- Shape > "Remesh and decimate" (`kit_remesh`) offers a preset select and two buttons, Remesh_To and Decimate_To, which
  take the preset index. Ctrl+R remeshes at the object's own count.
- Build > "Retopology and baking" (`kit_retopo_section`) has a Quads count slider (`kit_count`, logarithmic, 100 to 1M),
  the Retopologize button, and the bake controls.
- `geom.remesh_voxel(m, target)` uses spacing `h = max(sqrt(1.5 A / target), max_extent / (REMESH_MAX_LATTICE - 4))`
  and lattice origin `bounds.lo - 1.5 h`.
- The mesh shader has no mesh-space position. `Draw_Item` carries flat and wireframe, and both frame keys (partial
  redraw and the idle cache) hash them.

## Design
### Panel
- The Shape page's "Remesh and decimate" section becomes **Rebuild** (same `Kit_Section.Remesh`, so its fold state is
  kept).
  - Goal tabs: **Even** (voxel remesh), **Fewer** (decimate), **Quads** (retopologize).
  - A **Density** slider (`kit_count`, logarithmic) per goal, stored in `app.ui`:
    - Even, `rebuild_even`: 1k to 25M, default 500k.
    - Fewer, `rebuild_fewer`: 1k to 25M, default 100k.
    - Quads: the existing `retopo_quads`, 100 to 1M.
  - Each goal's line says what it will make, for example "About 480k vertices in cells 0.012 wide" for Even.
  - The Apply button is named for its goal (Remesh, Decimate or Retopologize) and posts the existing Scene_Command
    (`.Remesh`/`.Decimate` with `vertices`, `.Retopo` with quads). There is no new Scene_Command kind, and History is
    untouched.
  - The last result for the goal's section shows under the button.
- Build's section becomes "UVs and baking": the bake controls only, now that Retopologize lives in Rebuild.
- The Remesh_To and Decimate_To commands, which run a preset, stay for the palette, pies and keys.
- Settings remembers the goal and the two counts (`rebuild_goal`, `rebuild_even`, `rebuild_fewer`).

### Checkerboard preview
- It shows on the selected object while the Density slider is held, and for 1.5 s after it is let go (on the UI clock,
  so tests are deterministic). With a mouse it also shows while the pointer is over the slider.
  - Even: a 3D checker of exactly the remesh's lattice, with the same `h` and origin, so each square is one cell of the
    voxel grid. Each cell becomes about one vertex of the result.
  - Quads: a checker of side `sqrt(A / quads)`, the mean quad size.
  - Fewer: no checker. Decimation is dense where the detail is and sparse where the surface is flat, so a single size
    would mislead. The line under the slider says so.
- The lattice comes from one geom proc: `geom.remesh_lattice(area, bounds, target) -> (h, origin)`.
  `remesh_voxel` is refactored to call it, and a test checks that the preview's lattice equals the one the remesh
  uses.
- Area and bounds: `geom.mesh_area_bounds(m, pool)` runs as parallel ranges summed in range order, so it is
  deterministic. It skips zeroed (unused dynamic topology) triangle slots.
  - The result is cached in `app.rebuild` and keyed by object id, level and mesh buffer version.
  - It is computed only when the preview first needs it. The per-frame cost after that is O(1): a few floats into
    the draw item.
  - The one-time cost is measured at 1M and 10M and reported as the `rebuild_area_ms` stat.
- Rendering:
  - `Draw_Item.checker: [4]f32` holds the origin (xyz) and the cell size (w); 0 means off.
  - It is added to both frame keys, so a change redraws in full. Live items are never cached.
  - `Material_Uniforms` gains `checker`.
  - `mesh.vert` passes the mesh-space position (location 5).
  - `mesh.frag`: if `checker.w > 0`, the parity of `floor((p - origin) / cell)` summed over x, y and z darkens odd
    cells by 25% with a thin, darker line at the cell edges. Where a cell is under about 3 px (`fwidth`), the pattern
    fades to its mean so it does not shimmer. The label still states the size.
  - The cost is a few ALU instructions, behind a uniform branch, and only on the selected object while previewing.
    The shadow and studio shaders are unchanged, so the studio render never shows the checker.
- Stats:
  - `rebuild_goal`
  - `rebuild_preview` (0 or 1)
  - `rebuild_cell` (the cell size)
  - `rebuild_area_ms` (the last area computation)

### Tests
- geom: `remesh_lattice` matches `remesh_voxel`'s spacing (via an exported `remesh_voxel_lattice` for the mesh) on a
  sphere and on a long box that hits the REMESH_MAX_LATTICE clamp. `mesh_area_bounds` gives the same result serial and
  parallel, and ignores zeroed triangles.
- app: the preview shows while held, stays 1.5 s after release, never for Fewer, and is cached per version.
- Touch scenarios (desktop simulation):
  - Dragging Density shows `rebuild_preview=1`, with the expected cell for the target.
  - Rebuild > Even > Apply remeshes to about the count. The mesh is bit-identical to `--remesh` at that count.
  - The Quads goal runs Retopologize.
  - Fewer runs Decimate.
- PNG: a sphere with the Even checker at 2k, and the same at 50k.

## Out of scope
- A preview in the Adjust popover, which keeps its preset tabs.
- Dynamic topology density.
- "Keep sharp edges".

## Review (sm-architect) and what changed
Verdict: approve with changes. All six required changes were applied.
1. HD: the preview measures `levels_current(...).mesh`, not the HD window, matching what object_remesh remeshes.
2. Exact by construction: `remesh_run` takes the triangle box. `remesh_voxel`, `remesh_voxel_measured`, booleans and
   `remesh_spacing` all go through `mesh_area_bounds` + `remesh_lattice`. `object_remesh` measures the uncompacted level
   before compacting. It measures afresh rather than reading the preview's cache, because an adjust undoes and
   remeshes within one frame, before the buffers' version moves.
3. The checker is off in studio renders, time-lapses and live boolean previews.
4. `adjust_open` and the popover's size tabs keep `rebuild_even` and `rebuild_fewer` in step.
5. Cost, measured on the VM (4 cores, llvmpipe):
   - gpubench at 1M with and without the preview: within noise (orbit 34.3 vs 33.8 ms GPU on the software
     rasterizer).
   - Dragging Density redraws the selected object in full each frame, like an orbit frame; on Bolt's RTX that is
     about 0.5 ms at 10M.
6. The first measurement was 61 ms at 10M (release) as one pass, so it is now spread over frames: `mesh_area_parts`,
   a batch of 4 ranges at a time within a 1 ms budget. At 10M that is about 87 ms in all, with the longest frame
   1.9–2.7 ms (VM scheduling noise). The checker shows once the measurement is complete.

Also taken from the optional suggestions: "Retopologize (new object)", and the lattice-limit note under Density.
Also fixed: the panel keeps a fixed paragraph plus one variable line, so the Apply button no longer moves while
Density is held.
