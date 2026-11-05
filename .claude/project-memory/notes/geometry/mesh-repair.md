# Gap list 14b: mesh repair (design as built)

Goal: ZBrush's Geometry > Modify Topology and Mesh Integrity, combined with Blender's Clean Up
(Fill Holes, Merge by Distance, Recalculate Outside) and Meshmixer's Inspector. It lives in
Object > Shape, in the section that was "Mirror and weld", now "Modify topology".

## What the person sees
- In sight: the axis tabs, Keep the - side, Mirror and weld, Close holes and Delete hidden.
- Under More: Leave the largest hole, Delete half, Weld distance (logarithmic, 0.001 % to 1 % of
  the object's size) with Weld points, then Check mesh and Fix mesh.
- Each repair reports what it did, with Undo. Check mesh only reports.

## Choices (best of each)
- **Close holes.** Caps follow a bent border, which Meshmixer does and ZBrush does not. Each cap
  gets its own polygroup, which ZBrush does and Blender does not. Polypaint carries over to the
  cap. Leave the largest is ZBrush's Close Holes option, done as a switch.
- **Weld points.** Takes Blender's distance, with ZBrush's exact weld as the 0 case. Fins (two
  triangles over the same corners, facing opposite ways) are dropped, which neither app does.
- **Fix mesh.** Covers Blender's Recalculate Outside, Delete Loose and Degenerate Dissolve in one
  button. It never moves a vertex.
- **Check mesh.** Reports ZBrush's Check Mesh Integrity counts and Blender's 3D-print checks
  together. Hole and piece counts come from Meshmixer's Inspector.

## Code
- `geom/repair.odin`:
  - `mesh_close_holes`, `mesh_weld_points`, `mesh_fix` and `mesh_integrity`.
  - Each returns a `Repair_Map`: `vertex_from`, plus `tri_from` with `REPAIR_NEW + k` for cap k.
- `app/repair.odin`:
  - `Scene_Command.Repair` with a `Repair_Kind`.
  - `object_repair` follows the `object_knife` path, plus `object_rebuild(..., surface)`.
  - `repair_surface` carries polypaint and polygroups.
- Delete hidden is `object_split(.Hidden, keep_parts = false)`.

## Found by running it
- A border left by Delete hidden zigzags. Ear clipping then covered some border triangles with
  fins.
  - Fix: back-facing spikes are trimmed before capping.
  - Any fins left over are dropped with `mark_duplicates`.
- Check mesh took 8.9 s at 5M vertices with mesh_check's sort. It now counts in parallel from
  each vertex's triangles: 1.1 s, with the same counts (tested).
