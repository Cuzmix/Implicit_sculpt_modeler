# Model mode: design note for the architect review

Plan approved by Bolt 2026-10-28: https://claude.ai/artifact/FbiAiDoT6wX8dyrMjJYUjx (10 phases).
This note fixes the architecture that every phase builds on. Phases 1 and 2 are specified in detail;
later phases only say where they plug in.

## 1. What exists

- `geom.Mesh` is triangles only. OBJ polygons are fanned on import. Retopology quads live in
  `sculpt.Levels.faces` (`Quad_Faces`) and are drawn as triangle pairs. Levels are Loop subdivision only.
  Polygroups are per triangle (`u16`). Scene file v25.
- Two object kinds: mesh objects (a sculptor per level) and voxel objects (`Object.voxel: ^Voxel_Part`,
  an empty level, own `Mesh_Buffers`, own file section in the levels' place, `OBJECT_KIND_VOXEL`).
- Topology changes copy `object_remesh`: `stroke_finish`, `object_hd_leave`, build the new mesh,
  `render.wait_idle`, `object_release_mesh`, `object_build_from`, then `history_snapshot` /
  `history_record_swap` around it. Swap snapshots are `object_put` bytes.

## 2. Decision: a cage object is a mesh object plus a cage part

```
Object.cage: ^Cage_Part   // nil for a mesh or voxel object
Cage_Part :: struct {
    mesh:     poly.Mesh,        // the editable cage: half-edge, n-gons, creases, groups
    smooth:   int,              // 0..4 Catmull-Clark steps drawn (phase 6; 0 until then)
    flat:     bool,             // split without smoothing (phase 6)
    display:  poly.Display,     // how the drawn mesh maps back to the cage (below)
    selection: poly.Selection,  // the Select layer (phase 5), never the real groups
    edits:    u64,              // a stamp, like Voxel_Part.edits
}
```

The object's levels hold exactly one level: the cage's display mesh (triangulated, after `smooth` steps),
built through `object_build_from` with `old_to_new`, so the sculptor's BVH, culling, LOD, polygroup drawing,
raycast, thumbnails, `--check-mesh`, export and booleans all keep working on what is drawn.

- **Topology edits** (extrude, inset, loop insert, ...) change `cage.mesh`, then rebuild the level exactly
  as `object_rebuild` does (one `object_release_mesh(rebuild = true)` path that keeps `obj.cage`).
  Undo: one swap entry per action (`history_snapshot` before, `history_record_swap` after), `kind = .Model`
  for the timeline colour. `object_put` writes the cage (small) in the levels' place, as voxel objects do,
  so a snapshot is the cage, not the display mesh.
- **Drags** (moving a point, edge or face; the amount of an extrude while dragging) keep the topology:
  each frame the cage positions change, the display positions are recomputed (`poly.display_update`),
  written into the sculptor's mesh through the `old_to_new` map, and `sculpt.sculptor_nodes_moved` is
  called for the nodes touched. That keeps the hard rule (every vertex move goes through the sculptor).
  The swap entry is recorded once, on lift, with the snapshot taken at press.
- **Actions that add topology and then drag** (extrude, inset, bevel, loop insert) change the topology
  once at press (amount 0), rebuild once, and then only move positions while dragging.
- **Brushes, masking and polypaint on a cage object** are refused with a note ("a cage is edited in Model
  mode; Apply to sculpt makes it a sculpt", phase 7) at the press, the way `voxel_brush_allowed` refuses.
  Any other tool that rebuilds the object (remesh, mirror and weld, levels, booleans, repair, slice)
  frees the cage part first: the result is a plain mesh object of the drawn surface, which is what those
  tools mean. Their own swap entry undoes it, since the snapshot holds the cage.
- **Scene file v26**: `OBJECT_KIND_CAGE = 2`; after the object fields, the cage bytes stand where the
  levels go (`poly.mesh_write` / `poly.mesh_read`, versioned inside, damaged bytes refused). The display
  level is rebuilt on reading. v25 and older files read unchanged.
- **Autosave**: cage edits call `autosave_settle` first, like the voxel conversion.

## 3. Package `src/poly` (new)

Imports `core:` and `../geom` (for `Vec3`, `Mesh`, `Aabb`) and `../jobs`. Knows nothing of rendering, UI
or the sculptor. Boundary: `app` and `bench` may import it; `sculpt` imports it in phase 7 (Catmull-Clark
levels); `geom` never does.

### Mesh

```
NONE :: max(u32)
Mesh :: struct {
    // vertices
    positions: [dynamic]Vec3,
    vert_he:   [dynamic]u32,    // an outgoing half-edge; for a border vertex, the one whose face is NONE's next
    corner:    [dynamic]f32,    // vertex sharpness, 0 smooth, INFINITE_SHARP
    // half-edges: twin(h) = h ~ 1, edge(h) = h >> 1, so edges need no array of their own but their data
    he_next:   [dynamic]u32,
    he_vert:   [dynamic]u32,    // the vertex it starts at
    he_face:   [dynamic]u32,    // NONE on a border
    crease:    [dynamic]f32,    // per edge: OpenSubdiv sharpness 0..10, INFINITE_SHARP
    // faces
    face_he:   [dynamic]u32,
    group:     [dynamic]u16,
    // removed elements are kept as holes until mesh_compact; alive flags say which
    vert_alive, edge_alive, face_alive: [dynamic]bool,
}
```

Every operation is a pure procedure on `^Mesh` returning what it made (new faces, edges) and `ok`.
No operation leaves a non-manifold edge, a face with fewer than three corners, or a vertex used twice by
one face. `mesh_compact(m) -> Remap` renumbers after an operation and is what the app calls before building
the display; it is deterministic (order kept).

### Procedures, phase 1

- `mesh_from_polygons(positions, sizes, corners, groups, allocator) -> (Mesh, Build_Error)`; errors:
  an edge used by more than two faces, faces facing opposite ways across an edge, a degenerate face, a
  bow-tie vertex. `mesh_from_triangles(geom.Mesh)` for any sculpt. `mesh_polygons(m)` back out.
- `mesh_check(m) -> Check` with counts: vertices, edges, faces, border edges, quads, triangles, n-gons,
  poles (valence not 4 inside), broken links; `check_ok`.
- `triangulate(m, out: ^geom.Mesh, tri_face: ^[dynamic]u32)`: quads by the shorter diagonal, n-gons by ear
  clipping on the Newell plane, counter-clockwise outward like every geom mesh.
- Targets (each returns a sorted list of ids, deterministic): `edge_loop(m, e, stop)`, `edge_ring(m, e)`,
  `face_loop(m, e)`, `island(m, f)`, `flat_island(m, f, degrees)`, `group_island(m, f)`, `group_all(m, g)`,
  `border_loop(m, e)`, `shortest_path(m, a, b, kind)` (Dijkstra by length, ties by id), `similar(m, f, by)`.
  Loops stop at poles, borders and (option) a group change, as ZModeler and Blender do.
- Primitives (phase 2): `cube(segments)`, `plane`, `cylinder(around, along, caps)`, `quad_sphere(segments)`,
  `torus(around, tube)`, `cone(around)`; all quads where possible, closed, outward.

### Display (phase 2; Catmull-Clark in phase 6)

```
Display :: struct {
    mesh:     geom.Mesh,     // triangles, as drawn
    tri_face: [dynamic]u32,  // display triangle -> cage face
    vert_of:  [dynamic]u32,  // display vertex -> cage vertex at smooth 0 (identity); NONE for made vertices
    edge_segments: [dynamic]u32, // per cage edge, display vertex pairs along it (cage lines on the surface)
}
display_build(m, smooth, flat, d)   // topology and positions
display_update(m, smooth, flat, d)  // positions only, same topology
```

At smooth 0 the display vertices are the cage vertices; triangulation adds none.

## 4. Drawing

- The surface: the object's ordinary draw. Cage polygroups are uploaded as the sculptor's groups, so they
  draw through the existing group colours.
- Cage lines: a new LINELIST pipeline in `render` with the existing mesh shaders (flat colour through
  `params.y < 0`, as the wireframe), depth test with bias, no write. Index buffer = `edge_segments` mapped
  through `old_to_new`. A line list needs no `fillModeNonSolid`, so it works where the LINE fill wireframe
  is off. One more index buffer on `Mesh_Buffers` (`edges`, nil for mesh objects). No new shader.
- Hover and selection feedback: hover (one element) is drawn by the interface overlay in screen space:
  a dot for a point, a 3 px line for an edge, a filled polygon at 25% for a face, coloured blue, amber or
  teal, and the label "Action · Target" beside the pen. Painted selections (phase 5) show as a reserved
  group colour in the uploaded paint, never written into the real groups.

## 5. Interaction (phases 3 to 5)

- `Tool.Model` (new), a `Shelf_Page.Model` page whose tiles are presets (action + target + options).
- `model_tool.odin`: hover picking (sculptor raycast -> display triangle -> cage face -> nearest edge
  or vertex of that face in screen space within a pick radius), the press/drag/lift state machine,
  the floating value, Adjust Last through the existing `Adjust_Op`.
- Wheel: while the Model tool is active the modifier sectors read Snap (Smooth's), Select (Mask's) and
  Alt (Invert's); the pie sector opens the hovered element's action pie.
- Actions live in `src/poly/actions_*.odin` as pure procedures with a parameter struct, so Adjust Last
  re-runs them from the snapshot with new parameters.

## 6. Later phases, where they plug in

- 6: `poly.catmull_clark(m, steps, out)` with OpenSubdiv's semi-sharp crease rules; `display_build` uses it.
  Tests compare limit positions on a cube with creases against values from Blender's subdivision surface.
- 7: `sculpt.Levels` gains a Catmull-Clark scheme for objects applied from a cage (`Quad_Faces` generalised to
  any polygon), Apply to sculpt keeps groups and UVs; the retopology result opens as a cage.
- 8 to 10: further actions and the Topo pen are more procedures in `poly` and more states in `model_tool.odin`.

## 7. Evidence per phase

- `build.sh check`, `build.sh test` with `poly` tests (counts, Euler, `mesh_check`, planted faults, serial
  equals parallel where jobs are used), `smoke`, scripted runs with `--dump-viewport` described,
  `--check-mesh` on the display, touch_check scenarios for the pen grammar (desktop simulation).

## 8. Architect review (2026-10-28): changes adopted

- Topology edits rebuild through `cage_rebuild` (history_forget_strokes, wait_idle, gpu[0] destroy,
  levels_destroy, object_build_from); `object_release_mesh` frees the cage beside `voxel_part_free`, so
  remesh, decimate, mirror, slice, knife, repair, booleans, split, merge and voxel conversion drop it.
- `object_build_from` returns `old_to_new` and `tri_from` as caller-owned heap out-parameters, always with
  the groups; Display keeps only maps in post-renumber numbering, never its own mesh.
- Triangulation (diagonals, ear clips) is frozen at display_build; display_update moves positions only.
- At smooth 0 the display splits vertices where polygroups meet, `Draw_Item.flat` is set and groups are
  always drawn for cage objects; check the cage with `poly.mesh_check`, not the seamed display.
- Picking adds `sculpt.sculptor_raycast_triangle`.
- Topology edits are a `Scene_Command{kind = .Model}` applied at the next frame start (scriptable too);
  drags stay in the frame. `history_record_swap` takes a kind; `.Model` gets a timeline colour.
- `object_editable(app, obj, say)` plus a `CAGE_REFUSED` command set refuse brushes, mask, paint, groups,
  hide, clip, smooth all, pose, deformers, layers, adjust last, levels, HD, dyntopo, UV layout, extract,
  selection sets; the Blender link's Project swaps a cage like a voxel object.
- Cage lines: `Mesh_Mode.Lines` (LINELIST, no cull, LESS_OR_EQUAL, no write) in both sample counts, depth
  pulled toward the eye by a nudged projection (depth bias does not apply to lines), `Mesh_Buffers.edges`,
  `Draw_Item.cage_lines` in the frame keys' spare slot. Coordinate with the Vulkan/Slang thread; go
  through hal.odin's seam.
- No tombstones: every topology change goes through `Edit` (polygon list, rebuild), so the cage is always
  compact, bow-ties and loose vertices are refused, and deleting the last face is refused.
