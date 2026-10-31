package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:time"

import "../camera"
import "../geom"
import "../gizmo"
import "../render"
import "../sculpt"
import "../poly"
import "../voxel"
import "../retopo"

// Where an object sits in the world. Meshes stay in their own local space; the brush
// works in local space too, so moving or turning an object never touches its vertices.
// Scale is uniform, so normals turn with the object and need no other correction.
Transform :: struct {
	position: Vec3,
	scale:    f32,
	rotation: Vec3, // degrees about x, then y, then z (the zero value is no turn)
}

Vec3 :: [3]f32

// The turn of the transform as a matrix: about x first, then y, then z.
transform_rotation :: proc(t: Transform) -> matrix[3, 3]f32 {return gizmo.rotation_matrix(t.rotation)}

transform_matrix :: proc(t: Transform) -> render.Mat4 {
	m, s, p := transform_rotation(t), t.scale, t.position
	return render.Mat4{
		s * m[0, 0], s * m[0, 1], s * m[0, 2], p.x,
		s * m[1, 0], s * m[1, 1], s * m[1, 2], p.y,
		s * m[2, 0], s * m[2, 1], s * m[2, 2], p.z,
		0, 0, 0, 1,
	}
}

to_local :: proc(t: Transform, p: Vec3) -> Vec3 {return linalg.transpose(transform_rotation(t)) * (p - t.position) / t.scale}
to_world :: proc(t: Transform, p: Vec3) -> Vec3 {return transform_rotation(t) * (p * t.scale) + t.position}
// A direction (a ray's, an offset) from world space into the object's, and back. Only
// the turn applies; the scale is left to the caller where lengths matter.
to_local_dir :: proc(t: Transform, d: Vec3) -> Vec3 {return linalg.transpose(transform_rotation(t)) * d}
to_world_dir :: proc(t: Transform, d: Vec3) -> Vec3 {return transform_rotation(t) * d}

// One sculptable mesh in the scene, with its subdivision levels: only the current
// level is shown and sculpted, or while sculpting HD, a window of the HD level over the
// top level (see object_hd_enter).
Object :: struct {
	id:        int, // never reused
	name:      string, // the file an imported object came from, or the shape it started as; "" for a sphere (owned)
	transform: Transform,
	// Where the object's own space sits in the file it was imported from (or is
	// exported to): imports are moved and scaled to the size the app works at, and
	// this puts them back. The identity for spheres.
	file:      Transform,
	levels:    sculpt.Levels,
	// Per level, made the first time the level is shown and kept while it exists. A
	// level's buffers catch up with what changed while it was not current when it is
	// shown again (see object_show_level).
	gpu:       [sculpt.MAX_LEVELS]render.Mesh_Buffers,
	hd_gpu:    render.Mesh_Buffers, // the HD window's, while one is open
	// Per level, the polygons whose edges its buffers hold for the wireframe (poly_edges.odin).
	poly_edges: [sculpt.MAX_LEVELS]sculpt.Polygon_Source,
	boolean:   Boolean_Mode, // how it applies to the base in a boolean (app/boolean.odin)
	// Its eye is off: out of view and out of reach until shown again (scene_tree.odin).
	// Not hidden triangles, which are the sculptor's.
	off:       bool,
	ghost:     bool, // drawn dimmed as a reference, never picked by a press in the viewport
	// Its polypaint is left out of the drawing (the paint toggle of its row in the Objects
	// card), as ZBrush's SubTool rows turn colour off: the colours are kept, only unseen.
	paint_off: bool,
	// Locked: no press in the view reaches it, as a ghost, but it is drawn solid; the
	// Scene card's lock sets it, so a finished part is not sculpted by accident.
	locked:    bool,
	folder:    int, // the Folder it is in, by id; 0 for none
	// The spaces it is left out of (the outliner's dots): out of view and reach while one of
	// them is current, as its eye is everywhere (scene_tree.odin).
	spaces_off: bit_set[Space; u8],
	vis_off:   u8, // its eye in each stored visibility (bit k for V(k+1)): off (scene_tree.odin)
	// A voxel object's clay (voxel_object.odin); nil for a mesh object. A voxel object's
	// `levels` hold one empty level, so what reads the selected object's sculptor reads
	// nothing; the clay is what is drawn and sculpted.
	voxel:     ^Voxel_Part,
	// A Model mode cage (model.odin); nil for anything else. A cage object's one level is
	// the cage cut into triangles, made again from the cage after every edit.
	cage:      ^Cage_Part,
	// How it is shaded: a preset's values or its own (label "Custom"); a nil label until
	// materials_settle gives it the default (object_material).
	material:  Material,
	// Its polygroups with materials of their own, sorted by group (group_materials.odin);
	// none on a voxel object.
	group_materials: [dynamic]Group_Material,
	// Its texture maps, while it has quads and UVs (textures.odin), and their GPU copy.
	textures:  Object_Textures,
	preview:   Texture_Preview,
}

// The level being sculpted: the HD window while one is open.
object_level :: proc(obj: ^Object) -> ^sculpt.Level {return sculpt.levels_active(&obj.levels)}
object_sculptor :: proc(obj: ^Object) -> ^sculpt.Sculptor {return &object_level(obj).sculptor}
object_mesh :: proc(obj: ^Object) -> ^geom.Mesh {return &object_level(obj).mesh}
object_gpu :: proc(obj: ^Object) -> ^render.Mesh_Buffers {
	if obj.voxel != nil do return &obj.voxel.gpu
	if object_in_hd(obj) do return &obj.hd_gpu
	return &obj.gpu[obj.levels.current]
}
object_in_hd :: proc(obj: ^Object) -> bool {return obj.levels.hd.window != nil}
// With dynamic topology on, the mesh's arrays hold unused slots: count these instead; a
// voxel object's counts are its surface's.
object_vertex_count :: proc(obj: ^Object) -> int {
	if vp := obj.voxel; vp != nil {
		vertices, _ := voxel.surface_counts(&vp.clay.surface)
		return vertices
	}
	return sculpt.sculptor_vertex_count(object_sculptor(obj))
}
object_triangle_count :: proc(obj: ^Object) -> int {
	if vp := obj.voxel; vp != nil {
		_, triangles := voxel.surface_counts(&vp.clay.surface)
		return triangles
	}
	return sculpt.sculptor_triangle_count(object_sculptor(obj))
}
object_dynamic :: proc(obj: ^Object) -> bool {return sculpt.levels_dynamic(&obj.levels)}
// How the object is shown in panels and logs: "Sphere <id>", or its file's name.
object_label :: proc(obj: ^Object) -> string {
	if obj.name != "" do return obj.name
	return fmt.tprintf("Sphere %d", obj.id)
}

Scene :: struct {
	objects:  [dynamic]^Object,
	selected: int, // index into objects, -1 when nothing is selected
	next_id:  int,
	solo:     bool, // only the selected object is shown, whichever that is (scene_tree.odin)
	// Folders, nested as Blender's collections. A folder's objects, with those of the
	// folders inside it, stay next to each other in `objects` (scene_folders_normalize),
	// so the list's order is the tree's.
	folders:  [dynamic]Folder,
	next_folder_id: int,
	// The other selected objects' ids, while the selected one's id is still `also_for`
	// (scene_tree.odin's multi-select).
	also:     [dynamic]int,
	also_for: int,
	// Store visibility, as ZBrush's V1 to V8: the one chosen (1 to 8, 0 for none) and
	// those that hold eyes (bit k for V(k+1)); each object's and folder's eyes in them are
	// their vis_off (scene_tree.odin's visibility_slot).
	vis_slot: int,
	vis_used: u8,
	// Names the scene to the Blender link, so objects sent from another scene never
	// replace this one's (link.odin); 0 until something is sent. Saved with the scene.
	link_token: u64,
	// The scene's lights (lights.odin), saved with it, and whether they came from its file
	// rather than the starting lights (a file from before scenes kept lights, or none).
	lights:     Light_Set,
	lights_own: bool,
	// Millimetres per scene unit when printed (print.odin), saved with the scene.
	print_mm: f32,
	// The proportion guides (guides.odin), saved with the scene.
	guides:   Guides,
}

// Changes to the object list or the selected object's levels requested by the UI,
// applied at the start of the next frame so no panel ever draws an object (or GPU
// buffer) freed during the same frame.
// Polypaint per vertex and polygroups per triangle that a mesh brings to the object made
// from it (Split and Merge keep the surface's parts); nil for none.
Surface :: struct {
	color:  []sculpt.Color,
	groups: []u16,
}

Scene_Command_Kind :: enum u8 {None, Add, New, Remesh, Decimate, Retopo, Delete, Duplicate, Symmetrize, Slice, Subdivide, Set_Level, Delete_Higher, Delete_Lower, Hd_Enter, Hd_Leave, Hd_Steps, Hd_Delete, Dyntopo, Boolean, Extract, View, Arrange, Copy, Paste, Delete_Others, Levels_All, Split, Merge, Align, Distribute, Material, Group_Material, Voxel_To_Mesh, Layout_Uvs, Remove_Textures, Mesh_To_Voxels, Knife, Voxel_Resample, Repair, Add_Cage, Apply_Cage, Edit_Cage, Tidy_Cage, Select_Cage, Cage_Look, Crease_Cage}

// The commands that work on a mesh object's level, and so refuse a voxel object until it
// is converted to a mesh (Voxel_To_Mesh); the rest place, copy, list or delete objects of
// either kind.
MESH_ONLY_COMMANDS :: bit_set[Scene_Command_Kind]{.Remesh, .Decimate, .Retopo, .Symmetrize, .Slice, .Knife, .Subdivide, .Set_Level, .Delete_Higher, .Delete_Lower, .Hd_Enter, .Hd_Leave, .Hd_Steps, .Hd_Delete, .Dyntopo, .Extract, .Split, .Merge, .Group_Material, .Layout_Uvs, .Remove_Textures, .Repair}

Scene_Command :: struct {
	kind:     Scene_Command_Kind,
	vertices: int, // Remesh, Decimate: the count (Decimate: unless its setup keeps a share); Retopo: the quads
	quad:     retopo.Options, // Retopo: the engine and its options (retopo.odin)
	remesh:   Remesh_Setup, // Remesh: Smooth, Keep detail and Groups (remesh.odin)
	decimate: Decimate_Setup, // Decimate: the share to keep and what to keep besides the shape (decimate.odin)
	shape:    geom.Primitive, // Add, New: what to add
	mesh:     int, // Add, New: a content pack's mesh to add instead (Library.meshes, from 1), or 0
	voxels:   int, // Add: a voxel sphere this many voxels across instead of the shape (0 for a mesh); New: a voxel block this many across; Mesh_To_Voxels: voxels across the object's longest side; Voxel_Resample: the voxel object's new resolution, twice or half its own
	// Dyntopo: turn dynamic topology on, or off; Symmetrize: keep the + side; Delete_Others:
	// the selected objects too; Levels_All: every object to its highest level, or its lowest;
	// Add: below the selected object, in its folder, rather than at the end of the list;
	// Merge: the shown objects into a new one, rather than the selected one and the next;
	// Repair: Close holes leaves the largest open, Delete half keeps the + side; New: an
	// empty scene, with no object.
	on:       bool,
	axis:     int, // Symmetrize, Align, Distribute, Repair's Delete half: 0 x, 1 y, 2 z
	edge:     int, // Align, Distribute: 0 each object's low side, 1 its middle, 2 its high side
	split:    Split_Mode, // Split: what becomes objects of their own
	level:    int, // Set_Level; HD steps for Hd_Steps
	at:       [2]f32, // Hd_Enter: the viewport point to open the window around
	size:     [2]f32, // ...in a viewport of this size
	point:    Vec3, // Slice, Knife: a point of the plane, in the selected object's space
	normal:   Vec3, // ...and the way to the part that becomes a new object (Slice) or goes (Knife)
	// Runs the command again in place of the last one of its kind, from before it
	// (adjust_last.odin): Remesh, Decimate, Symmetrize, Retopo and Extract.
	adjust:   bool,
	view:     View_Change, // View: what changes about how objects are shown
	space:    Space, // View Space_Hide and Space_Show: the space
	id:       int, // View, Arrange: the object (or folder) it changes; Merge: the folder, or 0
	arrange:  Arrange_Change, // Arrange: what changes about the tree
	folder:   int, // Arrange: the folder an object goes into
	before:   int, // Arrange Reorder, Reorder_Folder: the object it goes before, 0 for the end
	name:     [NAME_BYTES]u8, // Arrange: a new name, ending at the first zero
	material: Material, // Material: what the selected objects are shaded with; Group_Material: the group's
	material_to: Material_Target, // Material: which objects take it
	preview:  Material_Preview, // Material: a scrub's preview, its keeping or its going back
	group:    u16, // Group_Material: the polygroup of object `id` it changes (`on`: back to the object's material)
	repair:   Repair_Kind, // Repair: which
	distance: f32, // Repair's Weld points: how far apart vertices weld, as a share of the object's largest side
	cage:     poly.Primitive, // Add_Cage: the primitive to add as a cage...
	segments: poly.Primitive_Options, // ...with these segments
	tidy:     Cage_Tidy, // Tidy_Cage: which
	select:   poly.Select_Op, // Select_Cage: which
	look:     Cage_Look, // Cage_Look: how the selected cage is drawn
	look_drag: bool, // Cage_Look: from a slider being dragged, one undo step when it lets go
	crease:   Cage_Crease, // Crease_Cage: which
}

scene_destroy :: proc(app: ^App) {
	render.wait_idle(&app.renderer)
	for obj in app.scene.objects do object_free(app, obj)
	delete(app.scene.objects)
	folders_clear(&app.scene.folders)
	delete(app.scene.folders)
	delete(app.scene.also)
	delete(app.move.members)
	delete(app.move.edit_members)
	app.scene = {}
}

selected_object :: proc(app: ^App) -> ^Object {
	s := &app.scene
	if s.selected < 0 || s.selected >= len(s.objects) do return nil
	return s.objects[s.selected]
}

// Builds a sphere of about `vertices` vertices (or an icosphere of `subdiv` levels when
// vertices is 0), prepares it for sculpting, uploads it, and adds it to the scene.
scene_add_sphere :: proc(app: ^App, vertices, subdiv: int, t: Transform) -> bool {
	obj := new(Object)
	obj.transform, obj.file = t, {scale = 1}
	if !object_build(app, obj, vertices, subdiv) {
		free(obj)
		return false
	}
	scene_append(app, obj)
	return true
}

// Adds a shape (geom.Primitive) of about `vertices` vertices, named after it, and
// selects it. Returns false only on a GPU failure.
scene_add_primitive :: proc(app: ^App, shape: geom.Primitive, vertices: int, t: Transform) -> bool {
	obj, ok := object_make_primitive(app, shape, vertices, t)
	if obj == nil do return ok
	scene_append(app, obj)
	log.infof("%s: %d vertices, %d triangles, %d levels", object_label(obj), object_vertex_count(obj), object_triangle_count(obj), len(obj.levels.levels))
	return true
}

// Adds a voxel sphere of radius 1 (the size every starting shape has), `resolution`
// voxels across, as a new object named after it, and selects it. Returns false only on a
// GPU failure.
scene_add_voxel_sphere :: proc(app: ^App, resolution: int, t: Transform) -> bool {
	obj := new(Object)
	obj.transform, obj.file = t, {scale = 1}
	obj.name = fmt.aprintf("Voxels %d", app.scene.next_id + 1)
	if !object_build_voxel(app, obj, resolution) {
		delete(obj.name)
		free(obj)
		return false
	}
	scene_append(app, obj)
	vertices, triangles := object_vertex_count(obj), object_triangle_count(obj)
	log.infof("%s: %d voxels across, %d bricks, %d vertices, %d triangles", object_label(obj), resolution, voxel.volume_brick_count(&obj.voxel.clay.volume), vertices, triangles)
	return true
}

// Builds a shape of about `vertices` vertices as an object that is not in the scene yet
// (no id), named after it: a sphere, a primitive, or a starter that comes with
// subdivision levels (starter_levels) as ZBrush's base meshes do, built at the count
// those levels divide down to. obj is nil when it was not built; ok is false only on a
// GPU failure.
object_make_primitive :: proc(app: ^App, shape: geom.Primitive, vertices: int, t: Transform) -> (obj: ^Object, ok: bool) {
	obj = new(Object)
	obj.transform, obj.file = t, {scale = 1}
	start := time.tick_now()
	levels := starter_levels(vertices) if geom.is_starter(shape) else 0
	if shape == .Sphere {
		if !object_build(app, obj, vertices, 0) {
			free(obj)
			return nil, false
		}
	} else {
		mesh, built := geom.primitive(shape, vertices >> (2 * uint(levels)), &app.pool)
		if !built {
			log.warnf("could not build a %v of %d vertices", shape, vertices)
			free(obj)
			return nil, true
		}
		if !object_build_from(app, obj, mesh, start, normals = true) {
			free(obj)
			return nil, false
		}
		obj.name = fmt.aprintf("%v %d", shape, app.scene.next_id + 1)
	}
	if levels == 0 do return obj, true
	// A starter is a closed manifold mesh, so each level divides; the top is shown.
	for _ in 0 ..< levels do if !sculpt.levels_subdivide(&obj.levels) do break
	if !object_show_level(app, obj, start) {
		render.wait_idle(&app.renderer)
		object_discard(app, obj)
		return nil, false
	}
	return obj, true
}

// How many subdivision levels a starter of about `vertices` vertices comes with: as many
// as keep its base at geom.STARTER_MIN_VERTICES or more (each level has about four times
// the vertices of the one below), up to STARTER_LEVELS. A 1M starter is a 16k base with
// three levels above it.
starter_levels :: proc(vertices: int) -> int {
	k := 0
	for k < STARTER_LEVELS && vertices >> (2 * uint(k + 1)) >= geom.STARTER_MIN_VERTICES do k += 1
	return k
}

STARTER_LEVELS :: 3

// Adds a mesh with zero normals (an import) as a new object named `name` (copied),
// whose own space sits at `file` in its file, and selects it. `name` must not be in
// temp memory, which building frees. `start` is when making the mesh began, for the
// log. With `prepared`, levels already made ready to sculpt (an import's) are taken in
// place of `mesh`. Returns false on a GPU failure.
scene_add_mesh :: proc(app: ^App, mesh: geom.Mesh, name: string, file, t: Transform, start: time.Tick, old_to_new: []u32 = nil, surface: Surface = {}, material: Material = {}, tri_from: []u32 = nil, prepared: ^sculpt.Levels = nil) -> bool {
	obj := object_from_mesh(app, mesh, name, file, t, start, old_to_new, surface, material, tri_from, prepared) or_return
	scene_append(app, obj)
	return true
}

// A new object of `mesh`, built (as scene_add_mesh says) but in no scene yet; nil on a
// GPU failure. `material` is the one it is shaded with, or none for the default.
object_from_mesh :: proc(app: ^App, mesh: geom.Mesh, name: string, file, t: Transform, start: time.Tick, old_to_new: []u32 = nil, surface: Surface = {}, material: Material = {}, tri_from: []u32 = nil, prepared: ^sculpt.Levels = nil) -> (obj: ^Object, ok: bool) {
	obj = new(Object)
	obj.transform, obj.file, obj.material = t, file, material
	if !object_build_from(app, obj, mesh, start, normals = true, old_to_new = old_to_new, surface = surface, tri_from = tri_from, prepared = prepared) {
		free(obj)
		return nil, false
	}
	obj.name = strings.clone(name)
	return obj, true
}

// Gives the object the next id and selects it.
scene_append :: proc(app: ^App, obj: ^Object) {
	app.scene.next_id += 1
	obj.id = app.scene.next_id
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
}

// Rebuilds the object as an even mesh of about `vertices` vertices that keeps the shape
// of the level it is on, as ZBrush's DynaMesh does (geom.remesh_voxel), keeping its
// transform, with `setup`'s options (remesh.odin): its polypaint and polygroups follow
// only with Keep detail, or the groups with Groups. Its levels, HD detail, mask, dynamic
// topology and strokes go (a swap entry recorded by the caller takes the whole remesh
// back). `changed` says whether it was remeshed; ok is false only when the old mesh is
// gone and the new one could not be uploaded.
object_remesh :: proc(app: ^App, obj: ^Object, vertices: int, setup := Remesh_Setup{smooth = geom.REMESH_SMOOTH_DEFAULT}) -> (changed, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	// Measured on the level as it is, before any compacting, as the density preview
	// measures it, so the lattice is the one it showed. Measured afresh rather than taken
	// from the preview: an adjust undoes and remeshes within one frame, before the undo
	// is uploaded and the buffers' version moves.
	area, bounds := geom.mesh_area_bounds(sculpt.levels_current(&obj.levels).mesh, &app.pool)
	source := object_mesh(obj)^
	packed: geom.Mesh
	s := object_sculptor(obj)
	// The dynamic layout's compacting renumbers the triangles, and it has no groups.
	dyn := object_dynamic(obj)
	if dyn {
		// Without the unused slots of the dynamic layout.
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(s)
		delete(mask)
		source = packed
	}
	groups := sculpt.sculptor_groups(s) if !dyn else nil
	report: geom.Remesh_Report
	defer geom.remesh_report_destroy(&report)
	mesh, built := geom.remesh_voxel_measured(source, area, bounds, vertices, &app.pool, options = remesh_options(setup, groups), report = &report)
	surface: Surface
	defer surface_free(&surface)
	if built do surface = remesh_surface(report, mesh, source, s.color if !dyn else nil, groups)
	geom.mesh_destroy(&packed)
	free_all(context.temp_allocator)
	if !built {
		log.warn("remesh: the mesh has no volume to remesh")
		return false, true
	}
	return true, remesh_apply(app, obj, mesh, start, time.tick_now(), surface = surface, remeshed = report, setup = setup)
}

// The second half of a remesh, which a long job (long_job.odin) runs on the frame thread
// once its thread computed `mesh` from `start` to `computed`: the object rebuilt on it, or
// on the levels the thread `prepared` from it (which then already carry the surface and
// the quads, so `surface` is empty). When what the remesh reported (`remeshed`) under `setup` has something to say
// (remesh_note) it reports the result line itself, the note after the count. False only
// when the old mesh is gone and the new one could not be uploaded.
remesh_apply :: proc(app: ^App, obj: ^Object, mesh: geom.Mesh, start, computed: time.Tick, prepared: ^sculpt.Levels = nil, surface: Surface = {}, remeshed: geom.Remesh_Report = {}, setup: Remesh_Setup = {}) -> bool {
	ready := time.tick_now()
	render.wait_idle(&app.renderer)
	// With Quads the maps say where the quads' corners and halves went, for the base
	// level to keep them as its polygons (a long job's levels already do).
	old_to_new, tri_from: []u32
	if remeshed.quads != nil && prepared == nil {
		old_to_new = make([]u32, len(mesh.positions))
		tri_from = make([]u32, len(mesh.indices) / 3)
	}
	defer delete(old_to_new)
	defer delete(tri_from)
	if !object_rebuild(app, obj, mesh, ready, normals = false, surface = surface, prepared = prepared, old_to_new = old_to_new, tri_from = tri_from) do return false
	if old_to_new != nil do remesh_take_quads(&obj.levels, remeshed.quads, old_to_new, tri_from)
	app.stats.remesh_ms = time.duration_milliseconds(time.tick_diff(start, computed))
	app.stats.remesh_setup_ms = time.duration_milliseconds(time.tick_since(ready))
	vertices := geom.mesh_vertex_count(object_mesh(obj)^)
	// Made after the rebuild, which frees the temp memory a note would sit in.
	note := remesh_note(remeshed, setup)
	log.infof("remesh: %d vertices in %.0f ms, ready in %.0f ms more%s", vertices, app.stats.remesh_ms, app.stats.remesh_setup_ms, note)
	if note != "" do report(app, .Remesh, {}, "%s%s", scene_report_line("Remeshed %s", object_label(obj), vertices, time.duration_milliseconds(time.tick_since(start))), note)
	return true
}

// Rebuilds the object with about `vertices` vertices that keep the shape of the level
// it is on, by collapsing edges where that changes the shape least (geom.mesh_decimate),
// as ZBrush's Decimation Master does: dense where the detail is, sparse where it is
// flat. Like a remesh, its levels, HD detail, mask and strokes go (the caller records
// the swap). `changed` says whether it did; ok is false only when the old mesh is gone
// and the new one could not be uploaded.
object_decimate :: proc(app: ^App, obj: ^Object, vertices: int, setup: Decimate_Setup) -> (changed, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	src := decimate_source(obj, setup, borrow = true)
	defer decimate_source_free(&src)
	mesh, error, surface, built, unmirrored := decimate_compute(src, vertices, setup, &app.pool)
	defer surface_free(&surface)
	before := len(src.mesh.positions)
	free_all(context.temp_allocator)
	if !built {
		log.warnf("decimate: the object already has %d vertices, no more than %d", before, vertices)
		return false, true
	}
	return true, decimate_apply(app, obj, mesh, error, before, start, time.tick_now(), surface = surface, setup = setup, unmirrored = unmirrored)
}

// The second half of a decimation, as remesh_apply is a remesh's: the object rebuilt on
// `mesh`, made from `before` vertices with `error` the largest stray, with the polypaint
// and polygroups that followed it (`surface`; a long job's prepared levels carry them).
// Under Keep symmetry the result line names the planes kept, or why they were not
// (`unmirrored`, from decimate_compute).
decimate_apply :: proc(app: ^App, obj: ^Object, mesh: geom.Mesh, error: f32, before: int, start, computed: time.Tick, prepared: ^sculpt.Levels = nil, surface: Surface = {}, setup: Decimate_Setup = {}, unmirrored := "") -> bool {
	ready := time.tick_now()
	render.wait_idle(&app.renderer)
	if !object_rebuild(app, obj, mesh, ready, normals = true, surface = surface, prepared = prepared) do return false
	app.stats.decimate_ms = time.duration_milliseconds(time.tick_diff(start, computed))
	app.stats.decimate_error = error
	vertices := geom.mesh_vertex_count(object_mesh(obj)^)
	// Made after the rebuild, which frees the temp memory a note would sit in.
	note := decimate_note(setup, unmirrored)
	log.infof("decimate: %d vertices to %d in %.0f ms (strays at most %.4f), ready in %.0f ms more%s", before, vertices,
		app.stats.decimate_ms, error, time.duration_milliseconds(time.tick_since(ready)), note)
	flags: Report_Flags
	if unmirrored != "" do flags += {.Warning}
	if note != "" do report(app, .Remesh, flags, "%s%s", scene_report_line("Decimated %s", object_label(obj), vertices, time.duration_milliseconds(time.tick_since(start))), note)
	return true
}

// Mirrors one half of the level the object is on onto the other across its own `axis`
// plane, welded along the cut (geom.mesh_symmetrize), keeping the `keep_positive` half.
// The level's polygons come through as polygons (a quad mesh stays quads, its creases
// mirrored too), as ZBrush's Mirror And Weld keeps a quad mesh's topology. Like a remesh
// it rebuilds the object, so its levels, HD detail, mask and strokes go (the caller
// records the swap that takes it back). `changed` says whether it did; ok is false only
// when the old mesh is gone and the new one could not be uploaded.
object_symmetrize :: proc(app: ^App, obj: ^Object, axis: int, keep_positive: bool) -> (changed, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	source := object_mesh(obj)^
	packed: geom.Mesh
	polygons: geom.Polygons
	creases: geom.Creases
	rule := sculpt.Subdivision_Rule.Smooth
	if object_dynamic(obj) {
		// Dynamic topology has no polygons to keep.
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		source = packed
	} else {
		polygons, creases, rule = object_level_polygons(obj)
	}
	kept: geom.Symmetrized_Polygons
	defer geom.symmetrized_polygons_destroy(&kept)
	mesh, built := geom.mesh_symmetrize(source, axis, keep_positive, &app.pool, polygons = polygons, creases = creases, out_polygons = &kept if polygons.first != nil else nil)
	geom.mesh_destroy(&packed)
	// The polygons in the new mesh's numbers, before the levels renumber it.
	polys: sculpt.Polys
	if built && polygons.first != nil do polys.first, polys.corners, polys.tri_poly = geom.mesh_polygons(mesh.indices[:], kept.polys[:])
	free_all(context.temp_allocator)
	if !built {
		log.warn("mirror and weld: nothing of the object is on the side to keep")
		return false, true
	}
	old_to_new, tri_from: []u32
	if polys.first != nil {
		old_to_new = make([]u32, len(mesh.positions))
		tri_from = make([]u32, len(mesh.indices) / 3)
	}
	defer delete(old_to_new)
	defer delete(tri_from)
	cut := time.tick_now()
	render.wait_idle(&app.renderer)
	if !object_rebuild(app, obj, mesh, cut, normals = true, mirror = {active = true, axis = sculpt.Axis(axis), keep_positive = keep_positive}, old_to_new = old_to_new, tri_from = tri_from) {
		sculpt.polys_destroy(&polys)
		return true, false
	}
	if polys.first != nil do symmetrize_take_polygons(&obj.levels, &polys, kept.creases, rule, old_to_new, tri_from)
	log.infof("mirror and weld: %d vertices, %d polygons in %.0f ms", object_vertex_count(obj), sculpt.levels_polygon_source(&obj.levels, 0).polygons, time.duration_milliseconds(time.tick_diff(start, cut)))
	return true, true
}

// Cuts the object in two along the plane through `point` across `normal` (in its own
// space), as ZBrush's SliceCurve and Split Groups do, closing the cut on both parts
// (geom.mesh_slice): the object keeps the part behind the plane, and the part `normal`
// points to becomes a new object beside it in the list, with the same transform, so
// nothing moves. Like a remesh, its levels, HD detail, mask, hidden parts and strokes go
// (the caller records both changes). `changed` says whether it was sliced, `part` is the
// new object (nil if its upload failed), and ok is false only on a GPU failure; with
// `changed` false and ok false, the object's own mesh is gone.
object_slice :: proc(app: ^App, obj: ^Object, point, normal: Vec3) -> (part: ^Object, changed, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	source := object_mesh(obj)^
	packed: geom.Mesh
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		source = packed
	}
	front, back, made := geom.mesh_slice(source, point, normal, true, &app.pool)
	geom.mesh_destroy(&packed)
	free_all(context.temp_allocator)
	if !made {
		log.warn("slice: the line does not cut the object in two")
		return nil, false, true
	}
	cut := time.tick_now()
	render.wait_idle(&app.renderer)
	// Both parts take the layers, so the level they came from stays until the second has.
	layered := object_take_layered(app, obj)
	defer sculpt.layered_level_free(&layered)
	object_release_mesh(app, obj)
	if !object_build_from(app, obj, back, cut, normals = true) {
		geom.mesh_destroy(&front)
		return nil, false, false
	}
	object_carry_layers(app, obj, layered)
	index := app.scene.selected
	if !scene_add_mesh(app, front, obj.name, obj.file, obj.transform, cut, material = obj.material) do return nil, true, false
	part = app.scene.objects[len(app.scene.objects) - 1]
	object_carry_layers(app, part, layered, counted = false)
	part.folder = obj.folder
	// Beside the object it came from, which stays selected.
	ordered_remove(&app.scene.objects, len(app.scene.objects) - 1)
	inject_at(&app.scene.objects, index + 1, part)
	app.scene.selected = index
	app.stats.slice_ms = time.duration_milliseconds(time.tick_diff(start, cut))
	app.stats.slice_setup_ms = time.duration_milliseconds(time.tick_since(cut))
	log.infof("slice: %d and %d vertices in %.0f ms, ready in %.0f ms more", object_vertex_count(obj), object_vertex_count(part), app.stats.slice_ms, app.stats.slice_setup_ms)
	return part, true, true
}

// Cuts the object along the plane through `point` across `normal` (in its own space) and
// throws away the part `normal` points to, closing the cut on what stays (geom.mesh_slice),
// as ZBrush's KnifeCurve does. Like Mirror and weld it rebuilds the object, so its levels,
// HD detail, mask, hidden parts and strokes go but the level's layers come across (the
// caller records the swap that takes it back). `changed` says whether it cut; ok is false
// only when the old mesh is gone and the new one could not be uploaded.
object_knife :: proc(app: ^App, obj: ^Object, point, normal: Vec3) -> (changed, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	source := object_mesh(obj)^
	packed: geom.Mesh
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		source = packed
	}
	front, back, made := geom.mesh_slice(source, point, normal, true, &app.pool)
	geom.mesh_destroy(&packed)
	geom.mesh_destroy(&front)
	free_all(context.temp_allocator)
	if !made {
		log.warn("knife: the line does not cross the object, or would take all of it")
		return false, true
	}
	cut := time.tick_now()
	render.wait_idle(&app.renderer)
	if !object_rebuild(app, obj, back, cut, normals = true) do return true, false
	app.stats.slice_ms = time.duration_milliseconds(time.tick_diff(start, cut))
	app.stats.slice_setup_ms = time.duration_milliseconds(time.tick_since(cut))
	log.infof("knife: %d vertices kept in %.0f ms, ready in %.0f ms more", object_vertex_count(obj), app.stats.slice_ms, app.stats.slice_setup_ms)
	return true, true
}

// Cuts `obj` across the middle of its bounds along `axis` (0 x, 1 y, 2 z), throwing away
// the + side when `positive` (else the - side), for a script's `knife`. Returns false
// only on a GPU failure.
scene_knife_axis :: proc(app: ^App, obj: ^Object, axis: int, positive: bool) -> bool {
	bounds := geom.AABB_EMPTY
	for p in object_mesh(obj).positions do geom.aabb_grow(&bounds, p)
	normal: Vec3
	normal[axis] = 1 if positive else -1
	for o, i in app.scene.objects do if o == obj do app.scene.selected = i
	return scene_apply(app, {kind = .Knife, point = (bounds.lo + bounds.hi) / 2, normal = normal})
}

// Slices `obj` across the middle of its bounds along `axis` (0 x, 1 y, 2 z), for
// a script's `slice`. Returns false only on a GPU failure.
scene_slice_axis :: proc(app: ^App, obj: ^Object, axis: int) -> bool {
	bounds := geom.AABB_EMPTY
	for p in object_mesh(obj).positions do geom.aabb_grow(&bounds, p)
	normal: Vec3
	normal[axis] = 1
	for o, i in app.scene.objects do if o == obj do app.scene.selected = i
	return scene_apply(app, {kind = .Slice, point = (bounds.lo + bounds.hi) / 2, normal = normal})
}

// Adds a copy of the object beside it (in the list it comes right after it), with every
// level and the mask, and selects it.
// Returns false only on a GPU failure.
scene_duplicate :: proc(app: ^App, obj: ^Object) -> bool {
	stroke_finish(app)
	bytes := make([dynamic]u8)
	defer delete(bytes)
	object_put(app, &bytes, obj)
	r := geom.byte_reader(bytes[:])
	twin, read, made := object_get(app, &r)
	if !read do return true
	if !made {
		render.wait_idle(&app.renderer)
		object_discard(app, twin)
		return false
	}
	twin.transform.position = next_free_position(app)
	scene_append(app, twin)
	// Beside its source in the list (and so in its folder), selected.
	scene_place_after(app, twin, obj)
	log.infof("duplicate: object %d is a copy of %d", twin.id, obj.id)
	return true
}

// Copies the object to the app's clipboard as the scene file stores it, so a paste works
// after the object is gone or another scene is open.
scene_copy :: proc(app: ^App, obj: ^Object) {
	stroke_finish(app)
	clear(&app.clipboard)
	object_put(app, &app.clipboard, obj)
	report(app, nil, {.Quiet}, "Copied %s", object_label(obj))
	log.infof("copy: object %d, %.1f MB on the clipboard", obj.id, f64(len(app.clipboard)) / (1 << 20))
}

// Adds a copy of what the clipboard holds below the selected object (in its folder), in
// view and selected, as an undo step. False only on a GPU failure.
scene_paste :: proc(app: ^App) -> bool {
	if len(app.clipboard) == 0 do return true
	stroke_finish(app)
	r := geom.byte_reader(app.clipboard[:])
	twin, read, made := object_get(app, &r)
	if !read do return true
	if !made {
		render.wait_idle(&app.renderer)
		object_discard(app, twin)
		return false
	}
	sel := selected_object(app)
	// The folder it was copied from may be gone, or in another scene: it goes where the
	// selection is. Hidden or a ghost, the selection would move straight off it.
	twin.folder = sel.folder if sel != nil else 0
	// Its eyes in the stored visibilities were another scene's, or another moment's.
	twin.off, twin.ghost, twin.vis_off = false, false, 0
	twin.transform.position = next_free_position(app)
	scene_append(app, twin)
	if sel != nil do scene_place_after(app, twin, sel)
	history_record_swap(app, twin.id, history_snapshot(app, nil, "paste object"))
	report(app, nil, {.Undo}, "Pasted %s", object_label(twin))
	return true
}

// Moves `twin`, the list's last object, to just after `obj`, and selects it.
scene_place_after :: proc(app: ^App, twin, obj: ^Object) {
	for o, i in app.scene.objects do if o == obj {
		ordered_remove(&app.scene.objects, len(app.scene.objects) - 1)
		inject_at(&app.scene.objects, i + 1, twin)
		app.scene.selected = i + 1
		break
	}
}

// Deletes every object but the selected ones, or with `all` every object, as one undo
// step. Refused when the copies undo keeps would pass the History's limit, which would
// drop the oldest of them and leave the step only partly undoable.
scene_delete_others :: proc(app: ^App, all: bool) {
	ids := make([dynamic]int, 0, len(app.scene.objects))
	defer delete(ids)
	bytes := 0
	for obj in app.scene.objects {
		if !all && object_in_selection(app, obj) do continue
		append(&ids, obj.id)
		bytes += object_put_estimate(obj)
	}
	if len(ids) == 0 do return
	if bytes > SWAP_LIMIT_BYTES {
		report(app, nil, {.Warning}, "Too much to delete in one undoable step (%.1f GB); delete fewer objects at a time", f64(bytes) / (1 << 30))
		return
	}
	for id, k in ids {
		select_object(app, object_by_id(app, id))
		scene_delete_selected(app, chain = k > 0)
	}
	report(app, nil, {.Undo}, "Deleted %d object%s", len(ids), "" if len(ids) == 1 else "s")
}

// Turns dynamic topology on or off for the object (see sculpt.levels_dyn_enable). It
// needs the object to have a single level and no HD level. Its strokes go (a swap entry
// recorded by the caller takes the change back). `changed` says whether it was turned;
// ok is false only on a GPU failure.
object_set_dyntopo :: proc(app: ^App, obj: ^Object, on: bool) -> (changed, ok: bool) {
	if on == object_dynamic(obj) do return false, true
	stroke_finish(app)
	start := time.tick_now()
	if on {
		if len(obj.levels.levels) > 1 || obj.levels.hd.steps > 0 {
			log.warn("dynamic topology: delete the other subdivision levels and the HD level first")
			return false, true
		}
		if !sculpt.levels_dyn_enable(&obj.levels) {
			log.warnf("dynamic topology: a vertex is in more than %d triangles; remesh first", sculpt.DYN_FACES)
			return false, true
		}
		// It drops the groups, and the table with them (the swap step keeps both).
		autosave_settle(app)
		clear(&obj.group_materials)
	} else {
		sculpt.levels_dyn_disable(&obj.levels)
	}
	free_all(context.temp_allocator)
	object_forget_history(app, obj)
	converted := time.tick_now()
	// The layout changed completely: new buffers with everything in them.
	render.wait_idle(&app.renderer)
	render.mesh_buffers_destroy(&app.renderer, &obj.gpu[0])
	obj.poly_edges[0] = {}
	obj.gpu[0], ok = render.mesh_buffers_create(&app.renderer, object_mesh(obj)^, object_sculptor(obj).mask)
	if !ok do return true, false
	render.viewport_invalidate(&app.target)
	app.stats.dyntopo_ms = time.duration_milliseconds(time.tick_diff(start, converted))
	app.stats.dyntopo_upload_ms = time.duration_milliseconds(time.tick_since(converted))
	log.infof("dynamic topology %s: %d vertices, %d triangles; converted in %.0f ms, uploaded in %.0f ms", "on" if on else "off",
		object_vertex_count(obj), object_triangle_count(obj), app.stats.dyntopo_ms, app.stats.dyntopo_upload_ms)
	return true, true
}

// Records the upload of what sculptor_flush reported for the level (its vertex
// `ranges`, and the triangles dynamic topology changed). When dynamic topology has
// outgrown the buffers, makes bigger ones with everything in them instead. Returns the
// bytes sent, and false on a GPU failure.
level_upload :: proc(app: ^App, cmd: render.Cmd, gpu: ^render.Mesh_Buffers, lv: ^sculpt.Level, ranges: []geom.Vertex_Range) -> (bytes: int, ok: bool) {
	m := lv.mesh
	if u32(len(m.positions)) > gpu.vertex_capacity || u32(len(m.indices)) > gpu.index_count {
		render.wait_idle(&app.renderer)
		render.mesh_buffers_destroy(&app.renderer, gpu)
		gpu^ = render.mesh_buffers_create(&app.renderer, m, lv.sculptor.mask) or_return
		render.viewport_invalidate(&app.target)
		app.stats.gpu_regrows += 1
		return len(m.positions) * render.VERTEX_BYTES + len(m.indices) * size_of(u32) + hidden_upload(app, cmd, gpu, lv) + paint_upload(app, cmd, gpu, lv, nil), true
	}
	render.mesh_buffers_upload_ranges(&app.renderer, cmd, gpu, m, ranges, lv.sculptor.mask)
	bytes += paint_upload(app, cmd, gpu, lv, ranges)
	triangles := sculpt.sculptor_index_ranges(&lv.sculptor)
	render.mesh_buffers_upload_indices(&app.renderer, cmd, gpu, m.indices[:], triangles)
	for r in ranges do bytes += int(r.count) * render.VERTEX_BYTES
	for r in triangles do bytes += int(r.index_count) * size_of(u32)
	return bytes + hidden_upload(app, cmd, gpu, lv), true
}

// Brings the index buffer up to date with what is hidden on the level: hidden triangles
// are uploaded as degenerate ones, which draw nothing. A new buffer starts from the
// mesh's own indices, so it takes every node with a hidden triangle. Returns the bytes.
@(private = "file")
hidden_upload :: proc(app: ^App, cmd: render.Cmd, gpu: ^render.Mesh_Buffers, lv: ^sculpt.Level) -> int {
	stamp := sculpt.sculptor_hidden_stamp(&lv.sculptor)
	if gpu.hidden_stamp == stamp do return 0
	indices, ranges := sculpt.sculptor_hidden_indices(&lv.sculptor, gpu.hidden_stamp)
	render.mesh_buffers_upload_packed_indices(&app.renderer, cmd, gpu, indices, ranges)
	gpu.hidden_stamp = stamp
	return len(indices) * size_of(u32)
}

// Deletes the selected object, as an undo step when `undoable` (with `chain`, part of
// the newest one).
scene_delete_selected :: proc(app: ^App, undoable := true, chain := false) {
	obj := selected_object(app)
	if obj == nil do return
	stroke_finish(app)
	if undoable do history_record_swap(app, obj.id, history_snapshot(app, obj, "delete object"), chain)
	render.wait_idle(&app.renderer)
	ordered_remove(&app.scene.objects, app.scene.selected)
	object_free(app, obj)
	app.scene.selected = min(app.scene.selected, len(app.scene.objects) - 1)
}

// Applies a pending UI command. Returns false only on a fatal GPU failure.
scene_apply :: proc(app: ^App, cmd: Scene_Command) -> bool {
	// A drag of where the object sits ends here as its own step, so a snapshot taken
	// below never holds it half done.
	if cmd.kind != .None {
		move_end(app)
		transform_drag_end(app, force = true)
		inspector_drags_end(app)
		// A look slider's own commands carry on its drag.
		if cmd.kind != .Cage_Look || !cmd.look_drag do cage_look_drag_end(app, force = true)
	}
	if obj := selected_object(app); obj != nil && obj.voxel != nil && cmd.kind in MESH_ONLY_COMMANDS {
		report(app, Kit_Section.Voxels, {.Warning}, "%v needs a mesh: convert %s to a mesh first (Object palette, Voxels)", cmd.kind, object_label(obj))
		return true
	}
	if obj := selected_object(app); obj != nil && obj.cage != nil && cmd.kind in CAGE_REFUSED_SCENE {
		report(app, nil, {.Warning}, "%v does not apply to a cage: Apply to sculpt makes %s a mesh first", cmd.kind, object_label(obj))
		return true
	}
	switch cmd.kind {
	case .None:
	case .Add:
		before := len(app.scene.objects)
		sel := selected_object(app)
		at := Transform{position = next_free_position(app), scale = 1}
		if cmd.mesh > 0 {
			if !scene_add_pack_mesh(app, cmd.mesh - 1) do return false
		} else if cmd.voxels > 0 {
			if !scene_add_voxel_sphere(app, cmd.voxels, at) do return false
		} else if !scene_add_primitive(app, cmd.shape, cmd.vertices, at) do return false
		if len(app.scene.objects) > before {
			// Inserted below the selection, in its folder, rather than at the end.
			if cmd.on && sel != nil {
				added := selected_object(app)
				added.folder = sel.folder
				scene_place_after(app, added, sel)
			}
			history_record_added(app)
		}
	case .Add_Cage:
		if !scene_add_cage(app, cmd.cage, cmd.segments, {position = next_free_position(app), scale = 1}) do return false
		history_record_added(app)
	case .Apply_Cage:
		if obj := selected_object(app); obj != nil && obj.cage != nil {
			before := history_snapshot(app, obj, "apply to sculpt")
			if object_apply_cage(app, obj) do history_record_swap(app, obj.id, before, kind = .Model)
			else do history_snapshot_drop(before)
		}
	case .Edit_Cage:
		if obj := selected_object(app); object_can_edit_cage(obj) {
			before := history_snapshot(app, obj, "edit cage")
			if !object_edit_cage(app, obj) {
				history_snapshot_drop(before)
				return false
			}
			if obj.cage != nil do history_record_swap(app, obj.id, before, kind = .Model)
			else do history_snapshot_drop(before)
		}
	case .Tidy_Cage:
		if obj := selected_object(app); obj != nil && obj.cage != nil do return object_tidy_cage(app, obj, cmd.tidy)
	case .Select_Cage:
		if obj := selected_object(app); obj != nil && obj.cage != nil do return object_select_cage(app, obj, cmd.select)
	case .Cage_Look:
		if obj := selected_object(app); obj != nil && obj.cage != nil do return object_set_cage_look(app, obj, cmd.look, cmd.look_drag)
	case .Crease_Cage:
		if obj := selected_object(app); obj != nil && obj.cage != nil do return object_crease_cage(app, obj, cmd.crease)
	case .New:
		if cmd.mesh > 0 do return scene_new_pack_mesh(app, cmd.mesh - 1)
		return scene_new(app, cmd.shape, cmd.vertices, cmd.voxels, empty = cmd.on)
	case .Remesh:
		if obj := selected_object(app); obj != nil {
			before := history_snapshot(app, obj, "remesh")
			// A big object remeshes on a thread of its own while the frame goes on.
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, before)
			changed, ok := object_remesh(app, obj, cmd.vertices, cmd.remesh)
			if !ok {
				// The old mesh is gone; drop the empty object rather than draw nothing.
				history_snapshot_drop(before)
				scene_delete_selected(app, undoable = false)
				return false
			}
			if changed do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
		}
	case .Layout_Uvs:
		if obj := selected_object(app); obj != nil do object_layout_uvs(app, obj)
	case .Remove_Textures:
		texture_remove(app, selected_object(app))
	case .Retopo:
		if obj := selected_object(app); obj != nil {
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, nil)
			made, ok := object_retopo(app, obj, cmd.vertices, cmd.quad)
			if made do history_record_added(app)
			return ok
		}
	case .Voxel_To_Mesh:
		if obj := selected_object(app); obj != nil && obj.voxel != nil {
			before := history_snapshot(app, obj, "convert to mesh")
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, before)
			if !object_voxel_to_mesh(app, obj) {
				// The clay is gone; drop the empty object rather than draw nothing.
				history_snapshot_drop(before)
				scene_delete_selected(app, undoable = false)
				return false
			}
			history_record_swap(app, obj.id, before)
		}
	case .Mesh_To_Voxels:
		if obj := selected_object(app); obj != nil && obj.voxel == nil {
			before := history_snapshot(app, obj, "convert to voxels")
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, before)
			changed, ok := object_mesh_to_voxels(app, obj, cmd.voxels)
			if !ok {
				// The mesh is gone; drop the empty object rather than draw nothing.
				history_snapshot_drop(before)
				scene_delete_selected(app, undoable = false)
				return false
			}
			if changed do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
		}
	case .Voxel_Resample:
		if obj := selected_object(app); obj != nil && obj.voxel != nil && voxel_resample_allowed(obj, cmd.voxels) {
			before := history_snapshot(app, obj, "voxel resolution")
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, before)
			if object_voxel_resample(app, obj, cmd.voxels) do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
		}
	case .Delete:
		// Every selected object, as one undo step. The ids are copied out of temp memory,
		// which taking a snapshot may free.
		ids := slice.clone(selection_ids(app))
		defer delete(ids)
		for id, k in ids {
			select_object(app, object_by_id(app, id))
			scene_delete_selected(app, chain = k > 0)
		}
	case .Duplicate:
		// Every selected object, as one undo step; the copies keep their spacing, moved as
		// the primary's copy is, and become the selection.
		ids := slice.clone(selection_ids(app))
		defer delete(ids)
		copies := make([dynamic]int, 0, len(ids))
		defer delete(copies)
		primary_from, primary_to: Transform
		for id in ids {
			obj := object_by_id(app, id)
			if obj == nil do continue
			from := obj.transform
			count := len(app.scene.objects)
			if !scene_duplicate(app, obj) do return false
			if len(app.scene.objects) == count do continue
			twin := selected_object(app)
			if len(copies) == 0 do primary_from, primary_to = from, twin.transform
			else do twin.transform = transform_follow(primary_from, primary_to, from)
			history_record_swap(app, twin.id, history_snapshot(app, nil, "add object"), chain = len(copies) > 0)
			append(&copies, twin.id)
		}
		selection_set(app, copies[:])
	case .Decimate:
		if obj := selected_object(app); obj != nil {
			// A share becomes a count of the object as it is now, so the job, the result
			// line and Adjust last's rerun (from the object as it was) all agree.
			cmd := cmd
			cmd.vertices = decimate_target(object_vertex_count(obj), cmd.vertices, cmd.decimate)
			before := history_snapshot(app, obj, "decimate")
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, before)
			changed, ok := object_decimate(app, obj, cmd.vertices, cmd.decimate)
			if !ok {
				history_snapshot_drop(before)
				scene_delete_selected(app, undoable = false)
				return false
			}
			if changed do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
		}
	case .Symmetrize:
		if obj := selected_object(app); obj != nil {
			before := history_snapshot(app, obj, "mirror and weld")
			changed, ok := object_symmetrize(app, obj, cmd.axis, cmd.on)
			if !ok {
				history_snapshot_drop(before)
				scene_delete_selected(app, undoable = false)
				return false
			}
			if changed do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
		}
	case .Knife:
		if obj := selected_object(app); obj != nil {
			before := history_snapshot(app, obj, "knife")
			changed, ok := object_knife(app, obj, cmd.point, cmd.normal)
			if !ok {
				history_snapshot_drop(before)
				scene_delete_selected(app, undoable = false)
				return false
			}
			if changed do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
		}
	case .Slice:
		if obj := selected_object(app); obj != nil {
			before := history_snapshot(app, obj, "slice")
			part, changed, ok := object_slice(app, obj, cmd.point, cmd.normal)
			if !changed {
				history_snapshot_drop(before)
				if !ok do scene_delete_selected(app, undoable = false)
				return ok
			}
			history_record_swap(app, obj.id, before)
			if part != nil do history_record_swap(app, part.id, history_snapshot(app, nil, "slice"), chain = true)
			return ok
		}
	case .Repair:
		obj := selected_object(app)
		if obj == nil || cmd.repair == .Check_Mesh do return true
		before := history_snapshot(app, obj, REPAIR_UNDO_NAMES[cmd.repair])
		changed, ok := object_repair(app, obj, cmd)
		if !ok {
			history_snapshot_drop(before)
			scene_delete_selected(app, undoable = false)
			return false
		}
		if changed do history_record_swap(app, obj.id, before)
		else do history_snapshot_drop(before)
	case .Boolean:
		return boolean_make(app)
	case .Extract:
		return extract_masked(app)
	case .View:
		scene_view(app, cmd.view, cmd.id, cmd.space)
	case .Material:
		material_command(app, cmd.material, cmd.material_to, cmd.preview)
	case .Group_Material:
		group_material_apply(app, cmd)
	case .Arrange:
		scene_arrange(app, cmd)
	case .Copy:
		if obj := selected_object(app); obj != nil do scene_copy(app, obj)
	case .Paste:
		return scene_paste(app)
	case .Delete_Others:
		scene_delete_others(app, cmd.on)
	case .Split:
		obj := selected_object(app)
		if obj == nil do return true
		before := history_snapshot(app, obj, "split")
		parts, changed, ok := object_split(app, obj, cmd.split)
		defer delete(parts)
		if !changed {
			history_snapshot_drop(before)
			if !ok do scene_delete_selected(app, undoable = false)
			return ok
		}
		// The object and every part it made, as one step.
		history_record_swap(app, obj.id, before)
		for id in parts do history_record_swap(app, id, history_snapshot(app, nil, "split"), chain = true)
		report(app, nil, {.Undo}, "%s: %d objects", SPLIT_NAMES[cmd.split], len(parts) + 1)
		return ok
	case .Merge:
		return merge_visible(app, cmd.id) if cmd.on else merge_down(app)
	case .Align:
		align_objects(app, cmd.axis, cmd.edge)
	case .Distribute:
		distribute_objects(app, cmd.axis, cmd.edge)
	case .Levels_All:
		// Not an undo step, as choosing a level with its slider is not.
		for obj in app.scene.objects {
			if !object_set_level(app, obj, len(obj.levels.levels) - 1 if cmd.on else 0) do return false
		}
	case .Dyntopo:
		if obj := selected_object(app); obj != nil {
			object_hd_leave(app, obj)
			before := history_snapshot(app, obj, "dynamic topology on" if cmd.on else "dynamic topology off")
			sets := len(sculpt.levels_sets(&obj.levels))
			changed, ok := object_set_dyntopo(app, obj, cmd.on)
			if changed do history_record_swap(app, obj.id, before)
			else do history_snapshot_drop(before)
			// Its vertices are numbered afresh, so the selection sets went; Undo brings them back.
			if changed && cmd.on && sets > 0 {
				report(app, Kit_Section.Topology, {.Undo}, "Dynamic topology on: %d selection set%s went, as the vertices are numbered afresh", sets, "" if sets == 1 else "s")
				app.sets_noted = sets
			}
			return ok
		}
	case .Hd_Enter:
		origin, dir := mouse_ray(app.camera, cmd.at, cmd.size)
		index, hit, ok := scene_raycast(app, origin, dir)
		if !ok {
			log.info("HD: point at an object to sculpt HD around that point")
			return true
		}
		app.scene.selected = index
		return object_hd_enter(app, selected_object(app), to_local(selected_object(app).transform, hit))
	case .Hd_Leave:
		if obj := selected_object(app); obj != nil do object_hd_leave(app, obj)
	case .Hd_Steps, .Hd_Delete:
		obj := selected_object(app)
		if obj == nil do return true
		object_hd_leave(app, obj)
		if cmd.kind == .Hd_Delete {
			sculpt.levels_hd_delete(&obj.levels)
		} else if object_dynamic(obj) {
			log.warn("HD: turn dynamic topology off first")
		} else if !sculpt.levels_hd_set_steps(&obj.levels, cmd.level) {
			log.warn("HD: steps change only while no HD detail is stored, on a closed mesh with every edge between two triangles")
		}
	case .Subdivide, .Set_Level, .Delete_Higher, .Delete_Lower:
		obj := selected_object(app)
		if obj == nil do return true
		if cmd.kind == .Delete_Lower && obj.levels.current == 0 do return true
		if cmd.kind == .Delete_Higher && obj.levels.current == len(obj.levels.levels) - 1 do return true
		stroke_finish(app)
		if cmd.kind != .Set_Level do object_hd_leave(app, obj)
		start := time.tick_now()
		levels := &obj.levels
		#partial switch cmd.kind {
		case .Subdivide:
			if _, _, bytes := sculpt.levels_subdivide_estimate(levels); bytes > MAX_SUBDIVIDE_BYTES {
				log.warnf("subdivide: the new level would need about %d MB; the limit is %d MB", bytes >> 20, MAX_SUBDIVIDE_BYTES >> 20)
				return true
			}
			if levels.hd.steps > 0 {
				log.warn("subdivide: delete the HD level first; its detail is tied to the top level as it is")
				return true
			}
			if object_dynamic(obj) {
				log.warn("subdivide: turn dynamic topology off first")
				return true
			}
			// The top level's sculpt layers move up to the new level, which leaves the old
			// top's undo steps naming layers it no longer has; so a layered Subdivide
			// clears the object's strokes and is an undo step of its own, a swap that puts
			// the old levels back with their layers.
			layers := len(levels.levels[len(levels.levels) - 1].sculptor.layers.list)
			before: ^Object_Snapshot
			if layers > 0 do before = history_snapshot(app, obj, "subdivide")
			// A big object's new level is built on a thread of its own while the frame
			// goes on; long_job_frame then adds it as below.
			if long_job_async(app, obj, cmd) do return long_job_start(app, cmd, obj, before)
			if !sculpt.levels_subdivide(levels, carry_layers = layers > 0) {
				if before != nil do history_snapshot_drop(before)
				log.warn("subdivide: needs a closed mesh with every edge between two triangles")
				return true
			}
			subdivide_record(app, obj, before, layers)
		case .Set_Level:
			return object_set_level(app, obj, cmd.level)
		case .Delete_Higher:
			history_record_swap(app, obj.id, history_snapshot(app, obj, "delete higher levels"))
			render.wait_idle(&app.renderer)
			for i in levels.current + 1 ..< len(levels.levels) {
				render.mesh_buffers_destroy(&app.renderer, &obj.gpu[i])
				obj.poly_edges[i] = {}
			}
			carried, dropped := sculpt.levels_delete_higher(levels)
			app.layers_kept += carried
			app.layers_lost += dropped
			object_forget_history(app, obj)
		case .Delete_Lower:
			k := levels.current
			history_record_swap(app, obj.id, history_snapshot(app, obj, "delete lower levels"))
			render.wait_idle(&app.renderer)
			for i in 0 ..< k do render.mesh_buffers_destroy(&app.renderer, &obj.gpu[i])
			sculpt.levels_delete_lower(levels)
			// The buffers move down with their levels, and so does what edges they hold.
			copy(obj.gpu[:], obj.gpu[k:])
			copy(obj.poly_edges[:], obj.poly_edges[k:])
			for i in sculpt.MAX_LEVELS - k ..< sculpt.MAX_LEVELS do obj.gpu[i], obj.poly_edges[i] = {}, {}
			object_forget_history(app, obj)
		}
		return object_show_level(app, obj, start)
	}
	return true
}

// What a Subdivide does once its level is added: with `layers` carried up, the swap undo
// step from `before` and the object's strokes cleared (scene_apply says why), then the log.
subdivide_record :: proc(app: ^App, obj: ^Object, before: ^Object_Snapshot, layers: int) {
	if before != nil {
		history_record_swap(app, obj.id, before)
		object_forget_history(app, obj)
		app.layers_kept += layers
	}
	log.infof("subdivide: level %d has %d vertices, %d triangles", obj.levels.current + 1,
		geom.mesh_vertex_count(object_mesh(obj)^), geom.mesh_triangle_count(object_mesh(obj)^))
}

// Makes `level` the object's current level, carrying the edits on the one it leaves to
// all the others, after leaving any HD window. Returns false on a GPU failure.
object_set_level :: proc(app: ^App, obj: ^Object, level: int) -> bool {
	object_hd_leave(app, obj)
	if clamp(level, 0, len(obj.levels.levels) - 1) == obj.levels.current do return true
	// Leaving the level carries its edits to the others, so its last stroke is no longer
	// one step to adjust there.
	if app.adjustable.op == .Stroke do app.adjustable.op = .None
	start := time.tick_now()
	sculpt.levels_set_current(&obj.levels, level)
	return object_show_level(app, obj, start)
}

// Largest new level Subdivide makes, in CPU memory.
MAX_SUBDIVIDE_BYTES :: 12 << 30

// Brings the current level's normals and GPU buffers up to date after it became
// current: uploads what changed while it was not, or everything the first time it is
// shown. `start` is when the level change began, for the stats. Returns false on a GPU
// failure.
object_show_level :: proc(app: ^App, obj: ^Object, start: time.Tick) -> bool {
	synced := time.tick_now()
	defer {
		app.stats.level_sync_ms = time.duration_milliseconds(time.tick_diff(start, synced))
		app.stats.level_show_ms = time.duration_milliseconds(time.tick_since(synced))
	}
	lv := object_level(obj)
	ranges := sculpt.sculptor_flush(&lv.sculptor)
	gpu := object_gpu(obj)
	if gpu.positions == nil {
		ok: bool
		gpu^, ok = render.mesh_buffers_create(&app.renderer, lv.mesh, lv.sculptor.mask)
		return ok
	}
	if len(ranges) == 0 && len(sculpt.sculptor_index_ranges(&lv.sculptor)) == 0 do return true
	cmd := render.cmd_begin(&app.renderer)
	if cmd == nil do return false
	_, ok := level_upload(app, cmd, gpu, lv, ranges)
	return render.cmd_submit(cmd) && ok
}

// Starts sculpting the object's HD level in a window around `at` (in the object's
// space), on its top level: the window is what brushes reach, and what is drawn there.
// Does nothing without an HD level. Returns false on a GPU failure.
object_hd_enter :: proc(app: ^App, obj: ^Object, at: Vec3) -> bool {
	if obj.levels.hd.steps == 0 {
		log.info("HD: add an HD level first (Divide HD)")
		return true
	}
	stroke_finish(app)
	// One window at a time, since each can hold millions of vertices.
	for other in app.scene.objects do if other != obj do object_hd_leave(app, other)
	if !object_set_level(app, obj, len(obj.levels.levels) - 1) do return false
	// The window is built from the top level's triangles, hidden or not.
	if sculpt.sculptor_hidden_count(object_sculptor(obj)) > 0 {
		log.warn("HD: show everything first (Ctrl+Shift click, or Ctrl+H)")
		return true
	}
	start := time.tick_now()
	if !sculpt.levels_hd_enter(&obj.levels, at, app.hd_window_vertices) do return true
	built := time.tick_now()
	ok: bool
	obj.hd_gpu, ok = render.mesh_buffers_create(&app.renderer, object_mesh(obj)^, object_sculptor(obj).mask)
	if !ok {
		sculpt.levels_hd_leave(&obj.levels)
		return false
	}
	render.viewport_invalidate(&app.target)
	app.stats.hd_open_ms = time.duration_milliseconds(time.tick_diff(start, built))
	app.stats.hd_upload_ms = time.duration_milliseconds(time.tick_since(built))
	log.infof("HD: window of %d vertices built in %.0f ms, uploaded in %.0f ms", geom.mesh_vertex_count(object_mesh(obj)^), app.stats.hd_open_ms, app.stats.hd_upload_ms)
	return true
}

// Stores what the HD window changed and closes it, dropping its strokes from the undo
// history. Does nothing outside HD.
object_hd_leave :: proc(app: ^App, obj: ^Object) {
	if !object_in_hd(obj) do return
	if app.stroke.object == obj.id do stroke_finish(app)
	start := time.tick_now()
	render.wait_idle(&app.renderer)
	render.mesh_buffers_destroy(&app.renderer, &obj.hd_gpu)
	sculpt.levels_hd_leave(&obj.levels)
	history_forget_level(app, obj.id, HD_LEVEL)
	render.viewport_invalidate(&app.target)
	app.stats.hd_leave_ms = time.duration_milliseconds(time.tick_since(start))
}

// Just to the right of everything already in the scene, so a new sphere never lands
// inside another one.
next_free_position :: proc(app: ^App) -> Vec3 {
	if len(app.scene.objects) == 0 do return {}
	right := min(f32)
	for obj in app.scene.objects {
		right = max(right, obj.transform.position.x + obj.transform.scale)
	}
	return {right + 1.25, 0, 0}
}

// Nearest object a press can pick hit by a world-space ray (dir normalised). The hit is
// in world space.
scene_raycast :: proc(app: ^App, origin, dir: Vec3) -> (index: int, hit: Vec3, ok: bool) {
	best := max(f32)
	for obj, i in app.scene.objects {
		if !object_pickable(app, obj) do continue
		t := obj.transform
		local_hit, _, local_ok := object_raycast_local(obj, to_local(t, origin), to_local_dir(t, dir))
		if !local_ok do continue
		world_hit := to_world(t, local_hit)
		if d := linalg.length(world_hit - origin); d < best {
			best, index, hit, ok = d, i, world_hit, true
		}
	}
	return
}

// For a Grab pressed off the model: the surface point nearest the pointer's ray within the
// brush ring, over every mesh object, the nearest on screen winning (the first object on a
// tie). Each object's ring is its radius at the object's middle's distance.
scene_grab_near :: proc(app: ^App, origin, dir: Vec3, size: [2]f32) -> (index: int, hit: Vec3, ok: bool) {
	best := max(f32)
	for obj, i in app.scene.objects {
		if !object_pickable(app, obj) || obj.voxel != nil do continue
		t := obj.transform
		per_px := camera.orbit_world_per_px(app.camera, to_world(t, object_local_middle(obj)), size.y)
		local, found := sculpt.sculptor_nearest_to_line(object_sculptor(obj), to_local(t, origin), to_local_dir(t, dir), app.brush.radius_px * per_px / t.scale)
		if !found do continue
		world := to_world(t, local)
		along := linalg.dot(world - origin, dir)
		px := linalg.length(world - origin - dir * along) / camera.orbit_world_per_px(app.camera, world, size.y)
		if px < best do best, index, hit, ok = px, i, world, true
	}
	return
}

@(private = "file")
object_build :: proc(app: ^App, obj: ^Object, vertices, subdiv: int) -> bool {
	start := time.tick_now()
	mesh: geom.Mesh
	if vertices > 0 {
		mesh = geom.geodesic_sphere(geom.geodesic_frequency_for(vertices), &app.pool)
	} else {
		mesh = geom.icosphere(subdiv)
	}
	return object_build_from(app, obj, mesh, start)
}

// Makes `mesh` the object's only level, prepares it for sculpting and uploads it,
// computing its normals first when `normals` is set, and giving it `surface`'s polypaint
// and polygroups (per vertex and triangle of `mesh`; not temporary, as building frees the
// temp allocator). `start` is when building the mesh began, for the log. `old_to_new` and
// `tri_from` (not temporary either) receive the renumbering of the mesh's vertices and,
// per triangle of the level, its triangle in `mesh`, for a caller that keeps maps into the
// level, as a cage does (model.odin). With `prepared`, levels a long job's thread already
// made from `mesh` (normals included), those are taken instead and only the upload is left.
object_build_from :: proc(app: ^App, obj: ^Object, mesh: geom.Mesh, start: time.Tick, normals := false, old_to_new: []u32 = nil, surface: Surface = {}, tri_from: []u32 = nil, prepared: ^sculpt.Levels = nil) -> bool {
	// Without groups the table has nothing to shade (a remesh, a slice's halves).
	if surface.groups == nil && (prepared == nil || !sculpt.sculptor_has_groups(&prepared.levels[0].sculptor)) {
		autosave_settle(app)
		clear(&obj.group_materials)
	}
	if prepared != nil {
		// A long job's thread made the levels from `mesh`, normals and all
		// (long_job_prepare); they take the app's workers from here on.
		assert(surface.color == nil && surface.groups == nil && old_to_new == nil && tri_from == nil)
		obj.levels = prepared^
		prepared^ = {}
		sculpt.levels_set_pool(&obj.levels, &app.pool)
	} else if surface.color == nil && surface.groups == nil {
		sculpt.levels_init(&obj.levels, mesh, &app.pool, old_to_new = old_to_new, tri_from = tri_from)
	} else {
		// The surface's parts follow the renumbering onto the level.
		renumbered := old_to_new if old_to_new != nil else make([]u32, len(mesh.positions), context.temp_allocator)
		from := tri_from if tri_from != nil else make([]u32, len(mesh.indices) / 3, context.temp_allocator)
		sculpt.levels_init(&obj.levels, mesh, &app.pool, old_to_new = renumbered, tri_from = from)
		sculpt.levels_take_surface(&obj.levels, surface.color, surface.groups, renumbered, from)
	}
	if normals && prepared == nil do sculpt.sculptor_recompute_all(object_sculptor(obj))
	free_all(context.temp_allocator)
	ready := time.tick_now()
	mesh_gpu, ok := render.mesh_buffers_create(&app.renderer, object_mesh(obj)^, object_sculptor(obj).mask)
	if !ok {
		sculpt.levels_destroy(&obj.levels)
		return false
	}
	obj.gpu[0] = mesh_gpu
	log.infof("mesh: %d vertices, %d triangles; ready to sculpt in %.0f ms, uploaded in %.0f ms",
		geom.mesh_vertex_count(object_mesh(obj)^), geom.mesh_triangle_count(object_mesh(obj)^),
		time.duration_milliseconds(time.tick_diff(start, ready)), time.duration_milliseconds(time.tick_since(ready)))
	app.stats = {}
	return true
}

// Rebuilds the object from `mesh` (taking it), as a remesh does: its levels, HD
// detail, mask and strokes go (the caller records the swap). Returns false only when
// the new mesh could not be uploaded.
object_replace_mesh :: proc(app: ^App, obj: ^Object, mesh: geom.Mesh) -> bool {
	start := time.tick_now()
	render.wait_idle(&app.renderer)
	return object_rebuild(app, obj, mesh, start, normals = true)
}

// Rebuilds the object from `mesh` (taking it), a new surface for the level it is on: its
// levels, HD detail, mask and strokes go, but that level's sculpt layers come across
// (sculpt layer_carry.odin), mirrored as Mirror and weld made it, and `surface` gives
// its polypaint and polygroups (a repair's). `normals` works out the mesh's normals, for
// a mesh that comes without them. `old_to_new` and `tri_from` (not temporary) receive the
// renumbering, as object_build_from fills them, for a caller that keeps maps into the
// level. The caller waits for the GPU first. Returns false only when the new mesh could
// not be uploaded.
object_rebuild :: proc(app: ^App, obj: ^Object, mesh: geom.Mesh, start: time.Tick, normals: bool, mirror: sculpt.Surface_Mirror = {}, surface: Surface = {}, prepared: ^sculpt.Levels = nil, old_to_new: []u32 = nil, tri_from: []u32 = nil) -> bool {
	layered := object_take_layered(app, obj)
	defer sculpt.layered_level_free(&layered)
	object_release_mesh(app, obj)
	if !object_build_from(app, obj, mesh, start, normals = normals, surface = surface, prepared = prepared, old_to_new = old_to_new, tri_from = tri_from) do return false
	object_carry_layers(app, obj, layered, mirror)
	return true
}

// Takes the level the object is on out of its levels when it has layers, for
// object_carry_layers after the rebuild; the layers of the other levels go, counted for
// the command's note.
object_take_layered :: proc(app: ^App, obj: ^Object) -> sculpt.Layered_Level {
	app.layers_lost += sculpt.levels_layer_count(&obj.levels)
	return sculpt.levels_take_layered(&obj.levels)
}

// Gives the rebuilt object the taken level's layers, counting them for the note unless
// `counted` already did (the second part of a slice).
object_carry_layers :: proc(app: ^App, obj: ^Object, layered: sculpt.Layered_Level, mirror: sculpt.Surface_Mirror = {}, counted := true) {
	if layered.level == nil do return
	start := time.tick_now()
	kept := sculpt.levels_carry_layers(&obj.levels, layered, mirror)
	if counted {
		app.layers_kept += kept
		app.layers_lost -= kept
	}
	ms := time.duration_milliseconds(time.tick_since(start))
	app.stats.layers_carry_ms += ms
	log.infof("layers: carried %d onto the rebuilt mesh in %.0f ms", kept, ms)
}

// Frees the levels and GPU buffers. The caller waits for the GPU first. A rebuild
// (`rebuild`) counts the selection sets that go for the command's note.
object_release_mesh :: proc(app: ^App, obj: ^Object, rebuild := true) {
	if rebuild do app.sets_lost += len(sculpt.levels_sets(&obj.levels))
	if app.stroke.object == obj.id do app.stroke.active = false
	history_forget_strokes(app, obj.id)
	for &gpu in obj.gpu do render.mesh_buffers_destroy(&app.renderer, &gpu)
	obj.poly_edges = {}
	render.mesh_buffers_destroy(&app.renderer, &obj.hd_gpu)
	texture_preview_release(app, obj)
	sculpt.levels_destroy(&obj.levels)
	voxel_part_free(app, obj)
	cage_part_free(obj)
}

object_free :: proc(app: ^App, obj: ^Object) {
	object_release_mesh(app, obj, rebuild = false)
	delete(obj.name)
	delete(obj.group_materials)
	textures_free(&obj.textures)
	free(obj)
}
