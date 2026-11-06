package main

import "core:fmt"
import "core:math/linalg"

import "../poly"

// The edits of the Model tool card's Edit section that work on the cage's selection, as
// Blender's edit mode menu does (and ZModeler's actions on a polygroup): what each takes
// is the selected faces, the picked points or the picked edges, and each is one undo step
// that says what it did, or a note saying what it needs.
Cage_Edit :: enum u8 {
	Subdivide,
	Poke,
	Tris_To_Quads,
	Split,
	Separate,
	Fill,
	Bevel_Points,
	Join,
	Relax,
	Smooth,
	Union,
	Subtract,
	Intersect,
}

@(rodata)
CAGE_EDIT_NAMES := [Cage_Edit]string {
	.Subdivide     = "Subdivide faces",
	.Poke          = "Poke faces",
	.Tris_To_Quads = "Triangles to quads",
	.Split         = "Split faces",
	.Separate      = "Separate faces",
	.Fill          = "Fill holes",
	.Bevel_Points  = "Bevel points",
	.Join          = "Join the cage below",
	.Relax         = "Even out cage points",
	.Smooth        = "Smooth cage points",
	.Union         = "Union with the cage below",
	.Subtract      = "Subtract the cage below",
	.Intersect     = "Intersect with the cage below",
}

// What each needs, for the note when the selection has none of it.
@(rodata)
CAGE_EDIT_NEEDS := [Cage_Edit]string {
	.Subdivide     = "selected faces",
	.Poke          = "selected faces",
	.Tris_To_Quads = "two triangles side by side",
	.Split         = "selected faces that are not the whole cage",
	.Separate      = "selected faces that are not the whole cage",
	.Fill          = "a hole (with edges picked on its border, that hole)",
	.Bevel_Points  = "picked points inside the cage, off its borders",
	.Join          = "another cage below it in the scene",
	.Relax         = "a selection",
	.Smooth        = "a selection",
	.Union         = "another closed cage below it in the scene",
	.Subtract      = "another closed cage below it in the scene",
	.Intersect     = "another closed cage below it in the scene",
}

// What each one's count in its report counts.
@(rodata)
CAGE_EDIT_COUNTS := [Cage_Edit]string {
	.Subdivide     = "faces",
	.Poke          = "faces",
	.Tris_To_Quads = "pairs joined",
	.Split         = "faces",
	.Separate      = "faces",
	.Fill          = "holes",
	.Bevel_Points  = "points",
	.Join          = "cages",
	.Relax         = "points",
	.Smooth        = "points",
	.Union         = "cages",
	.Subtract      = "cages",
	.Intersect     = "cages",
}

// How far along each edge Bevel points cuts: a quarter, which leaves the corner's face
// clearly visible and its neighbours whole.
CAGE_POINT_BEVEL :: 0.25

// Runs edit `kind` on `obj`'s cage. Returns false only on a GPU failure.
object_cage_edit :: proc(app: ^App, obj: ^Object, kind: Cage_Edit) -> bool {
	if kind == .Join do return cage_join_below(app, obj)
	#partial switch kind {
	case .Union:     return cage_boolean_below(app, obj, .Union)
	case .Subtract:  return cage_boolean_below(app, obj, .Subtract)
	case .Intersect: return cage_boolean_below(app, obj, .Intersect)
	}
	if kind == .Separate do return cage_separate(app, obj)
	cage := &obj.cage.mesh
	faces_before, points_before := len(cage.face_he), len(cage.positions)
	// The snapshot frees the frame's temporary memory, so it comes before anything made.
	before := history_snapshot(app, obj, fmt.tprintf("%s cage", CAGE_EDIT_NAMES[kind]))
	refuse :: proc(app: ^App, obj: ^Object, before: ^Object_Snapshot, kind: Cage_Edit, err: poly.Build_Error) -> bool {
		history_snapshot_drop(before)
		if err == .None do report(app, nil, {}, "%s needs %s on %s", CAGE_EDIT_NAMES[kind], CAGE_EDIT_NEEDS[kind], object_label(obj))
		else do report(app, nil, {.Warning}, "%s refused on %s: what it would leave is not a valid cage (%v)", CAGE_EDIT_NAMES[kind], object_label(obj), err)
		return true
	}
	faces := make([dynamic]u32, context.temp_allocator)
	poly.selected_faces(cage, &faces)
	r: poly.Edit_Result
	defer poly.edit_result_destroy(&r)
	err: poly.Build_Error
	count := 0
	switch kind {
	case .Join, .Separate, .Union, .Subtract, .Intersect:
	// Handled above, as they change two objects.
	case .Subdivide, .Poke, .Split:
		if len(faces) == 0 || (kind == .Split && len(faces) == len(cage.face_he)) do return refuse(app, obj, before, kind, .None)
		#partial switch kind {
		case .Subdivide: r, err = poly.subdivide_faces(cage, faces[:])
		case .Poke:      r, err = poly.poke_faces(cage, faces[:])
		case:            r, err = poly.split_faces(cage, faces[:])
		}
		count = len(faces)
	case .Tris_To_Quads:
		// With no face selected, the whole cage, as Blender's Alt J on everything.
		if len(faces) == 0 do for f in 0 ..< u32(len(cage.face_he)) do append(&faces, f)
		joined: int
		r, joined, err = poly.tris_to_quads(cage, faces[:])
		if err == .Degenerate_Face do return refuse(app, obj, before, kind, .None)
		count = joined
	case .Fill:
		filled := 0
		// Each hole one picked border edge lies on, or with no edge picked every hole; the
		// edges are found afresh after each fill, which renumbers them.
		edges := make([dynamic]u32, context.temp_allocator)
		poly.picked_edges(cage, &edges)
		any_picked := len(edges) > 0
		for _ in 0 ..< len(cage.crease) {
			hole := poly.NONE
			if any_picked {
				poly.picked_edges(cage, &edges)
				for e in edges do if poly.edge_border(cage, e) {hole = e; break}
			} else {
				for e in 0 ..< u32(len(cage.crease)) do if poly.edge_border(cage, e) {hole = e; break}
			}
			if hole == poly.NONE do break
			poly.edit_result_destroy(&r)
			r, err = poly.fill_hole(cage, hole)
			if err != .None do break
			filled += 1
		}
		if filled == 0 && err == .None do return refuse(app, obj, before, kind, .None)
		count = filled
	case .Bevel_Points:
		points := make([dynamic]u32, context.temp_allocator)
		poly.picked_points(cage, &points)
		inner := 0
		for v in points do if !poly.vert_border(cage, v) do inner += 1
		if inner == 0 do return refuse(app, obj, before, kind, .None)
		r, err = poly.bevel_points(cage, points[:], CAGE_POINT_BEVEL)
		count = inner
	case .Relax, .Smooth:
		moved := cage_smooth_selection(app, obj, kind == .Relax)
		if moved == 0 do return refuse(app, obj, before, kind, .None)
		if !cage_rebuild(app, obj) {
			history_snapshot_drop(before)
			return false
		}
		history_record_swap(app, obj.id, before, kind = .Model)
		app.model.edits += 1
		report(app, nil, {}, "%s: %d points of %s moved", CAGE_EDIT_NAMES[kind], moved, object_label(obj))
		return true
	}
	if err != .None do return refuse(app, obj, before, kind, err)
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	app.model.edits += 1
	report(app, nil, {}, "%s (%d %s): %s went from %d faces and %d points to %d and %d", CAGE_EDIT_NAMES[kind], count, CAGE_EDIT_COUNTS[kind], object_label(obj), faces_before, points_before, len(cage.face_he), len(cage.positions))
	return true
}

// Relax (keeping the shape) or Smooth the selection's points once, their mirror images
// with them, and with the Falloff the points round them by a share; a point on a mirror
// plane stays on it. Returns how many points moved.
cage_smooth_selection :: proc(app: ^App, obj: ^Object, keep_shape: bool) -> int {
	cage := &obj.cage.mesh
	carried := make([dynamic]u32, context.temp_allocator)
	poly.selection_points(cage, &carried)
	if len(carried) == 0 do return 0
	plan := poly.point_move_plan(cage, carried[:], model_axes(app), model_falloff_reach(app, cage), context.temp_allocator)
	goals := poly.smooth_goals(cage, plan.verts[:], keep_shape, context.temp_allocator)
	moved := 0
	for v, i in plan.verts {
		q := cage.positions[v]
		p := linalg.lerp(q, goals[i], plan.weights[i])
		for axis in plan.planes[i] do p[int(axis)] = q[int(axis)]
		if p != q do moved += 1
		goals[i] = p
	}
	for v, i in plan.verts do cage.positions[v] = goals[i]
	return moved
}

// Separate (Blender's P, Selection): the selected faces leave the cage as a cage object
// of their own, in the same place, with the same look. Two undo entries chained into one
// step. Returns false only on a GPU failure.
cage_separate :: proc(app: ^App, obj: ^Object) -> bool {
	before := history_snapshot(app, obj, "separate cage")
	cage := &obj.cage.mesh
	faces := make([dynamic]u32, context.temp_allocator)
	poly.selected_faces(cage, &faces)
	if len(faces) == 0 || len(faces) == len(cage.face_he) {
		history_snapshot_drop(before)
		report(app, nil, {}, "%s needs %s on %s", CAGE_EDIT_NAMES[.Separate], CAGE_EDIT_NEEDS[.Separate], object_label(obj))
		return true
	}
	count := len(faces)
	part, err := poly.faces_mesh(cage, faces[:])
	r: poly.Edit_Result
	if err == .None do r, err = poly.delete_faces(cage, faces[:])
	poly.edit_result_destroy(&r)
	if err != .None {
		poly.mesh_destroy(&part)
		history_snapshot_drop(before)
		report(app, nil, {.Warning}, "Separate refused on %s: what it would leave is not a valid cage (%v)", object_label(obj), err)
		return true
	}
	if !cage_rebuild(app, obj) {
		poly.mesh_destroy(&part)
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	added := new(Object)
	added.transform, added.file = obj.transform, {scale = 1}
	for &s in part.selected do s = false
	if !object_build_cage(app, added, part, obj.cage.look) {
		free(added)
		return false
	}
	added.name = fmt.aprintf("%s part", object_label(obj))
	scene_append(app, added)
	history_record_swap(app, added.id, history_snapshot(app, nil, "add object"), chain = true)
	// The cage the faces came from stays the one being edited, as Blender's active object.
	select_object(app, obj)
	app.model.edits += 1
	report(app, nil, {.Undo}, "Separate: %d face%s of %s became %s", count, "" if count == 1 else "s", object_label(obj), object_label(added))
	return true
}

// Join (Blender's Ctrl J): the cage below this one in the scene becomes part of it, its
// points brought into this one's space, and goes, as Merge down does for sculpts. Two undo
// entries chained into one step. Returns false only on a GPU failure.
cage_join_below :: proc(app: ^App, obj: ^Object) -> bool {
	below := app.scene.selected + 1
	if below >= len(app.scene.objects) || app.scene.objects[below].cage == nil {
		report(app, nil, {}, "%s needs %s on %s", CAGE_EDIT_NAMES[.Join], CAGE_EDIT_NEEDS[.Join], object_label(obj))
		return true
	}
	other := app.scene.objects[below]
	name := fmt.aprintf("%s", object_label(other))
	defer delete(name)
	before := history_snapshot(app, obj, "join cages")
	to := linalg.inverse(transform_matrix(obj.transform)) * transform_matrix(other.transform)
	joined, err := poly.join_meshes(&obj.cage.mesh, &other.cage.mesh, to)
	if err != .None {
		history_snapshot_drop(before)
		report(app, nil, {.Warning}, "Join refused: %s and %s would not make a valid cage (%v)", object_label(obj), name, err)
		return true
	}
	poly.mesh_destroy(&obj.cage.mesh)
	obj.cage.mesh = joined
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	app.scene.selected = below
	scene_delete_selected(app, chain = true)
	select_object(app, obj)
	app.model.edits += 1
	report(app, nil, {.Undo}, "Joined %s into %s", name, object_label(obj))
	return true
}

// The cage selection's counts, for the Edit section's hint.
cage_edit_counts :: proc(m: ^poly.Mesh) -> (faces, points: int) {
	for s in m.selected do if s do faces += 1
	for p in m.picked do if p do points += 1
	return
}

// Union, Subtract or Intersect with the cage below this one in the scene, exactly, along
// the faces' own planes (poly.cage_boolean), as Plasticity's and Shapr3D's solid booleans
// and Blender's Boolean modifier applied: the result is this cage, the faces the other
// adds in a polygroup of their own and the seam creased so Smooth keeps it sharp, and the
// other cage goes, as Join's does. Two undo entries chained into one step. Returns false
// only on a GPU failure.
cage_boolean_below :: proc(app: ^App, obj: ^Object, op: poly.Boolean_Op) -> bool {
	kinds := [poly.Boolean_Op]Cage_Edit{.Union = .Union, .Subtract = .Subtract, .Intersect = .Intersect}
	kind := kinds[op]
	below := app.scene.selected + 1
	if below >= len(app.scene.objects) || app.scene.objects[below].cage == nil {
		report(app, nil, {}, "%s needs %s, %s has none", CAGE_EDIT_NAMES[kind], CAGE_EDIT_NEEDS[kind], object_label(obj))
		return true
	}
	other := app.scene.objects[below]
	name := fmt.aprintf("%s", object_label(other))
	defer delete(name)
	before := history_snapshot(app, obj, fmt.tprintf("%s cages", BOOLEAN_OP_WORDS[op]))
	to := linalg.inverse(transform_matrix(obj.transform)) * transform_matrix(other.transform)
	result, err := poly.cage_boolean(&obj.cage.mesh, &other.cage.mesh, to, op)
	if err != .None {
		history_snapshot_drop(before)
		#partial switch err {
		case .Non_Manifold_Edge:
			report(app, nil, {.Warning}, "%s refused: %s and %s must both be closed, with no open edges, to have an inside", CAGE_EDIT_NAMES[kind], object_label(obj), name)
		case .Degenerate_Face:
			report(app, nil, {.Warning}, "%s: nothing would be left of %s and %s", CAGE_EDIT_NAMES[kind], object_label(obj), name)
		case:
			report(app, nil, {.Warning}, "%s refused on %s and %s: the result would not be a valid cage (%v)", CAGE_EDIT_NAMES[kind], object_label(obj), name, err)
		}
		return true
	}
	faces := len(result.face_he)
	poly.mesh_destroy(&obj.cage.mesh)
	obj.cage.mesh = result
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	app.scene.selected = below
	scene_delete_selected(app, chain = true)
	select_object(app, obj)
	app.model.edits += 1
	report(app, nil, {.Undo}, "%s: %s with %s, %d faces", CAGE_EDIT_NAMES[kind], object_label(obj), name, faces)
	return true
}

@(rodata)
BOOLEAN_OP_WORDS := [poly.Boolean_Op]string {
	.Union     = "union",
	.Subtract  = "subtract",
	.Intersect = "intersect",
}
