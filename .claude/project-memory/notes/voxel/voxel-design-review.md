# Review of `voxel-sculpt-design.md` (sm-architect, read-only)

Date 2026-10-27. Reviewed against branch `claude/project-thread-wp91l3` at `be6c7ba` (the design's own baseline).
Every `path:line` below was opened in this session; `UNVERIFIED` marks what was not. `./build.sh check` was not run:
nothing new was compiled, and the review is of a design, not a diff.

Verdict: the representation, the dab pipeline and the surface-nets layout are sound and fit the house rules. The
app integration is where the design under-states the work: an object whose `levels` is empty crashes in about a
dozen places the design does not list (the frame loop, `brush_stroke_finish`, `history_step`, every exit-stats
loop, `object_put_estimate`, the mesh-only `Scene_Command`s reachable from shortcuts and scripts), and the undo
hook misses `history_drop_redo` and `object_forget_history`. The MUST list in §3a is what makes the design
implementable; §3b is what would make it better.

## 1. Request
Add a second object kind, a sparse bricked `i16` narrow-band SDF in a new package `src/voxel`, sculpted by
Add/Subtract/Smooth/Flatten/Inflate dabs, meshed per 16³ node by surface nets into slotted `geom.Mesh` arrays
drawn through the existing `render.Mesh_Buffers` and `Draw_Item.chunks`, undone per stroke by copy-on-write brick
saves, saved in `.sculpt` under a new `SCENE_VERSION`, and convertible to a mesh object. It is not a change to the
mesh sculptor, not a ray-marched display, not adaptive resolution, and not mesh→voxel import (a follow-up).

## 2. Current state (the design's claims, checked)
| Design claim | Verified | Notes |
|---|---|---|
| `Object{levels, gpu: [MAX_LEVELS]Mesh_Buffers, …}` at `scene.odin:50-70` | yes | `object_level` → `sculpt.levels_active` → `l.levels[l.current]` (`scene.odin:73`, `src/sculpt/hd.odin:104-107`): an empty `levels` is an out-of-bounds read, a panic in debug and garbage under `-no-bounds-check` in release (`build.sh:55`) |
| "206 call sites" of `object_sculptor/object_mesh/object_level` | about right | 155 + 47 + 3 = 205 in 45 of 111 files under `src/app`; the design leaves out 49 `object_dynamic(` calls (`levels_dynamic` reads `l.levels[0]`, `levels.odin:172`), 9 direct `sculpt.levels_current(&obj.levels)` calls (`files.odin:390, 545, 806, 833`, `main.odin:666`, `rebuild.odin:95`, `retopo.odin:44`, `scene.odin:73, 262`) and 92 direct `obj.levels.` reads (most are safe: `current`, `hd.window`, `hd.steps`, `len(levels)`) |
| Strokes `sculpt_frame → stroke_follow → stroke_start/stroke_walk → stroke_dab` (`sculpt_tool.odin:194-760`) | yes | `stroke_start:332-413`, `stroke_dab:737-755`, `spray_dab:701-714` (which calls `stroke_dab`, so one branch covers both) |
| `brush_stroke_finish` records when `sculptor_stroke_end` says so (`history.odin:200-224`) | yes | but lines 216-218 call `sculptor_locked_plane`, `sculptor_grab_end`, `sculptor_cloth_end` on `object_sculptor(obj)` and 221 `adjust_set_stroke` → `object_sculptor` (`adjust_last.odin:144`) before/after the record: all four crash on a voxel object |
| `history_step` takes `can`/`step` over `^sculpt.Sculptor` via `entry_sculptor` (`history.odin:522-584`) | yes (`:522-580`) | `entry_sculptor` returns nil for `e.level >= len(obj.levels.levels)` (`:576-577`), so a voxel entry is silently `continue`d (`:554`); `object_set_level` at `:557` clamps to `len-1 = -1` (`scene.odin:754`) and would reach `levels_set_current` |
| Frame loop per part: `sculptor_flush → level_upload → Draw_Item` (`main.odin:625-690`) | yes, now `:663-722` | `parts := [2]^sculpt.Level{sculpt.levels_current(&obj.levels), …}` at `:666` indexes the empty array before any branch could run |
| `prepare_draws` culls `chunks` sorted by `first_index`; nil `lod`/`hidden`/`chunk_groups` fine (`renderer.odin:979-1052`) | yes (`:979-1040`) | nil `chunk_groups` falls back to `cull_chunks` (`:1015-1019`); `len(item.lod.groups) == 0` turns `simplify` off (`:997`); nil `hidden` is the default. `cull_chunks` merges adjacent ranges, so the sort is required (`visibility.odin:94-114`) |
| `mesh_buffers_create` sizes to the arrays; `upload_ranges` asserts `vertex_capacity`; `upload_indices` asserts `index_count` | yes | `renderer.odin:472-473, 584, 720`; zero-count index ranges are skipped (`:761`) |
| dyntopo draws a slotted layout with zero unused triangles (`dyntopo.odin:19-34`) | yes (`:19-24`) | `level_upload` recreates when `len(positions) > vertex_capacity \|\| len(indices) > index_count` (`scene.odin:491-498`) and then returns without range uploads |
| `object_put_bytes` writes id, name, transforms, boolean, view bits, folder, then `levels_write` (`files.odin:779-795`) | yes (`:779-792`) | `object_put_estimate` (`:798-814`) takes `levels_current` at `:806`; `object_get` (`:824-837`) calls `levels_read` at `:827` and `levels_current` at `:833` |
| `SCENE_VERSION` is 10 | yes | `files.odin:52`; `scene_open` refuses `version > SCENE_VERSION` (`:652`) |
| `src/sdf_trial` dense grid, 16³ chunks, surface nets | yes | `main.odin:16-31, 83-156`; `remesh_chunk` computes the vertex pass one cell below the chunk (`:89-96`), the same −1-layer rule the design adopts |
| `geom.remesh` manifold MC table and ray voxelizer | yes | `remesh.odin:11-31` |
| `object_build_from` at `scene.odin:462` | stale | it is `@(private = "file")` at `scene.odin:885-903`; the conversion must live in `scene.odin` or go through `object_replace_mesh` (`:906-910`, public) |
| `level_upload` at `scene.odin:489-510` | yes | |
| jobs rules | yes | workers are `thread.create`d without an init context (`jobs.odin:39`); a nil pool or `count == 1` runs on the caller (`:68-71`); `parallel_ranges` (`:94-107`) |

Also verified for the review: `levels_destroy` (`levels.odin:87-96`), `levels_sets` (`selection_sets.odin:88`), `levels_sets_clear`
(`:157-162`), `levels_hd_delete` (`hd.odin:94-100`), `levels_drop_quads` (`levels_quads.odin:31-35`), `levels_take_layered` (guards
`len == 0`, `layer_carry.odin:314`) and `levels_layer_count` all work on a zero `Levels`, so `object_release_mesh` (`scene.odin:955-962`)
and `object_free` (`:964-968`) are safe on a voxel object once they also free the voxel part. `sync_levels` reads `l.levels[k]`
(`levels.odin:261`), `levels_write` reads `l.levels[0]` (`levels_file.odin:115`), `levels_subdivide` and `levels_hd_set_steps` read
the top level (`levels.odin:134`, `hd.odin:81`): none may be reached with a voxel object.

## 3. Design

### 3a. MUST change (the design is not implementable as written without these)

**M1. The frame loop branches before `levels_current`.** `main.odin:666` dereferences the empty level array for every
object. The per-object loop needs `if obj.voxel != nil { voxel_frame(...); continue }` ahead of line 666, where
`voxel_frame` does: `clay_flush` → on `regrow`: `WaitForGPUIdle`, `mesh_buffers_destroy`, `mesh_buffers_create(surface.mesh, nil)`,
`viewport_invalidate`, `gpu_regrows += 1` and no range uploads this frame (exactly `scene.odin:491-498`); else
`mesh_buffers_upload_ranges(..., ranges, nil)` then `mesh_buffers_upload_indices(..., mesh.indices[:], indices)`; then the
`Draw_Item{mesh, model, color, material, surface, flat, wireframe, live, chunks = surface.chunks, damage}` with `paint`, `groups`,
`chunk_groups`, `lod`, `hidden` zero. Bytes go to `uploaded`, flush time to `normals_ms` as the design says.

**M2. Freed index slots are zeroed and uploaded.** With `--no-cull` (`main.odin:42, 393`) `prepare_draws` returns at
`renderer.odin:980-985` and `draw_item_triangles` draws the whole `index_count` (`:1159, 1170`); the wireframe pass does the same.
A node slot that was relocated or whose node vanished still holds its old triangles on the GPU unless the CPU zeroes the
freed index range and lists it in `Flush.indices`. The design says unused slots "hold 0" but not that freeing writes zeros and
uploads them. Same rule dyntopo keeps (`dyntopo.odin:21-22`). Test: `--no-cull` dump after a Subtract that empties a node shows no
stray triangles; `clay_to_mesh` must ignore zero slots.

**M3. Undo hook: four branches, not one.** `history_step` must test `object_is_voxel` *before* `entry_sculptor` (`history.odin:553`),
skip `object_set_level` (`:557`) and the hidden-stamp lines (`:558-561`), and pick undo or redo from `from == &app.history.done`
(the pattern at `:539, 548`). `history_drop_redo` (`:477-488`) must call a new `clay_clear_redo` where it calls `sculptor_clear_redo`
(`:483-484`), or a stroke on any other object leaves the voxel object's redo steps orphaned (bytes held, lists out of step with the
History). `object_forget_history` (`:682-689`) needs `clay_clear_history`. `history_record` (`:432`) writes `level = obj.levels.current`
= 0, which is fine. So the voxel undo API is `clay_can_undo`, `clay_undo`, `clay_can_redo`, `clay_redo`, `clay_undo_bytes`,
`clay_clear_redo`, `clay_clear_history`, and `clay_stroke_end` must itself drop its redo list as `sculptor_stroke_end` does
(`undo.odin:146`).

**M4. `brush_stroke_finish` branches before line 216.** `history.odin:216-221` call `sculptor_locked_plane`, `sculptor_grab_end`,
`sculptor_cloth_end` and `adjust_set_stroke` on the sculptor. For a voxel object: set `app.stroke_end.valid = false` (join strokes
read `e.locked` and `stroke_restart` calls `sculptor_lock_plane`, `sculpt_tool.odin:376-385, 382`), call `clay_stroke_end`, record
`.Stroke` if it changed, set `app.adjustable.op = .None`, return. Place the branch after the pivot and `stroke_end` bookkeeping (`:203-211`).

**M5. `stroke_start` branches right after the raycast.** Lines `342, 361, 366` call `object_dynamic` (reads `l.levels[0]`), `357`
`sculptor_stroke_begin(object_sculptor(obj))`. The voxel branch goes after `app.scene.selected = index` (`:340-341`): refuse
Grab/Hook/Cloth/Mask/Paint/History/Morph/Layer/Snake_Hook and Drag_Rect/Line/Roll modes with one `log.warn` at a `.Press`, map the
kind, `clay_stroke_begin`, set `st.active/object/kind/held/seed/pos/...` as lines 348-356 and 363-369 do, then the first `voxel_dab`.
`stroke_dab` (`:737-755`) branches at its top (`:741` and `:752` are sculptor calls); `spray_dab` then needs nothing. `scene_raycast`
(`scene.odin:858`) branches to `clay_raycast` as the design says; so must `scene_raycast_surface` (`cursor.odin:38`, which the cursor
ring uses) and `cursor_update` at `cursor.odin:44` (`sculptor_area_normal`).

**M6. `scene_apply` refuses the mesh-only kinds for a voxel object.** The palette skipping its sections does not stop Ctrl+R, Ctrl+D,
the HD key, the pie or a script: `commands.odin:449, 456, 470, 495, 617, 725` set `.Remesh`, `.Dyntopo`, `.Subdivide`, `.Hd_Enter`
straight into `app.ui.scene_command`, and `commands.odin:456` already calls `object_dynamic(selected_object(app))` while building the
command. Add one guard at the top of the switch in `scene_apply` (`scene.odin:543`): for `.Remesh, .Decimate, .Retopo, .Symmetrize,
.Slice, .Subdivide, .Set_Level, .Delete_Higher, .Delete_Lower, .Hd_*, .Dyntopo, .Boolean, .Extract` on a voxel selection,
`log.warn` + `return true`. `commands.odin:456`'s `object_dynamic` needs the voxel-safe form (see M8). The script runner (`script.odin`)
and `rebuild.odin:95`, `retopo.odin:44` reach the same procs: UNVERIFIED which verbs; the `scene_apply` guard covers the command path,
the deform/clip/smooth-all/hide/mask commands in `history.odin:230-425` need their own `selected_object` guard (they call
`object_sculptor` directly, e.g. `:236, 262, 291, 319`).

**M7. Exit stats and `--check-mesh` branch.** Every run ends through `main.odin:1077-1151`: `object_dynamic` (`:1079, 1108`),
`object_mesh` (`:1080`), `object_sculptor` (`:1102, 1121, 1145, 1148, 1151`). Without branches every smoke run, touch scenario and
scripted run with a voxel object crashes at exit, which would mask every other result. `--check-mesh` on a voxel object should run
`clay_to_mesh` and print its `mesh_report`, as the risk table already assumes. The `--bench-stroke` block (`:1140-1168`) needs a voxel
form or a refusal. Also the startup loop `main.odin:357-368` (`--subdivide`, `--hd`, `--level` with `--voxel`) must skip voxel objects:
`levels_hd_set_steps` reads the top level (`hd.odin:81`).

**M8. Make the accessors fail safely, not only loudly.** The design asserts in `object_level/object_sculptor/object_mesh`. Add
`object_dynamic` returning false and `object_in_hd` false for a voxel object (49 and 35 call sites: most are guards that should
simply read false), and keep the asserts on the three mesh accessors. Then audit the 9 direct `levels_current` calls and the 92
`obj.levels.` reads (list them in the PR with the branch or the reason they cannot be reached). `object_has_mask` (`history.odin:715`),
`object_put_estimate` (`files.odin:806`), `object_export`/`object_export_bytes` (`files.odin:390, 545`), `boolean_live_update`
(`boolean.odin:64, 68, 110-112, 205, 210`) and `autosave_start`'s `levels_sync` (`autosave.odin:362`) are the ones the design's
list misses.

**M9. Files: `object_get`, `object_discard`, `object_put_estimate`, and the autosave abort.** `object_get` (`files.odin:824-837`)
reads the kind byte after `object_get_fields` for `version >= 11`, then `clay_read` + `mesh_buffers_create(surface.mesh, nil)`; a kind
byte above 1 is damage (`r.ok = false`). `object_discard` (`:869-874`) and `object_free` must destroy the voxel `Mesh_Buffers` and
`clay_destroy`. `object_put_estimate` reserves by the brick count (`len(bricks) * 1 KiB + occupied chunks * 4 KiB`). `clay_write` must
take the `Write_Options` (`serial`, `abort`) and check `abort` per chunk, because `autosave_settle` waits for the writer to stop
(`autosave.odin:304-308`) before any change: a 35 MB write that cannot stop is a hitch on the next press (sm-sculpt's rule, and
`levels_file_write_stops_when_asked` is its test). Bump `SCENE_VERSION` to 11 with its comment (`files.odin:52`).

**M10. Band completeness is an invariant, and Inflate/Smooth/Flatten break it.** The seamless-mesh argument needs: wherever a sign
change exists, both voxels of the edge lie in bricks (a brick-less node never owns a crossing). Add's stamp fills its band and the
pre-pass makes bricks where the stamp is near, so Add/Subtract keep it. Inflate (`d' = d − h·w`, up to a voxel a dab) moves values
toward the brick's face while an Empty neighbour tile stays at +CLAMP; after a few dabs the crossing reaches the brick edge and the
next edge's lower voxel may be a tile in a node that has no bricks and so no meshing job: a hole, not a seam. The same for Smooth's
mean and Flatten's fill. The pre-pass rule "skip Empty tiles the operator cannot fill" must be made concrete: a tile within the brush
box whose neighbouring brick has any voxel with |d| < CLAMP − 1 voxel after the dab is made a brick (filled with its tile value) in the
serial pre-pass, before the jobs run; and the research's own step 3 (`voxel-research.md` §5.4: local Eikonal iterations every N dabs)
should run at least on the touched bricks' outer layer every N dabs, not only at stroke end, or a long Inflate stroke corrupts the band
within the stroke. Test: 200 Inflate dabs then `clay_to_mesh` → `boundary_edges == 0`.

**M11. Band repair happens inside the undo step, and deterministically.** `volume_redistance` at `clay_stroke_end` writes bricks (the
halo too): they must be recorded first-touch into the open step, i.e. repair runs before the step is closed, or undo leaves the halo
redistanced (the bit-exact undo test catches it; say the order). The Godunov sweep "in the 8 sweep directions" is Gauss-Seidel: run in
parallel per brick with neighbours read live, the result depends on scheduling. Either run it serially over the region (a few thousand
bricks × 512 voxels: ~1-3 ms at stroke end, acceptable), or do Jacobi rounds (read the pre-round copy, write the brick) so serial ==
parallel; state which, and give it the 3-thread comparison test.

**M12. Convert to mesh is a swap entry and lives where `object_build_from` is reachable.** `Voxel_To_Mesh` replaces the object's kind:
`before := history_snapshot(app, obj, "convert to mesh")`, `WaitForGPUIdle`, destroy the voxel GPU buffers and clay, `object_build_from`
(`scene.odin:885`, file-private: add the case in `scene.odin`), then `history_record_swap`. `history_swap` (`history.odin:586-635`)
works unchanged once `object_put/object_get` know the kind. Without the swap the conversion is not undoable, against AGENTS.md §5.

**M13. The new package goes in both build scripts' lists.** `build.sh:72` (check) and `:65` (test) list packages by name; `build.bat:39-52`
echoes "11 packages" (UNVERIFIED that its loop is a literal list, likely the same). Add `voxel` to check and test, fix the count, add the
Layout row in README (`README.md:9-19`) and sm-lint's import list (`.claude/skills/sm-lint/SKILL.md` §2: "`voxel` imports `geom` and
`jobs`"), then `scripts/agents_sync.py`.

### 3b. SHOULD (improvements, not blockers)

- **S1. Dirty rule, exactly.** A node's window of influence is voxels `[16i − 2, 16i + 17]` per axis (corners `16i−1..16i+16` for
  positions, ±1 for the central differences). A brick `[8j, 8j+8)` therefore dirties its own node and, per axis, the neighbour on the
  side of the node it sits in (the lower brick of the node dirties `i−1`, the upper brick `i+1`): at most 2³ = 8 nodes a brick, never
  27. The design's "nodes up to one step away on each axis" reads as 27 and would triple the meshing work. Write the rule as a table
  and test it with `dirty-only remesh equals full remesh` across a node border.
- **S2. One cell-vertex proc, `#force_no_inline`.** The seam argument is "same position and normal by construction": two nodes compute
  the same −1-layer cell. `levels.odin:393-398` learned that the compiler may inline a shared helper differently per caller; mark
  `cell_vertex` and the gradient helper `#force_no_inline`, and add the seam test (`clay_to_mesh` welds by exact bits; count duplicates
  before the weld equals the border-vertex count after).
- **S3. No compaction during a stroke.** Compaction sets `regrow` → `WaitForGPUIdle` + a full re-upload (`scene.odin:491-498` does
  the same for dyntopo, but rarely). Defer compaction to `clay_stroke_end`, as `sculptor_lod_update` does nothing during a stroke
  (`main.odin:683`); mid-stroke overflow relocates only the overflowing node.
- **S4. Per-job scratch in bounded batches.** A 20³ `i16` window (16 KB) plus an 18³ cell-vertex table (23 KB) per dirty node means a
  1000-node flush pre-sizes ~40 MB. `Job_Proc` has no thread id (`jobs.odin:14`), so run the dirty list in batches of 256 jobs with 256
  scratch slots (~10 MB, kept warm), or accept the memory and say so.
- **S5. Sort the dirty node list** before the meshing `parallel_for` and the serial relocation pass so slot assignment is independent of
  dab order within a frame; the design implies it but the determinism test will only catch it if dabs land out of order.
- **S6. Keep `chunks` in slot order.** `cull_chunks` merges adjacent ranges and needs the sort (`visibility.odin:94-114`); with 35k nodes
  rebuilding and sorting on every relocation is <1 ms, fine, but a per-node `chunk index` lets a bounds change patch in place and the
  sort run only on relocation. Also build `chunk_groups` (`geom.chunk_group`, `visibility.odin:119-135`) once nodes exceed ~4k:
  `prepare_draws` tests every chunk serially (`renderer.odin:1018`), and with `cone_cutoff = 1` nothing back-face culls, so a 4.4M-vertex
  bust draws every triangle: fine for the slice, put a bench row on it.
- **S7. Validate `clay_read` beyond counts.** Voxel size > 0 and finite, origin finite, chunk coordinates inside `MAX_CHUNKS³` and
  unique, tile codes ≤ 2, brick indices < the brick count, and `(len(r.data) − r.at) / 1024 >= bricks` before reading them
  (`levels_read`'s pattern, `levels_file.odin:360`).
- **S8. `read_hash` for `--check-autosave`** (`autosave.odin:584-594`) should hash the bricks too, or a torn voxel autosave is
  never detected.
- **S9. Say where `Scene_Command.voxel` and `Kit.add_voxel` live.** The interface may remember the switch; the resolution mapping
  `voxel_resolution_for` belongs in `voxel` (pure), not in a `kit_*` file.
- **S10. Memory numbers.** 3.9 says "~50 MB of mesh slots" at 1024³; with 25 % slack and 50 % headroom, 1.1M vertices × 24 B (positions
  and normals) + ~6.6M indices × 4 B ≈ 27 + 26 MB before slack, ~80 MB with it, plus the same 16 B/vertex + indices on the GPU. Fine,
  but print it in the exit stats (`voxel_mb=`) and the bench so the estimate is checked.
- **S11. The mesh-space `damage` box must cover before and after** (`renderer.odin:162-165`); a brick box covers both only if the
  previous surface was inside the same bricks, which holds when every touched brick is in the box, including bricks that collapsed
  to tiles this frame.

### 3c. What stands as designed
Package shape and procs (3.1-3.3), the slotted `Surface` reusing `Mesh_Buffers` (3.4; `mesh_buffers_create` uploads the slack
slots as zeros, `upload_ranges` takes `nil` mask, `upload_indices` asserts inside `index_count`, all verified above), COW brick undo
as its own inverse (3.5, the shape of `step_move`, `undo.odin:249-256`), the file layout with a tag and a version inside the object
(3.6, as `LEVELS_TAG`), the conversion (3.7) with M12, threading rules (3.9: directory mutated only in serial passes, jobs write disjoint
bricks or slots, scratch owned by `Clay` and grown before dispatch, heap allocator for anything made inside a job: all consistent with
`jobs.odin:39, 66-71` and sm-odin's trap row). Fixed point: `CLAMP = 16384` fits `i16`, a 27-voxel sum fits `i32`. Add's stamp
geometry (`R = (r² + h²)/2h`, centre `hit − n(R − h)`) gives a cap of height `h` over a footprint of radius `r`, correct; Subtract is its
mirror. Flatten's `max(d, d_plane)` clips and `min(d, max(−d_plane, d_sphere))` fills within the brush, correct.

## 4. Boundary check
- `voxel → geom, jobs`: the same edges `sculpt` has (`src/sculpt/undo.odin:6-7`); allowed by the Layout table (README `:11, :16`).
  Add the row to sm-lint §2 (M13).
- `app → voxel`: `app` already imports every package; fine.
- `bench → voxel`: `bench` imports `camera, geom, jobs, sculpt` (`src/bench/main.odin:39-42`), never `render` or `app`; adding `voxel`
  keeps that.
- `render` unchanged: `Mesh_Buffers`, `Draw_Item`, `mesh_buffers_upload_ranges/indices` are used as they are (`renderer.odin:78-114,
  142-173, 559, 716`). No new GPU buffer layout, no shader.
- `ui` untouched; the switch and the Voxels section are `kit_*` files in `app`.
- `sdf_trial` stays alone; nothing is imported from it (the spike's `remesh_chunk` is copied in spirit, not in code).

## 5. Alternatives rejected (agreeing with the design, one addition)
- Dense grid: 512 MB at 512³ (`sm-sdf` numbers table); memory, not time, rules it out.
- VDB tree or octree: no production brush sculptor uses adaptive resolution; the fixed `MAX_CHUNKS³` table with the "clamp and warn"
  rule is a bounded domain where the research proposed a hash map (`voxel-research.md` §5.1); acceptable for the slice, and `Res−`
  is the stated way out. Say so in §5 of the design.
- A separate `Voxel_Buffers` in `render`: would duplicate the transfer-buffer batching and the indirect draws for nothing; the slotted
  mesh is what dyntopo already draws.

## 6. Risks
| Risk | Invariant threatened | Catches it |
|---|---|---|
| A mesh-only path reached with a voxel object (M1, M4-M8) | `object_level` has a level | the asserts in debug; the audit list in the PR; every touch scenario and the smoke run with `--voxel=256` (they exit through `main.odin:1077-1151`, so the exit stats must be branched first or every run fails there) |
| Redo lists drift from the History (M3) | undo/redo on every object stays consistent with `History` | app test: voxel stroke, undo, stroke on a mesh object, `clay_undo_bytes` drops to the done steps only; `clay_can_redo == false` |
| Holes at the band's edge after Inflate/Smooth (M10) | both voxels of every crossing lie in bricks | test: 200 Inflate dabs → `clay_to_mesh` → `mesh_check.boundary_edges == 0`; `--check-mesh` line |
| Halo redistanced but not saved; nondeterministic sweep (M11) | a step is its own inverse; serial == parallel | undo bit-exact test with repair on; 3-thread comparison of `volume_redistance` |
| Stale triangles in freed slots under `--no-cull` or wireframe (M2) | every index slot not owned by a node is (0,0,0) | `--no-cull --dump-viewport` after a Subtract that empties a node; `clay_to_mesh` ignores zero slots |
| Conversion not undoable (M12) | every user action is a History entry | app test: convert, undo → `obj.voxel != nil` |
| Compaction mid-stroke (S3) | frame time under a stroke | bench "Frame ms max" at radius 64; `gpu_regrows` in the exit stats |
| Dirty set too wide or too narrow (S1) | the shown surface equals a full remesh | `dirty-only remesh equals full remesh` with strokes across node borders, bit for bit |
| Seam between nodes (S2) | duplicated border vertices are bit-identical | `clay_to_mesh` weld count == border vertex count; `boundary_edges == 0` |
| 10M scale: 4.4M vertices, 35k chunks, no back-face culling | frame time | bench rows at 256/512/1024, `cull_ms`, `last_frame_triangles` in the exit stats; `chunk_groups` when it shows |
| Autosave cannot stop (M9) | a press never waits for the writer | `autosave.wait_ms` in the stats; a `clay_write_stops_when_asked` test |
| Damaged `.sculpt` (S7) | a damaged file is refused, never asserted on | tests: every count out of range, a short read, a bad tile code |
| GPU buffer freed in flight | `WaitForGPUIdle` before destroy | `build.bat smoke` with `--voxel` |

## 7. Plan (the design's steps, with the evidence rung each must show)
1. `src/voxel` volume, directory, sphere, sample, gradient, raycast. Evidence: `check`; tests for the sphere radius error and
   raycast vs analytic; add `voxel` to the build lists first (M13) so `check` runs it.
2. Brushes and the dab pipeline, with the tile-dilation rule (M10) and the periodic band pass. Evidence: tests for volume sign,
   serial == parallel with `jobs.pool_init(&pool, 3)`, domain clamp, band completeness after 200 Inflate dabs.
3. Surface nets into slots, flush, chunks, `clay_to_mesh`, zeroing freed slots (M2), `#force_no_inline` helpers (S2), exact dirty rule
   (S1). Evidence: tests closed-after-weld, Euler characteristic, seam count, dirty-only == full remesh, serial == parallel meshing.
4. Undo (with `clear_redo`/`clear_history`), band repair ordered inside the step (M11), files with `Write_Options` and validation
   (M9, S7). Evidence: undo bit-exact with repair on, redo, round trip, damaged bytes refused, write stops when asked.
5. `bench --voxel` at 256/512/1024, 1 and 4 threads. Evidence: the markdown table beside the dense spike's and the mesh bench's rows.
6. App (own PR, likely over ~700 lines once M1-M8 are in): the kind, `--voxel`, Add switch, frame loop, raycasts, strokes, undo hooks,
   `scene_apply` guard, exit stats, files v11, palette section, README, touch scenario, the accessor audit list. Evidence: `check`,
   `test` (app tests for M3 and M12), `smoke --voxel=256`, a `--dump-viewport` PNG described, `--check-mesh` line, the exit stats
   `voxel_*=`, `scripts/touch_check.py voxel_sphere_sculpts`.
7. Follow-ups as listed, plus `chunk_groups` for voxel nodes and `read_hash` for bricks.

## 8. Open questions (defaults I would take)
- Band repair cadence: every 16 dabs on the touched bricks' outer layer plus the full regional sweep at stroke end (research §5.4);
  default on, the A/B flag kept for the bench.
- `cone_cutoff = 1` for every node in the slice: yes; normal cones from the gradient are a follow-up once the bench shows the draw cost.
- Compaction threshold: holes above half the arrays, at stroke end only (S3).
- Where the domain clamp warns: once per stroke through `log.warn`, and once in the Voxels section as a line, since a log line is
  invisible on the tablet.
- Autosave `--check-autosave`: hash the bricks (S8) from day one; it is a few lines.
