# PR 5a design: Remesh gaps (holes closed first, Smooth, Keep detail, Groups)

Part of the Remesh / Quad Remesh roadmap (report https://claude.ai/artifact/Y7oLGn8QV2MmegNP2uYWgV, section 8, PR 5a).
Bolt approved the roadmap 2026-10-30 07:09. PR 5b (the dual quads mesher) and PR 6 (corpus script + bench) follow.

## What exists when it is done
Remesh (Rebuild's Even goal, Ctrl+R, the shelf's Remesh and its quick menu, `remesh` in scripts) gains three options kept
in `Scene_Command` so Adjust last and macros replay them: **Smooth** (relax rounds 0–8, 3 as today), **Keep detail**
(the result projected back onto the old surface within one cell, and the old polypaint and polygroups carried through the
nearest old triangle, as Blender's voxel remesh preserves attributes), and **Groups** (each polygroup remeshed as a closed
piece of its own, as DynaMesh's Groups does; the result's triangles keep their group). Independently of the options, an open
mesh is **closed first**: every hole capped (`mesh_close_holes`) before the rays, so a bowl becomes a solid whichever way it
faces, and the result line says "N holes closed first". The Rebuild panel says what the lattice cannot do: no adaptivity
(Decimate is the adaptive step) and gaps narrower than a cell merge, wider ones stay.

## The bug (reproduced 2026-10-30, throw-away geom test)
`remesh_voxel` decides inside/outside from the x rays alone: a ray's winding is +1 behind a sheet it crosses once and
stays so to the lattice's edge, where marching cubes stops, so the surface is open there. Which open parts break depends on
their orientation: a square sheet facing −x gave 39 boundary and 37 non-manifold edges, a bowl opening to +x 58 and 178;
the same sheet facing +x or y or z vanished (zero volume) and bowls opening the other ways were filled, by luck. The merged
Female export (3,465 non-manifold edges after Remesh at 500k) is the same defect at scale.

## Design
### geom (`src/geom/remesh.odin`)
- `Remesh_Options :: struct {smooth: int, keep_detail: bool, groups: []u16}` with `REMESH_OPTIONS_DEFAULT :: {smooth = 3}`,
  `REMESH_SMOOTH_MAX :: 8`; `groups` is per triangle of the input (nil: whole). `Remesh_Report :: struct {holes_closed,
  pieces, dropped: int, groups: []u16, source_tris: []u32}`: `groups` per output triangle (only with `options.groups`),
  `source_tris` per output vertex (only with `keep_detail`: the old triangle its projection hit, `max(u32)` for none),
  both in the caller's allocator.
- `remesh_voxel_measured(..., options := REMESH_OPTIONS_DEFAULT, report: ^Remesh_Report = nil)` keeps its callers
  (Close first in retopo.odin, the long job, object_remesh, bench, voxel conversion) unchanged.
- **Closed first**: `mesh_edges_paired(m, pool) -> bool`: a wrapping u64 sum over every directed edge of `mix(a, b) −
  mix(b, a)`, in fixed ranges added in order, zero exactly when every edge appears once each way (a false "paired" needs a
  2⁻⁶⁴ collision and only means today's behaviour). ~1 ms per million triangles, no memory, so the common closed mesh pays
  nothing. When it is not paired, `mesh_close_holes(m, leave_largest = false)` runs and the capped mesh goes to the rays;
  `holes_closed` is reported. A mesh it cannot cap (no hole loop, e.g. only non-manifold edges) remeshes as today.
- **Smooth**: `remesh_run` takes `smooth` and `relax` runs that many rounds (the final no-move pass still computes normals).
- **Keep detail**: after relax, `bvh_build_morton(source)` and `project_along_normals` with reach = one cell `h`, both ways,
  onto the *original* mesh (not the capped one, so a cap's vertices stay where the lattice put them); the hit triangles go to
  `report.source_tris`. Takes the last tenth of the progress share.
- **Groups**: group ids made dense in ascending order (deterministic), `mesh_split`, each piece through the same closed-first
  and rays on the *same lattice* (same `h` and `bounds`, so neighbouring pieces meet on shared lattice points), joined with
  `mesh_join`; `report.groups[t]` is the piece's group id; a piece thinner than a cell gives nothing and is counted in
  `dropped`. Progress is split evenly across pieces. Keep detail runs once over the joined mesh.
- Tests: sheet (both orientations, three axes) and bowl (both ways) closed and manifold, bowl volume ≥ 85 % of the ball;
  smooth 0 and 8 closed, edge spread p99/median falls with rounds; two-group sphere gives two closed pieces with both ids;
  keep detail halves the deviation on a bumpy sphere; ten remeshes in a row at one density stay within 1 % in count and
  volume (the report's "Done when").

### app
- `Remesh_Setup :: struct {smooth: int, keep_detail, groups: bool}` (scene.odin), `remesh_setup(app)` from
  `app.ui.remesh_smooth` (i32, default 3), `remesh_keep_detail`, `remesh_groups`; `Scene_Command.remesh: Remesh_Setup`; every
  issuer (`commands.odin` Remesh and Remesh_To, `rebuild_command`, `lens_tools`, the quick menu, `adjust_post`, `gpubench`)
  passes it; `adjust_open` restores the panel from the command. Settings rows `remesh_smooth` (0–8), `remesh_keep_detail`,
  `remesh_groups`; macro lists EVEN gain them.
- `object_remesh(app, obj, vertices, setup)` and the long job build the geom options: `groups` from the current level's
  `sculptor_groups` when `setup.groups` (none under dynamic topology), and after the remesh make a `Surface` for
  `object_rebuild`: colours per new vertex from the hit triangle's corners weighted by barycentrics (`bvh`-free: the point
  lies on the triangle, so the weights come from areas), groups per new triangle from the pieces (Groups) or else from the
  first corner's hit triangle (Keep detail). The long job copies the colours and groups with the input on the frame thread
  and `long_job_prepare` calls `levels_init` with the renumbering maps and `levels_take_surface` on its thread.
- The result line: "Remeshed Sphere 1: 101,230 vertices (312 ms); 2 holes closed first; 3 pieces, 1 too thin; detail kept".
- Rebuild's Even goal: a Smooth slider, Keep detail and Groups switches (Groups disabled with its reason when the object has
  no polygroups), and the paragraph gains "No adaptivity: Decimate after; gaps narrower than a cell merge."
- README's Voxel remesh section and the scripts line (`set remesh_smooth 5`, `set remesh_keep_detail on`,
  `set remesh_groups on`); the `sm-cad` skill's remesh note.

## Out of scope
Thickness for sheets (DynaMesh's Thickness), partial remesh of the edited area, the dual quads mesher (5b), reprojection
without Keep detail.

## Risks
- `mesh_close_holes` on a huge open mesh (the Female export's 5,392 islands with 33,724 border edges) is serial per loop;
  it is what Close holes already does on the same mesh, and it runs on the long job's thread.
- Keep detail builds a BVH of the old mesh (a 10M source is ~1 s and a few hundred MB); it is off by default.
- Groups on an object with hundreds of groups runs the lattice once per group; each pass only visits its piece's cells, so the
  total is about one remesh plus the per-pass lattice setup.

## Review and as built (2026-10-30)
The architect's review (Revise) was taken in full: a cap's membrane vertices are clamped into the measured box before the
rays (they could leave it and index the lattice out of bounds); each group piece is remeshed in its own box with its low
corner snapped onto the whole mesh's lattice (shared lattice points, no whole-box ray heads per piece); seams between
pieces are not counted as holes; `object_build_from` keeps the group materials when prepared levels carry groups, so the
long job and the at-once path agree; the `mesh_edges_paired` comment says "pair off" (a doubled triangle pairs) and a test
pins it; a serial-versus-pool bit-identity test covers an open fixture, eight rounds with Keep detail, and three groups
with Keep detail. Added beyond the note: a mesh inside out as a whole (its signed volume negative, `mesh_signed_volume`
in fixed ranges) is turned outward first, as the report's input policy asked, with "turned outward first" in the result
line (a hollow mesh keeps its cavity, since only the whole's sign is read); the result line's note is built after the
rebuild, which frees the temp memory; the three option rows sit under Rebuild's More options, which keeps the section to
five controls (the kit test). Scripted runs: an inside-out open bowl OBJ remeshes closed ("turned outward first; 1 hole
closed first", `mesh_closed=true`, picture `pr5a_bowl.png`); a painted sphere keeps its colour through Keep detail both at
once and through the long job's thread (`pr5a_keep_detail.png`); two merged spheres grouped by piece remesh as "2 pieces"
(`pr5a_groups.png`). The shelf touch scenario `mesh_tools_on_the_shelf` was rewritten for the Quad Remesh tile's tap
(runs, a new object) and long press (its section), which #358 changed; it could not run here (no X11 in this container).
