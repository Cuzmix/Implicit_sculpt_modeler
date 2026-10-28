package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"

import "../geom"
import "../poly"
import "../render"
import "../sculpt"
import "../ui"

// Model mode's objects: a polygon cage (the poly package) edited with the Model tool, as
// ZBrush's ZModeler edits a PolyMesh. A cage object is a mesh object whose one level is
// the cage cut into triangles, so everything that reads a level (drawing, culling,
// picking, thumbnails, export, booleans, --check-mesh) keeps working on what is drawn;
// the cage itself rides beside it in Object.cage, with maps from the level back to it.
//
// The level is never sculpted: brushes, masks, paint and anything else that changes the
// level in place refuse a cage object (object_editable, CAGE_REFUSED_COMMANDS), since the
// level is made again from the cage after every edit. Tools that rebuild the object from
// its surface (remesh, decimate, mirror and weld, slice, repair, booleans, voxels) drop
// the cage through object_release_mesh, which is what they mean: the result is a mesh of
// the drawn surface. Apply to sculpt does that on purpose.

Cage_Part :: struct {
	mesh:    poly.Mesh,
	look:    Cage_Look,
	// The cage made finer for drawing (none at Smooth 0), whose points start with the
	// cage's own.
	sub:     poly.Subdivision,
	// Per point of the drawn cage (the finest), its vertex in the level, which the
	// sculptor numbers in its own order; per triangle of the level, the cage face it lies in.
	vert_of: []u32,
	face_of: []u32,
}

// How a cage is drawn, as ZBrush's Dynamic Subdivision and Blender's Subdivision Surface
// set it: Smooth steps of Catmull-Clark (0 to poly.SUBDIVIDE_MAX), or with Flat the faces
// only split, for hard surfaces. Saved with the cage and undone with it.
Cage_Look :: struct {
	smooth: int,
	flat:   bool,
}

// The cage as drawn: the finest step, or the cage itself.
cage_drawn :: proc(cp: ^Cage_Part) -> ^poly.Mesh {return poly.subdivision_top(&cp.sub, &cp.mesh)}

// Where cage point v shows: on the drawn surface (its point there).
cage_point :: proc(cp: ^Cage_Part, v: u32) -> Vec3 {return cage_drawn(cp).positions[v]}

// Where cage face f's middle shows: its face point on the drawn surface, which every step
// keeps, or its corners' mean on an unsmoothed cage.
cage_face_center :: proc(cp: ^Cage_Part, f: u32) -> Vec3 {
	if len(cp.sub.steps) == 0 do return poly.face_center(&cp.mesh, f)
	return cage_drawn(cp).positions[len(cp.mesh.positions) + len(cp.mesh.crease) + int(f)]
}

// The points cage edge e shows along, from its first end to its other, into `out`
// (cleared first): on the drawn surface, so a smoothed cage's edges follow its curves.
cage_edge_points :: proc(cp: ^Cage_Part, e: u32, out: ^[dynamic]Vec3) {
	clear(out)
	drawn := cage_drawn(cp)
	n := cp.sub.line_points
	for v in cp.sub.edge_line[int(e) * n:][:n] do append(out, drawn.positions[v])
}

// Frees the object's cage, if it has one. Its GPU edges go with the level's buffers.
cage_part_free :: proc(obj: ^Object) {
	cp := obj.cage
	if cp == nil do return
	poly.mesh_destroy(&cp.mesh)
	poly.subdivision_destroy(&cp.sub)
	delete(cp.vert_of)
	delete(cp.face_of)
	free(cp)
	obj.cage = nil
}

// Makes `cage` (taken, also on failure) the object's cage, drawn as `look` says: the
// level cut from it (made finer first by Smooth), its polygroups on the level's
// triangles, the upload and the cage's edges as lines. The object has no level yet.
// Returns false on a GPU failure, with nothing of the object made.
object_build_cage :: proc(app: ^App, obj: ^Object, cage: poly.Mesh, look := Cage_Look{}) -> bool {
	start := time.tick_now()
	cp := new(Cage_Part)
	cp.mesh = cage
	cp.look = {clamp(look.smooth, 0, poly.SUBDIVIDE_MAX), look.flat}
	// A valid cage always subdivides; were one refused, it is drawn as it is.
	sub, sub_err := poly.subdivide(&cp.mesh, cp.look.smooth, cp.look.flat)
	if sub_err != .None {
		sub, _ = poly.subdivide(&cp.mesh, 0)
		cp.look.smooth = 0
	}
	cp.sub = sub
	drawn := cage_drawn(cp)
	mesh := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	poly.triangulate(drawn, &mesh, &tri_face)
	resize(&mesh.normals, len(mesh.positions))
	// The triangles' groups are their faces', on the heap: building frees temp memory.
	groups := make([]u16, len(tri_face))
	defer delete(groups)
	for f, t in tri_face do groups[t] = drawn.group[f]
	cp.vert_of = make([]u32, len(mesh.positions))
	tri_from := make([]u32, len(tri_face))
	defer delete(tri_from)
	if !object_build_from(app, obj, mesh, start, normals = true, old_to_new = cp.vert_of, surface = {groups = groups}, tri_from = tri_from) {
		cage_free_part(cp)
		return false
	}
	cp.face_of = make([]u32, len(tri_from))
	for old, t in tri_from do cp.face_of[t] = cp.sub.face_from[tri_face[old]]
	obj.cage = cp
	if !cage_upload_edges(app, obj) {
		object_release_mesh(app, obj, rebuild = false)
		return false
	}
	return true
}

// Sends the cage's vertices `verts` (cage ids), moved without a change of topology, to
// the level: its positions, bounds and normals, and the GPU at the next flush. A smoothed
// cage's finer points are worked out again and every one sent, since each cage point
// pulls on the surface round it.
cage_positions_moved :: proc(app: ^App, obj: ^Object, verts: []u32) {
	cp := obj.cage
	moved := verts
	if len(cp.sub.steps) > 0 {
		poly.subdivision_update(&cp.sub, &cp.mesh, cp.look.flat)
		moved = make([]u32, len(cp.vert_of), context.temp_allocator)
		for &v, i in moved do v = u32(i)
	}
	drawn := cage_drawn(cp)
	level := make([]u32, len(moved), context.temp_allocator)
	positions := make([]Vec3, len(moved), context.temp_allocator)
	for v, i in moved do level[i], positions[i] = cp.vert_of[v], drawn.positions[v]
	sculpt.sculptor_place_vertices(object_sculptor(obj), level, positions)
}

// Works the drawn surface out again after creases or corners changed, which the finer
// cages take when they are made, and sends every point to the level. The topology is
// the same, so the level and its edges stay.
cage_sharpness_changed :: proc(app: ^App, obj: ^Object) {
	cp := obj.cage
	if len(cp.sub.steps) == 0 do return
	sub, err := poly.subdivide(&cp.mesh, cp.look.smooth, cp.look.flat)
	// The same cage subdivided before, so it does again.
	if err != .None do return
	poly.subdivision_destroy(&cp.sub)
	cp.sub = sub
	cage_positions_moved(app, obj, nil)
}

@(private = "file")
cage_free_part :: proc(cp: ^Cage_Part) {
	poly.mesh_destroy(&cp.mesh)
	poly.subdivision_destroy(&cp.sub)
	delete(cp.vert_of)
	delete(cp.face_of)
	free(cp)
}

// Sends the cage's edges, as pairs of the level's vertices, to the level's buffers: each
// edge along its line over the drawn surface.
cage_upload_edges :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.cage
	n := cp.sub.line_points
	pieces := n - 1
	pairs := make([]u32, 2 * pieces * len(cp.mesh.crease), context.temp_allocator)
	for e in 0 ..< len(cp.mesh.crease) {
		line := cp.sub.edge_line[e * n:][:n]
		for i in 0 ..< pieces {
			at := 2 * (e * pieces + i)
			pairs[at], pairs[at + 1] = cp.vert_of[line[i]], cp.vert_of[line[i + 1]]
		}
	}
	return render.mesh_buffers_set_edges(&app.renderer, &obj.gpu[0], pairs)
}

// Builds the level again from the object's cage after an edit changed it: the strokes,
// buffers and level go and are made anew, keeping the object's place, name, material and
// cage. Returns false on a GPU failure, with the object left without a level for the
// caller to drop.
cage_rebuild :: proc(app: ^App, obj: ^Object) -> bool {
	assert(obj.cage != nil)
	// The autosave thread may be writing the object out; it finishes first.
	autosave_settle(app)
	cage, look := obj.cage.mesh, obj.cage.look
	obj.cage.mesh = {}
	render.wait_idle(&app.renderer)
	object_release_mesh(app, obj, rebuild = false)
	return object_build_cage(app, obj, cage, look)
}

// Adds primitive `kind` as a new cage object, named after it, where the next object goes,
// and selects it. Returns false only on a GPU failure.
scene_add_cage :: proc(app: ^App, kind: poly.Primitive, opts: poly.Primitive_Options, t: Transform) -> bool {
	obj := new(Object)
	obj.transform, obj.file = t, {scale = 1}
	if !object_build_cage(app, obj, poly.primitive(kind, opts)) {
		free(obj)
		return false
	}
	obj.name = fmt.aprintf("%s %d", poly.PRIMITIVE_NAMES[kind], app.scene.next_id + 1)
	scene_append(app, obj)
	c := poly.mesh_check(&obj.cage.mesh)
	log.infof("%s: a cage of %d points, %d edges, %d faces (%d quads)", object_label(obj), c.vertices, c.edges, c.faces, c.quads)
	return true
}

// Apply to sculpt: the cage goes and the object keeps its level as an ordinary mesh,
// which every brush can then sculpt. Returns whether it had a cage to drop.
object_apply_cage :: proc(app: ^App, obj: ^Object) -> bool {
	if obj.cage == nil do return false
	autosave_settle(app)
	render.wait_idle(&app.renderer)
	_ = render.mesh_buffers_set_edges(&app.renderer, &obj.gpu[0], nil)
	cage_part_free(obj)
	return true
}

// Reads the cage object_put wrote in the levels' place into `obj` and builds its level.
// `read` is false when the bytes are damaged (nothing is made); `made` is false on a GPU
// failure.
cage_part_get :: proc(app: ^App, r: ^geom.Byte_Reader, obj: ^Object, version := SCENE_VERSION) -> (read, made: bool) {
	cage, ok := poly.mesh_read(r)
	if !ok do return false, false
	// Smooth and Flat from version 28; an older cage is drawn as it is.
	look: Cage_Look
	if version >= 28 {
		smooth := int(geom.byte_get(r, u8))
		flat := geom.byte_get(r, u8)
		if !r.ok || smooth > poly.SUBDIVIDE_MAX || flat > 1 {
			poly.mesh_destroy(&cage)
			return false, false
		}
		look = {smooth, flat == 1}
	}
	return true, object_build_cage(app, obj, cage, look)
}

// Draws `obj`'s cage as `look` says, as one undo step. Returns false only on a GPU failure.
object_set_cage_look :: proc(app: ^App, obj: ^Object, wanted: Cage_Look) -> bool {
	look := Cage_Look{clamp(wanted.smooth, 0, poly.SUBDIVIDE_MAX), wanted.flat}
	if obj.cage.look == look do return true
	before := history_snapshot(app, obj, "flat" if look.flat != obj.cage.look.flat else fmt.tprintf("smooth %d", look.smooth))
	obj.cage.look = look
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

// The cage clean-ups of the Model palette: Blender's Limited dissolve and Merge by
// distance.
Cage_Tidy :: enum u8 {
	Dissolve_Flat,
	Merge_Close,
}

@(rodata)
CAGE_TIDY_NAMES := [Cage_Tidy]string {
	.Dissolve_Flat = "Dissolve flat",
	.Merge_Close   = "Merge close points",
}

// How flat two faces must be to join, and how close two points to merge (a share of the
// cage's largest side).
CAGE_FLAT_DEGREES :: 5
CAGE_MERGE_SHARE :: 1e-3

// Runs a clean-up on `obj`'s cage as one undo step, saying what it did. Returns false only
// on a GPU failure.
object_tidy_cage :: proc(app: ^App, obj: ^Object, kind: Cage_Tidy) -> bool {
	cage := &obj.cage.mesh
	faces, points := len(cage.face_he), len(cage.positions)
	before := history_snapshot(app, obj, "dissolve flat faces" if kind == .Dissolve_Flat else "merge close points")
	r: poly.Edit_Result
	err: poly.Build_Error
	switch kind {
	case .Dissolve_Flat:
		r, err = poly.dissolve_by_angle(cage, CAGE_FLAT_DEGREES)
	case .Merge_Close:
		b := poly.mesh_bounds(cage)
		size := b.hi - b.lo
		r, _, err = poly.merge_by_distance(cage, CAGE_MERGE_SHARE * max(size.x, size.y, size.z))
	}
	poly.edit_result_destroy(&r)
	if err != .None {
		history_snapshot_drop(before)
		report(app, nil, {.Warning}, "%s refused on %s: what it would leave is not a valid cage (%v)", CAGE_TIDY_NAMES[kind], object_label(obj), err)
		return true
	}
	if len(cage.face_he) == faces && len(cage.positions) == points {
		history_snapshot_drop(before)
		report(app, nil, {}, "%s: nothing to do on %s", CAGE_TIDY_NAMES[kind], object_label(obj))
		return true
	}
	report(app, nil, {}, "%s: %s went from %d faces and %d points to %d and %d", CAGE_TIDY_NAMES[kind], object_label(obj), faces, points, len(cage.face_he), len(cage.positions))
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

// The crease options of the Model palette: ZModeler's Crease by angle and Crease
// polygroups, and taking every crease away.
Cage_Crease :: enum u8 {
	By_Angle,
	Group_Borders,
	Clear,
}

@(rodata)
CAGE_CREASE_NAMES := [Cage_Crease]string {
	.By_Angle      = "Crease by angle",
	.Group_Borders = "Crease polygroup borders",
	.Clear         = "Clear creases",
}

// How far two faces must bend from each other for Crease by angle: Blender's default for
// sharp edges.
CAGE_CREASE_DEGREES :: 30

// Creases `obj`'s cage as `kind` says, as one undo step, saying how many edges it changed.
// Returns false only on a GPU failure.
object_crease_cage :: proc(app: ^App, obj: ^Object, kind: Cage_Crease) -> bool {
	before := history_snapshot(app, obj, strings.to_lower(CAGE_CREASE_NAMES[kind], context.temp_allocator))
	cage := &obj.cage.mesh
	count: int
	switch kind {
	case .By_Angle:      count = poly.crease_by_angle(cage, CAGE_CREASE_DEGREES)
	case .Group_Borders: count = poly.crease_group_borders(cage)
	case .Clear:         count = poly.crease_clear(cage)
	}
	if count == 0 {
		history_snapshot_drop(before)
		report(app, nil, {}, "%s: nothing to do on %s", CAGE_CREASE_NAMES[kind], object_label(obj))
		return true
	}
	report(app, nil, {}, "%s: %d %s on %s", CAGE_CREASE_NAMES[kind], count, "edges and points" if kind == .Clear else "edges", object_label(obj))
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

@(rodata)
CAGE_SELECT_NAMES := [poly.Select_Op]string {
	.All    = "Select all faces",
	.None   = "Select no faces",
	.Invert = "Invert selected faces",
	.Grow   = "Grow selected faces",
	.Shrink = "Shrink selected faces",
}

// Changes `obj`'s cage selection as one undo step (a selection is undone as Blender's
// is); nothing is listed when nothing changed. Returns false only on a GPU failure.
object_select_cage :: proc(app: ^App, obj: ^Object, op: poly.Select_Op) -> bool {
	before := history_snapshot(app, obj, strings.to_lower(CAGE_SELECT_NAMES[op], context.temp_allocator))
	if !poly.select_op(&obj.cage.mesh, op) {
		history_snapshot_drop(before)
		return true
	}
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

// The commands a cage object refuses: each changes its level in place (vertices, masks,
// hiding, paint, groups, levels, layers), which the next edit of the cage would undo.
CAGE_REFUSED_COMMANDS :: bit_set[Command_Id; [4]u64]{
	.Dyntopo_Toggle, .Subdivide, .Level_Up, .Level_Down, .Hd_Toggle, .Group_Shortcut, .Mask, .Mask_By, .Mask_Adjust,
	.Show_All, .Invert_Hidden, .Hide_Masked, .Hide_Unmasked, .Grow_Visible, .Shrink_Visible, .Grow_All_Visible,
	.Outer_Ring, .Grow_To_Groups, .Show_Masked, .Store_Selection_Set, .Restore_Selection_Set, .Paint, .Group,
	.Delete_Lower_Levels, .Delete_Higher_Levels, .Hd_Divide, .Hd_Delete, .Hd_Sculpt, .Hd_Leave, .Morph_Store,
	.Morph_Delete, .New_Layer, .Layer_Edit, .Recall_Earlier, .Recall_Later, .Recall_Oldest, .Smooth_All, .Deformer,
	.Deformation, .Reshape_Repeat, .Delete_Hidden, .Extract_Masked, .Replay_Stroke,
}

// The scene commands a cage object refuses, for the same reason.
CAGE_REFUSED_SCENE :: bit_set[Scene_Command_Kind]{.Subdivide, .Set_Level, .Delete_Higher, .Delete_Lower, .Hd_Enter, .Hd_Leave, .Hd_Steps, .Hd_Delete, .Dyntopo, .Extract, .Layout_Uvs}

// Whether the selected object is a cage.
selected_cage :: proc(app: ^App) -> bool {
	obj := selected_object(app)
	return obj != nil && obj.cage != nil
}

// Whether `obj`'s level may be changed in place (a stroke, a mask, paint); a cage's may
// not, which is said once a press (`say`) so the press does not do nothing in silence.
object_editable :: proc(app: ^App, obj: ^Object, say: bool) -> bool {
	if obj.cage == nil do return true
	if say do report(app, nil, {.Warning}, "%s is a cage: edit it with the Model tool, or Apply to sculpt to sculpt it", object_label(obj))
	return false
}

// The Model tool's state: the primitive and segments Add cage makes (zero segments for
// the primitive's defaults), the action and target a press uses (model_tool.odin), and
// what the pen is over and dragging.
Model_Tool :: struct {
	primitive: poly.Primitive,
	segments:  poly.Primitive_Options,
	action:    Model_Action,
	// Per action, the target picked for it, for those in `targeted` (the rest use
	// MODEL_DEFAULT_TARGETS), so each action keeps its own as ZModeler's do.
	targets:   [Model_Action]Model_Target,
	targeted:  bit_set[Model_Action],
	group:     u16, // the polygroup Polygroup paints
	check:     bool, // the mesh check's colours are drawn over the shown cages
	bevel_segments: int, // the segments the last round bevel had (0 for none yet)
	// Per drag action, how far it went last (0 for not yet): a tap with it repeats that, as
	// ZModeler's Extrude does.
	last:      [Model_Action]f32,
	hover:     Model_Hover,
	drag:      Model_Drag,
	// The Knife's last tap on an edge (object 0 for none), which the next tap cuts to, as
	// Maya's Multi-Cut does: each tap cuts from the one before until a tap off the cage.
	knife_from: Model_Knife_Tap,
	// Since the start, for the exit stats: actions made, and refused.
	done:      int,
	refused:   int,
}

// The segments Add cage uses: the ones set, and the defaults for those never set.
model_segments :: proc(m: Model_Tool) -> poly.Primitive_Options {
	s := m.segments
	if s.across <= 0 do s.across = poly.PRIMITIVE_DEFAULTS.across
	if s.around <= 0 do s.around = poly.PRIMITIVE_DEFAULTS.around
	if s.along <= 0 do s.along = poly.PRIMITIVE_DEFAULTS.along
	if s.tube <= 0 do s.tube = poly.PRIMITIVE_DEFAULTS.tube
	return s
}

// The tray's Model palette: the primitive to add as a cage and its segments, Apply to
// sculpt, and what the selected cage is made of.
kit_model_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	m := &app.model
	kit_tool_head(ctx, ui.ICON_GRID, "Model", "Builds and edits cages: polygons with their edges shown, as ZBrush's ZModeler and Blender's edit mode work. Pick an action and a target, then press on a cage: the faces it would reach light up under the pen first. Add a primitive here; Apply to sculpt turns a cage into a mesh to sculpt.")
	ui.caption(ctx, "ACTION")
	actions: [len(Model_Action)]string
	for a, i in Model_Action do actions[i] = MODEL_ACTION_NAMES[a]
	if picked := ui.select(ctx, "model action", actions[:], int(m.action)); picked >= 0 do command_run(app, .Model_Action, picked)
	ui.caption(ctx, "TARGET")
	// Only the targets the action can take.
	targets := make([dynamic]string, context.temp_allocator)
	which := make([dynamic]Model_Target, context.temp_allocator)
	chosen := 0
	for g in MODEL_ACTION_TARGETS[m.action] {
		if g == model_target(m, m.action) do chosen = len(which)
		append(&targets, MODEL_TARGET_NAMES[g])
		append(&which, g)
	}
	if picked := ui.select(ctx, "model target", targets[:], chosen); picked >= 0 do command_run(app, .Model_Target, int(which[picked]))
	how := MODEL_ACTION_HOW[m.action]
	if alt := MODEL_ACTION_ALT[m.action]; alt != "" {
		ui.paragraph(ctx, fmt.tprintf("%s. Held Ctrl (the wheel's Invert): %s.", how, alt))
	} else {
		ui.paragraph(ctx, fmt.tprintf("%s.", how))
	}
	if m.action == .Polygroup {
		g := f32(m.group)
		if ui.slider(ctx, "Polygroup", &g, 0, 64, .Linear, fmt.tprint(m.group)) do m.group = u16(clamp(int(g + 0.5), 0, 64))
	}
	if obj := selected_object(app); obj != nil && obj.cage != nil {
		// The live surface, as ZBrush's Dynamic Subdivision: steps of smoothing drawn over
		// the cage, which keeps its edges and is what every action works on.
		ui.caption(ctx, "SURFACE")
		steps := [poly.SUBDIVIDE_MAX + 1]string{"Off", "1", "2", "3", "4"}
		hints: [poly.SUBDIVIDE_MAX + 1]string
		for &h, i in hints do h = command_hint(app, .Cage_Smooth, i)
		if picked := ui.tabs(ctx, "cage smooth", steps[:], obj.cage.look.smooth, keys = hints[:]); picked >= 0 do command_run(app, .Cage_Smooth, picked)
		flat := obj.cage.look.flat
		if ui.switch_row(ctx, "Flat", &flat, keys = command_hint(app, .Cage_Flat)) do command_run(app, .Cage_Flat)
		ui.caption(ctx, "CREASES")
		kit_command_pair(app, .Crease_Cage, .Crease_Cage, arg_a = int(Cage_Crease.By_Angle), arg_b = int(Cage_Crease.Group_Borders), label_a = "By angle", label_b = "Polygroups")
		_ = command_button(app, .Crease_Cage, int(Cage_Crease.Clear), "Clear creases", width = ui.fill_width(ctx))
	}
	check := m.check
	if ui.switch_row(ctx, "Mesh check", &check, keys = command_hint(app, .Cage_Check)) do command_run(app, .Cage_Check)
	ui.caption(ctx, "SELECTION")
	kit_command_pair(app, .Select_Cage, .Select_Cage, arg_a = int(poly.Select_Op.All), arg_b = int(poly.Select_Op.None), label_a = "All", label_b = "None")
	kit_command_pair(app, .Select_Cage, .Select_Cage, arg_a = int(poly.Select_Op.Grow), arg_b = int(poly.Select_Op.Shrink), label_a = "Grow", label_b = "Shrink")
	_ = command_button(app, .Select_Cage, int(poly.Select_Op.Invert), "Invert", width = ui.fill_width(ctx))
	ui.caption(ctx, "TIDY")
	kit_command_pair(app, .Tidy_Cage, .Tidy_Cage, arg_a = int(Cage_Tidy.Dissolve_Flat), arg_b = int(Cage_Tidy.Merge_Close), label_a = "Dissolve flat", label_b = "Merge close")
	ui.caption(ctx, "NEW CAGE")
	names: [len(poly.Primitive)]string
	for p, i in poly.Primitive do names[i] = poly.PRIMITIVE_NAMES[p]
	if picked := ui.select(ctx, "cage primitive", names[:], int(m.primitive)); picked >= 0 do m.primitive = poly.Primitive(picked)
	m.segments = model_segments(m^)
	segments :: proc(ctx: ^ui.Context, label: string, value: ^int, lo: int) {
		v := f32(value^)
		if ui.slider(ctx, label, &v, f32(lo), 64, .Logarithmic, fmt.tprint(value^)) do value^ = clamp(int(v + 0.5), lo, 64)
	}
	switch m.primitive {
	case .Cube, .Plane, .Sphere:
		segments(ctx, "Segments", &m.segments.across, 2 if m.primitive == .Sphere else 1)
	case .Cylinder:
		segments(ctx, "Around", &m.segments.around, 3)
		segments(ctx, "Along", &m.segments.along, 1)
	case .Torus:
		segments(ctx, "Around", &m.segments.around, 3)
		segments(ctx, "Tube", &m.segments.tube, 3)
	case .Cone:
		segments(ctx, "Around", &m.segments.around, 3)
	}
	kit_command_pair(app, .Add_Cage, .Apply_Cage, arg_a = int(m.primitive), label_a = "Add cage")
	obj := selected_object(app)
	if obj == nil || obj.cage == nil do return
	c := poly.mesh_check(&obj.cage.mesh)
	creased, corners := poly.crease_count(&obj.cage.mesh)
	ui.paragraph(ctx, fmt.tprintf("%s: %d points, %d edges, %d faces (%d quads, %d triangles, %d polygons), %d creased edges, %d corners, %d poles, %d open edges", object_label(obj), c.vertices, c.edges, c.faces, c.quads, c.triangles, c.ngons, creased, corners, c.poles, c.border_edges))
}
