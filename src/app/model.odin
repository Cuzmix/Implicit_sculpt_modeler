package main

import "core:fmt"
import "core:log"
import "core:time"

import "../geom"
import "../poly"
import "../render"
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
	// Per cage vertex, its vertex in the level, which the sculptor numbers in its own
	// order; per triangle of the level, the cage face it was cut from.
	vert_of: []u32,
	face_of: []u32,
}

// Frees the object's cage, if it has one. Its GPU edges go with the level's buffers.
cage_part_free :: proc(obj: ^Object) {
	cp := obj.cage
	if cp == nil do return
	poly.mesh_destroy(&cp.mesh)
	delete(cp.vert_of)
	delete(cp.face_of)
	free(cp)
	obj.cage = nil
}

// Makes `cage` (taken, also on failure) the object's cage: the level cut from it, its
// polygroups on the level's triangles, the upload and the cage's edges as lines. The
// object has no level yet. Returns false on a GPU failure, with nothing of the object made.
object_build_cage :: proc(app: ^App, obj: ^Object, cage: poly.Mesh) -> bool {
	start := time.tick_now()
	cp := new(Cage_Part)
	cp.mesh = cage
	mesh := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	poly.triangulate(&cp.mesh, &mesh, &tri_face)
	resize(&mesh.normals, len(mesh.positions))
	// The triangles' groups are their faces', on the heap: building frees temp memory.
	groups := make([]u16, len(tri_face))
	defer delete(groups)
	for f, t in tri_face do groups[t] = cp.mesh.group[f]
	cp.vert_of = make([]u32, len(mesh.positions))
	tri_from := make([]u32, len(tri_face))
	defer delete(tri_from)
	if !object_build_from(app, obj, mesh, start, normals = true, old_to_new = cp.vert_of, surface = {groups = groups}, tri_from = tri_from) {
		cage_free_part(cp)
		return false
	}
	cp.face_of = make([]u32, len(tri_from))
	for old, t in tri_from do cp.face_of[t] = tri_face[old]
	obj.cage = cp
	if !cage_upload_edges(app, obj) {
		object_release_mesh(app, obj, rebuild = false)
		return false
	}
	return true
}

@(private = "file")
cage_free_part :: proc(cp: ^Cage_Part) {
	poly.mesh_destroy(&cp.mesh)
	delete(cp.vert_of)
	delete(cp.face_of)
	free(cp)
}

// Sends the cage's edges, as pairs of the level's vertices, to the level's buffers.
cage_upload_edges :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.cage
	edges := len(cp.mesh.crease)
	pairs := make([]u32, 2 * edges, context.temp_allocator)
	for e in 0 ..< edges {
		a, b := poly.edge_verts(&cp.mesh, u32(e))
		pairs[2 * e], pairs[2 * e + 1] = cp.vert_of[a], cp.vert_of[b]
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
	cage := obj.cage.mesh
	obj.cage.mesh = {}
	render.wait_idle(&app.renderer)
	object_release_mesh(app, obj, rebuild = false)
	return object_build_cage(app, obj, cage)
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
cage_part_get :: proc(app: ^App, r: ^geom.Byte_Reader, obj: ^Object) -> (read, made: bool) {
	cage, ok := poly.mesh_read(r)
	if !ok do return false, false
	return true, object_build_cage(app, obj, cage)
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
// the primitive's defaults).
Model_Tool :: struct {
	primitive: poly.Primitive,
	segments:  poly.Primitive_Options,
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
	t := ctx.theme
	m := &app.model
	kit_tool_head(ctx, ui.ICON_GRID, "Model", "Builds and edits cages: polygons with their edges shown, as ZBrush's ZModeler and Blender's edit mode work. Add a primitive here; Apply to sculpt turns a cage into a mesh to sculpt.")
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
	ui.label(ctx, fmt.tprintf("%s: %d points, %d edges, %d faces (%d quads, %d triangles, %d polygons)", object_label(obj), c.vertices, c.edges, c.faces, c.quads, c.triangles, c.ngons), t.small_size)
}

// The Model tool for now: a press on an object selects it, as the Move tool's does; the
// cage's actions come with the pen grammar.
model_tool_frame :: proc(app: ^App, input: Viewport_Input) {
	if !input.primary || !input.press do return
	origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
	if index, _, ok := scene_raycast(app, origin, dir); ok do app.scene.selected = index
}
