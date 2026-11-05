# Material per polygroup (roadmap 2.5): design

## What exists after
- An object with polygroups can give any of its groups its own material (a classic or physically based preset, or Custom values), up to 15 groups an object. Every other group keeps the object's material. For hard-surface work: gold trim on a steel plate, a rubber grip on a chrome handle, in one object.
- Scene > Material gains, when the selected object has polygroups, a target choice: Object | Group.
  - Object: the section as today.
  - Group: "Pick a group" (a one-shot pick: the next tap or click on the selected object chooses the group under it; Escape or a tap on empty space cancels). The section then names the group ("Group 7", with its polygroup colour chip) and the preset select and colour picker edit that group's material. Under More: Metallic, Roughness and "Use the object's material" (removes the group's own one).
  - MatCap presets are not offered for a group (one MatCap sampler a draw); the object itself can still be a MatCap, and its groups' own materials are lit as usual.
- The viewport, Studio render, thumbnails, screenshots and the time-lapse show group materials. Show polygroups still shows group colours instead of everything.
- glTF export writes one primitive per material used (the object's plus each group's), each with its own material. USD writes a GeomSubset per group material (familyName "materialBind") bound to its own UsdPreviewSurface, the mesh keeping the object's material. Both checked with `scripts/export_check.py` and Blender.
- `.sculpt` scenes keep them (SCENE_VERSION 15); older scenes open with none.
- Script: `group_material N` gives the current material (what `set material NAME` chose) to group N of the selected objects; `group_material_clear N` removes it.

## Data (app)
- `Object.group_materials: [dynamic]Group_Material` with `Group_Material{group: u16, material: Material}`; at most `GROUP_MATERIALS_MAX :: 15`, groups unique, kept sorted by group so the order is deterministic.
- Keyed by group number, per object (not per level): levels carry group numbers between each other (levels_carry_groups), so one table serves every level.
- Kept by number whatever the groups do: Group visible and Group masked take a fresh number (groups_next is max + 1), so existing assignments stay put. Groups by creases and Clear groups renumber from 0, so an assignment may then land on another part; the user re-picks. This keeps undo consistent without making materials History steps (as with object materials, they are outside Undo, like ZBrush's): undoing a group command brings the old numbers back and their materials with them.
- Dropped when the groups are dropped for good: a topology rebuild (`object_remesh` and everything that copies it: remesh, decimate, rebuild, retopology, booleans' result, mirror and weld), and turning dynamic topology on (sculptor_dyn_enable drops groups). The History swap entry snapshots `object_put`, so undoing the rebuild brings the table back with the old mesh.
- Objects made from another (duplicate, slice, extract, split) copy the table where the groups are copied (duplicate, slice halves) and start without one otherwise.
- A Scene_Command kind `.Group_Material{object id, group, material, clear: bool}` applies panel edits at the start of the next frame, to the selected object only (groups are per object, so a multi-selection would mean different parts). It bumps `scene_edits`.

## GPU (render)
- Each vertex already carries one group to the GPU (the low 16 bits of `paint[v].y`, the corner each triangle is drawn from carrying the triangle's own group). Add, per object, a small table group -> slot:
  - `render.Material_Table{buffer, transfer: ^sdl.GPUBuffer..., groups: u32, stamp: u64}` owned by the Object (released with the object, after the WaitForGPUIdle every buffer free already has), created and re-uploaded by `material_table_upload(r, cmd, t, slots: []u8)` when the assignment changes (a stamp the app bumps). One byte a group up to the highest assigned group + 1, packed four to a u32; tiny (64 KB at worst for group 65535).
  - The mesh pipelines get a second vertex storage buffer (set 0, binding 1), always bound: the object's table or `r.no_table` (one zero word).
  - `Draw_Item` gains `slots: ^Material_Table` (nil for none) and `slot_materials: ^[GROUP_SLOTS]Slot_Material` (16 entries; entry 0 unused). `Slot_Material{base_color, params, surface: [4]f32}` mirrors the three Material_Uniforms fields that differ between materials. Draw_Item stays small; the app keeps the array in the object.
  - mesh.vert: when `options.z > 0.5` (the item has a table and the mesh has its paint buffer), `slot = (table[g >> 2] >> ((g & 3) * 8)) & 0xff` for the carried group `g` (0 past the table's end) -> `layout(location = 6) flat out uint out_slot`.
  - mesh.frag: a second fragment uniform buffer (set 3, binding 1) `Slot_Uniforms{vec4 base[16], params[16], surface[16]}` (768 bytes), pushed per item only when it has slots (a zero block once a pass otherwise, since SDL_GPU wants every declared slot pushed before a draw). `in_slot > 0` swaps base_color, params and surface before anything reads them; everything after (paint over the albedo, cavity, exposure, tone map, the MatCap path for slot 0 only) is unchanged.
  - Frame and static keys hash the table's identity and stamp and the 16 slot materials, so the idle cache and partial redraw invalidate on their own.
  - Cost: one storage read per vertex and one flat varying, only for items with a table; one branch per fragment. A/B with `build.bat bench`/`gpubench` rows before and after at 1M and 10M.
- Known limit, shared with group colours today: groupings where some triangle has no corner carrying its own group draw that triangle in a neighbour's material (groups_refresh makes this rare). Documented in README.
- HD windows: the HD mesh carries no groups, so an HD window draws in the object's material (as it shows no group colours today).
- Dim the others: each slot's colour takes its material's `idle` the way the object's does (object_draw_tint per slot).

## File (object_put / object_get, version >= 15)
- After the object's material: u16 count, then per entry u16 group and `material_put`.
- Reading checks count <= 15, groups strictly increasing, each material valid and not a MatCap; anything else makes `r.ok = false` (a damaged file is refused). Versions before 15 read none.

## Export (geom)
- `Mesh_Export.materials: []Export_Material` (entry 0 the object's) and `tri_material: []u8` (per triangle, the entry; nil for all 0).
- glTF: one primitive per entry used, each with its own index accessor over the shared attribute accessors; materials in entry order. Painted objects compose paint over each vertex's carried-group base, as the viewport does, with `base = 1` per primitive.
- USD: per entry > 0 used, `def GeomSubset "Mat_N" (prepend apiSchemas = ["MaterialBindingAPI"]) { uniform token elementType = "face"; uniform token familyName = "materialBind"; int[] indices = [...]; rel material:binding = </Root/Mat_N> }`, faces in ascending order.

## Tests
- Table packing: groups -> bytes -> words, past-the-end reads 0.
- File round trip; damaged tables refused (too many, duplicates, a MatCap, out of order); a version 14 scene reads none.
- Scene_Command applies to the selected object only; remesh drops the table; undo of the remesh brings it back.
- glb and usda carry primitives/subsets with the right triangle counts and materials (geom tests), plus `export_check.py` through Blender by hand.
- kit_more_test: Material still shows at most five folded, both targets.
- A dump: a sphere with two crease groups, one steel, one gold; partial vs `--no-partial` 0 px, MSAA on.

## Open questions for review
1. Keep by number vs drop on Creases/Clear (chosen: keep, see Data).
2. A per-object table in a second vertex storage buffer vs folding the slot into the spare 16 bits of `paint[v].y` (rejected: a reassignment would re-upload 8 bytes a vertex, 80 MB at 10M, and roadmap 3.4 wants those bits for roughness and metal paint).
3. Selected object only vs every selected object for group edits (chosen: selected only).

## Review (sm-architect): approved with changes, all taken
1. No per-object GPU table: `Frame_Uniforms` gains `uvec4 slot_group[4]` (slot k's group, 0xffffffff for none); mesh.vert finds the slot with four `equal()` tests on the carried group, only when `options.z`. No new buffer, no binding change for thumbs or the nav head. The 15-group limit follows from it.
2. Mesh pipelines declare `num_uniform_buffers = 2` on the fragment shader; slot materials are pushed to index 1 only for items with slots (the shader reads the block only behind `in_slot > 0`).
3. mesh.frag swaps after the wireframe's `params.y < 0` return, swaps only `surface.xy` (flat stays the item's) and sets `surface.w = 0` for slots, so a MatCap object's groups are lit.
4. Frame and static keys hash the slot block's contents (groups and materials), with the size asserts updated.
5. Thumbnails stay in `THUMB_COLOR` (they show no materials today); out of scope.
6. `object_draw_tint` is factored into a tint for any Material so each slot dims like the object; the HD window and the boolean preview get no slots.
7. Renumbering: after a group command that changed groups, the table is remapped. Creases moves each entry to the new group holding most of its old triangles (triangle order, deterministic); Clear drops entries whose group is gone; Visible and Masked drop any entry for the fresh number. The table before and after rides on the History entry so undo puts it back; assignment edits stay outside undo. Group 0 is not assignable (it is the object's own).
8. Copies: slice carries no groups, so no table; split filters the table per piece (Split by groups: a piece whose group had a material takes it as its object material); merge remaps each source's entries through its group offset and gives later sources' groups their object material, up to 15 (a warning past that). Duplicate, copy, paste and swap undo go through object_put. One rule clears the table: `object_build_from` when the surface has no groups, and dynamic topology turning on.
9. Scene_Command stays flat: `group: u16` added, `id`, `material` and `on` (clear) reused; the kind is mesh-only; the table changes only after `autosave_settle` (the autosave thread reads it). The script command refuses a MatCap material with a note.
10. File: at most 15 entries, groups strictly increasing and not 0, a non-nil label, no MatCap, none on a voxel object; groups need not exist (stale entries are legal).
11. glTF: every primitive lists the morph targets; when painted with more than one material, seam vertices are duplicated deterministically so each primitive's COLOR_0 carries its own base.
12. USD: per written face (quads on a retopologized base level); painted subsets get the Paint primvar reader.
13. README limits: HD windows draw the object's material; simplified copies may break up group borders while the view moves.
