# Phase 8b: the live stack (Bevel creases, Thickness)

What exists after: a cage's look (Cage_Look) gains two live steps that run before Smooth/Flat, as
ZBrush's Dynamic Subdivision QGrid and Thickness and Blender's Bevel and Solidify modifiers do. The
cage stays as the user modelled it; what is drawn (and what Apply to sculpt turns into levels) is
cage -> bevel every creased edge -> thickness for a shell -> Smooth/Flat.

## poly: live.odin

    Live :: struct {
        bevel:          f32,  // 0 off; the strip width, in the cage's units
        bevel_segments: int,  // 1..BEVEL_SEGMENTS_MAX
        thickness:      f32,  // 0 off
        thickness_segments: int, // 1..LIVE_THICKNESS_SEGMENTS_MAX (rim quads across)
        side:           Thickness_Side, // Out, In, Centre
    }
    Live_Mesh :: struct {
        mesh:      Mesh,
        vert:      []u32, // per cage vertex: its vertex in mesh, NONE when the bevel replaced it
        face_from: []u32, // per mesh face: the cage face it came from, NONE for a bevel strip or patch
    }
    live_build(cage, live) -> (Live_Mesh, Build_Error)
    live_update(cage, live, lm)   // same topology, new positions (a drag of cage points)

- Bevel: mesh_clone, bevel_edges over every edge with crease > 0, drag_apply at the width (the bevel's
  own clamp keeps it valid). Edges a bevel refuses (a crease touching a border) make the step refused:
  the bevel is skipped for the whole cage and Live_Mesh says so (bevel_refused), the panel shows it.
- Thickness: offset copy along area-weighted vertex normals (Out: copy at +t, the cage's faces turned
  over; In: copy at -t turned over; Centre: both at -/+ t/2). Rim of `segments` quads along every
  border loop, wound to match both layers. The cage's vertices keep their ids (first V points), the
  copy follows, then rim rings. face_from: both layers -> source face; rim -> the face beside the border.
  A closed cage gets a hollow second shell (Blender's Solidify on a closed mesh).
- Determinism: everything in cage order, no maps decide order (bevel already sorts).

## app

- Cage_Look gains `live: poly.Live`. Cage_Part gains `live: poly.Live_Mesh` (empty when off).
  object_build_cage: live_build, then subdivide the live mesh; face_of composes sub.face_from with
  live.face_from (NONE allowed). cage_positions_moved: with the stack on, live_update then
  subdivision_update on the live mesh, every point sent. cage_sharpness_changed: with Bevel creases on,
  a crease change can change topology, so it rebuilds (cage_rebuild).
- Drawing and picking: cage_point(v) = drawn point of live.vert[v] (vertex points keep ids through
  subdivision), or the cage point itself when NONE; cage_face_center uses the cage's own face centre
  when the stack is on; cage_edge_points finds the live edge between live.vert[a] and live.vert[b]
  (reversed when its first end is b) and otherwise gives the two cage points straight;
  cage_upload_edges skips edges with no live edge (a bevelled edge shows as its strip).
  model_pick: a triangle whose face_of is NONE picks nothing.
- Apply to sculpt: the polygons given to the levels are the live mesh's (cage_polys on the live mesh,
  creases of the live mesh), so a bevelled cage becomes levels of its strips. Edit cage on such a sculpt
  gives the live mesh back as the cage (the stack is baked), as ZBrush's Apply does.
- Scene file: version 31 writes Live after Smooth/Flat (f32, u8, f32, u8, u8); older cages read with
  the stack off. Damaged values (negative, NaN, segments out of range) refuse the file.
- Undo: a Cage_Look scene command for the tabs (segments, side) is one swap step as Smooth is; the two
  width sliders snapshot on the first change of a drag, rebuild live while dragging, and record the
  swap on release (cage_look_drag_end, called with the other inspector drags).
- Commands and scripts: cage_bevel <percent of the cage's size, 0..20>, cage_bevel_segments <1..6>,
  cage_thickness <percent, 0..20>, cage_thickness_segments <1..6>, cage_thickness_side <out|in|centre>.
  Model palette SURFACE section: Bevel creases slider + segments tabs; Thickness slider + segments
  tabs + side tabs. Exit stats cage_bevel, cage_thickness (on cages), cage_live_faces.
- README: the Surface paragraph; the scenario list.

## Tests

poly: bevel live on a creased cube (faces, closed, mesh_check sound, vert map), thickness on a plane
(closed shell, faces = 2F + rim, orientation consistent: mesh_from_polygons accepts it), Centre keeps
the middle, live_update equals live_build positions after a move, serial order deterministic.
Touch: cube with crease_cage by_angle, cage_bevel 5 -> more faces drawn, apply makes levels; plane
cage_thickness 5 -> closed; undo of a slider drag is one step.
