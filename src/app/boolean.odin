package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../render"
import "../sculpt"
import "../ui"
import "../voxel"

// Booleans and Extract on the app side, after ZBrush's Live Boolean: each object can be
// marked Union, Subtract or Intersect, and those apply, in scene order, to the base, the
// first object left unmarked. With Live boolean on, the result is shown in their place
// (a preview at Live vertices, made again whenever one of them changes and nothing is
// being dragged or sculpted); Make boolean mesh replaces the base with the result at
// Vertices and takes the marked objects out, as one undo step. Extract makes a new
// object, a shell over the selected object's masked part.
//
// A voxel base takes the marks on its field (voxel.clay_combine), as 3D-Coat's voxel room
// and OpenVDB do: the result is clay at the base's resolution, with Blend rounding the seam
// (Houdini's SDF blend), and a mesh mark is voxelised in the base's space first. The
// preview is made on a copy of the base at most BOOLEAN_PREVIEW_ACROSS voxels across, as
// Nomad previews on a coarser lattice, and that copy is kept while the base is unchanged.
// A voxel mark on a mesh base takes part as its welded surface.

Boolean_Mode :: enum u8 {
	None,
	Union,
	Subtract,
	Intersect,
}

BOOLEAN_OPS := [Boolean_Mode]geom.Remesh_Op {
	.None      = .Merge,
	.Union     = .Union,
	.Subtract  = .Subtract,
	.Intersect = .Intersect,
}

Boolean_State :: struct {
	live:          bool,
	live_vertices: i32,
	vertices:      i32,
	preview:       render.Mesh_Buffers, // the live result, in the base's space
	shown:         bool,                // preview holds the result for `stamp`
	stamp:         u64,
	base:          int,                 // id of the base the preview was made for
	ms:            f64,                 // time the last preview took
	thickness:     f32,                 // Extract: shell thickness, a share of the object's size
	blend:         f32,                 // a voxel base: how wide the seam is rounded, in its voxels
	coarse:        ^voxel.Clay,         // a voxel base's clay at preview resolution, nil until a preview is made...
	coarse_base:   int,                 // ...for this base...
	coarse_edits:  u64,                 // ...in this state (Voxel_Part.edits)
}

// The op a mark stands for on a field (None never reaches a combine).
CLAY_OPS := [Boolean_Mode]voxel.Clay_Op {
	.None      = .Union,
	.Union     = .Union,
	.Subtract  = .Subtract,
	.Intersect = .Intersect,
}

// The most voxels across a preview's clay has: Res− steps on the copy bring a finer base
// down to it.
BOOLEAN_PREVIEW_ACROSS :: 256

// The base: the first object not marked; nil when there is none or nothing is marked.
boolean_base :: proc(app: ^App) -> ^Object {
	base: ^Object
	marked := false
	for obj in app.scene.objects {
		if obj.boolean == .None {
			if base == nil do base = obj
		} else {
			marked = true
		}
	}
	return base if marked else nil
}

// The shape of `obj`'s shown level in the space `into` places (a copy, with zero normals),
// without the unused slots of dynamic topology's layout; a voxel object's welded surface.
shape_in :: proc(obj: ^Object, into: Transform) -> geom.Mesh {
	if obj.voxel != nil {
		out := voxel.clay_to_mesh(&obj.voxel.clay)
		for &p in out.positions do p = to_local(into, to_world(obj.transform, p))
		return out
	}
	src := object_mesh(obj)^
	packed: geom.Mesh
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		src = packed
	}
	out := geom.Mesh {
		positions = make([dynamic]geom.Vec3, len(src.positions)),
		indices   = make([dynamic]u32, len(src.indices)),
		normals   = make([dynamic]geom.Vec3, len(src.positions)),
	}
	copy(out.indices[:], src.indices[:])
	for p, v in src.positions do out.positions[v] = to_local(into, to_world(obj.transform, p))
	geom.mesh_destroy(&packed)
	return out
}

// The base with every marked object applied, at about `vertices` vertices.
@(private = "file")
boolean_result :: proc(app: ^App, base: ^Object, vertices: int, project: bool) -> (out: geom.Mesh, ok: bool) {
	out = shape_in(base, base.transform)
	for obj in app.scene.objects {
		if obj.boolean == .None do continue
		other := shape_in(obj, base.transform)
		next, made := geom.mesh_boolean(out, other, BOOLEAN_OPS[obj.boolean], vertices, project, &app.pool)
		geom.mesh_destroy(&other)
		geom.mesh_destroy(&out)
		free_all(context.temp_allocator)
		if !made do return {}, false
		out = next
	}
	return out, true
}

// Applies the marked objects, in scene order, to `c`, a clay in `base`'s space (a copy of
// the base's, at its resolution or coarser). A voxel mark is read through the two
// placings; a mesh mark is voxelised at the clay's voxel size in the base's space first.
// False when the result holds no clay, or a mark has no volume to voxelise (said in a
// warning); the clay is then whatever the last combine left.
@(private = "file")
boolean_apply :: proc(app: ^App, base: ^Object, c: ^voxel.Clay) -> bool {
	base_world := transform_matrix(base.transform)
	blend := app.ui.boolean.blend
	for obj in app.scene.objects {
		if obj.boolean == .None do continue
		op := CLAY_OPS[obj.boolean]
		kept: bool
		if obj.voxel != nil {
			// A point of the base's space into the mark's, through the world; one of the
			// mark's units is this many of the base's.
			to_other := linalg.inverse(transform_matrix(obj.transform)) * base_world
			kept = voxel.clay_combine(c, &obj.voxel.clay.volume, to_other, obj.transform.scale / base.transform.scale, op, blend)
		} else {
			mesh := shape_in(obj, base.transform)
			other: voxel.Clay
			built := voxel.clay_from_mesh(&other, mesh, c.volume.voxel, &app.pool)
			geom.mesh_destroy(&mesh)
			if !built {
				log.warnf("boolean: %s has no volume to voxelise at the base's voxel size", object_label(obj))
				return false
			}
			kept = voxel.clay_combine(c, &other.volume, linalg.MATRIX4F32_IDENTITY, 1, op, blend)
			voxel.clay_destroy(&other)
		}
		if !kept do return false
	}
	return true
}

// The voxel base's clay at preview resolution: a copy, brought down to
// BOOLEAN_PREVIEW_ACROSS by Res− steps, kept until the base or its clay changes.
@(private = "file")
boolean_coarse :: proc(app: ^App, base: ^Object) -> ^voxel.Clay {
	b := &app.ui.boolean
	vp := base.voxel
	if b.coarse != nil && b.coarse_base == base.id && b.coarse_edits == vp.edits do return b.coarse
	boolean_coarse_drop(app)
	b.coarse = new(voxel.Clay)
	voxel.clay_copy(b.coarse, &vp.clay)
	resolution := vp.resolution
	for resolution > BOOLEAN_PREVIEW_ACROSS && resolution / 2 >= VOXELS_MIN && voxel.clay_resample(b.coarse, voxel.RESAMPLE_DOWN) do resolution /= 2
	b.coarse_base, b.coarse_edits = base.id, vp.edits
	return b.coarse
}

// Frees the kept preview clay, if there is one.
boolean_coarse_drop :: proc(app: ^App) {
	b := &app.ui.boolean
	if b.coarse == nil do return
	voxel.clay_destroy(b.coarse)
	free(b.coarse)
	b.coarse = nil
}

// The live preview's mesh: the mesh result at Live vertices, or for a voxel base the
// marks applied to the coarse copy and its surface welded.
@(private = "file")
boolean_preview :: proc(app: ^App, base: ^Object) -> (geom.Mesh, bool) {
	if base.voxel == nil do return boolean_result(app, base, int(app.ui.boolean.live_vertices), project = true)
	c: voxel.Clay
	voxel.clay_copy(&c, boolean_coarse(app, base))
	defer voxel.clay_destroy(&c)
	if !boolean_apply(app, base, &c) do return {}, false
	return voxel.clay_to_mesh(&c), true
}

// What the preview depends on: which objects, how marked, where, and how edited.
@(private = "file")
boolean_stamp :: proc(app: ^App) -> u64 {
	h := u64(14695981039346656037)
	mix :: proc(h: ^u64, x: u64) {h^ = (h^ ~ x) * 1099511628211}
	for obj in app.scene.objects {
		mix(&h, u64(obj.id))
		mix(&h, u64(obj.boolean))
		t := obj.transform
		for x in ([7]f32{t.position.x, t.position.y, t.position.z, t.scale, t.rotation.x, t.rotation.y, t.rotation.z}) do mix(&h, u64(transmute(u32)x))
		s := object_sculptor(obj)
		mix(&h, u64(len(s.history.done)) << 32 | u64(len(s.history.undone)))
		mix(&h, u64(obj.levels.current) << 32 | u64(object_vertex_count(obj)))
		if obj.voxel != nil do mix(&h, obj.voxel.edits)
	}
	mix(&h, u64(app.ui.boolean.live_vertices))
	mix(&h, u64(transmute(u32)app.ui.boolean.blend))
	return h
}

// Makes the live preview again when what it shows changed and nothing is held down.
// Returns false only on a GPU failure.
boolean_live_update :: proc(app: ^App) -> bool {
	b := &app.ui.boolean
	base := boolean_base(app) if b.live else nil
	if base == nil {
		b.shown = false
		return true
	}
	stamp := boolean_stamp(app)
	if b.shown && stamp == b.stamp && b.base == base.id do return true
	if app.stroke.active || move_busy(app) || .Left in app.device.down do return true
	start := time.tick_now()
	mesh, ok := boolean_preview(app, base)
	b.stamp, b.base = stamp, base.id
	if b.shown do _ = sdl.WaitForGPUIdle(app.renderer.device)
	render.mesh_buffers_destroy(&app.renderer, &b.preview)
	b.shown = false
	if !ok {
		log.warn("live boolean: the result is empty")
		return true
	}
	defer geom.mesh_destroy(&mesh)
	preview, made := render.mesh_buffers_create(&app.renderer, mesh, nil)
	if !made do return false
	b.preview, b.shown = preview, true
	b.ms = time.duration_milliseconds(time.tick_since(start))
	render.viewport_invalidate(&app.target)
	return true
}

// Whether the live preview stands in for `obj` this frame: it does for the base and the
// marked objects, except one being moved or sculpted, which shows as it is meanwhile.
boolean_hides :: proc(app: ^App, obj: ^Object, index: int) -> bool {
	if !app.ui.boolean.shown do return false
	if obj.id != app.ui.boolean.base && obj.boolean == .None do return false
	// With its base out of view the preview is not drawn, so nothing stands in for the
	// objects it uses: they draw as themselves, as a press can still reach them.
	if base := object_by_id(app, app.ui.boolean.base); base == nil || !object_shown(app, base) do return false
	busy := app.stroke.active || move_busy(app) || .Left in app.device.down
	return !(busy && index == app.scene.selected)
}

// Replaces the base with the boolean result and removes the marked objects, as one undo
// step. Returns false only on a GPU failure.
boolean_make :: proc(app: ^App) -> bool {
	stroke_finish(app)
	base := boolean_base(app)
	if base == nil {
		log.warn("make boolean: mark an object Union, Subtract or Intersect first")
		return true
	}
	for obj in app.scene.objects do object_hd_leave(app, obj)
	start := time.tick_now()
	if vp := base.voxel; vp != nil {
		// On the field: the marks applied to a copy of the clay, which then takes the
		// clay's place; the next upload remakes the GPU copy of the new surface.
		c: voxel.Clay
		voxel.clay_copy(&c, &vp.clay)
		if !boolean_apply(app, base, &c) {
			voxel.clay_destroy(&c)
			log.warn("make boolean: the result is empty; nothing changed")
			return true
		}
		before := history_snapshot(app, base, "make boolean")
		voxel.clay_destroy(&vp.clay)
		vp.clay = c
		voxel_part_edited(vp)
		_ = voxel.clay_flush(&vp.clay)
		history_record_swap(app, base.id, before)
	} else {
		mesh, ok := boolean_result(app, base, int(app.ui.boolean.vertices), project = true)
		if !ok {
			log.warn("make boolean: the result is empty; nothing changed")
			return true
		}
		before := history_snapshot(app, base, "make boolean")
		if !object_replace_mesh(app, base, mesh) {
			history_snapshot_drop(before)
			return false
		}
		history_record_swap(app, base.id, before)
	}
	made_ms := time.duration_milliseconds(time.tick_since(start))
	// The marked objects go, each a swap entry chained to the first.
	for i := len(app.scene.objects) - 1; i >= 0; i -= 1 {
		obj := app.scene.objects[i]
		if obj.boolean == .None do continue
		app.scene.selected = i
		scene_delete_selected(app, chain = true)
	}
	for obj, i in app.scene.objects do if obj == base do app.scene.selected = i
	scene_selection_fix(app)
	app.ui.boolean.shown = false
	if vp := base.voxel; vp != nil {
		vertices, _ := voxel.surface_counts(&vp.clay.surface)
		log.infof("make boolean: clay of %d bricks, %d vertices, in %.0f ms", voxel.volume_brick_count(&vp.clay.volume), vertices, made_ms)
	} else {
		log.infof("make boolean: %d vertices in %.0f ms", object_vertex_count(base), made_ms)
	}
	return true
}

// Makes a shell over the selected object's masked part (its shown level), Thickness
// thick, as a new object in the same place. Returns false only on a GPU failure.
extract_masked :: proc(app: ^App) -> bool {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return true
	object_hd_leave(app, obj)
	s := object_sculptor(obj)
	if s.mask == nil || object_dynamic(obj) {
		log.warn("extract: mask the part to extract first (not with dynamic topology)")
		return true
	}
	m := object_mesh(obj)^
	keep := make([]bool, len(m.positions), context.temp_allocator)
	for k, v in s.mask do keep[v] = k >= 128
	bounds := geom.AABB_EMPTY
	for p in m.positions do geom.aabb_grow(&bounds, p)
	size := max(bounds.hi.x - bounds.lo.x, bounds.hi.y - bounds.lo.y, bounds.hi.z - bounds.lo.z)
	shell, ok := geom.mesh_extract_shell(m, keep, app.ui.boolean.thickness * size, 4)
	if !ok {
		log.warn("extract: nothing is masked")
		return true
	}
	name := fmt.aprintf("%s extract", object_label(obj))
	defer delete(name)
	vertices := len(shell.positions)
	if !scene_add_mesh(app, shell, name, obj.file, obj.transform, time.tick_now(), material = obj.material) do return false
	history_record_added(app)
	log.infof("extract: a shell of %d vertices from %s", vertices, object_label(obj))
	return true
}

// The interface's Booleans section.
kit_boolean_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	b := &app.ui.boolean
	if obj := selected_object(app); obj != nil {
		ui.label(ctx, "The selected object is", t.small_size)
		modes: [len(Boolean_Mode)]string
		for m, i in Boolean_Mode do modes[i] = fmt.tprint(m)
		if picked := ui.tabs(ctx, "boolean mode", modes[:], int(obj.boolean)); picked >= 0 do obj.boolean = Boolean_Mode(picked)
	}
	_ = ui.switch_row(ctx, "Live boolean", &b.live)
	base := boolean_base(app)
	if base != nil && base.voxel != nil {
		_ = ui.slider(ctx, "Blend", &b.blend, 0, 16, .Linear, fmt.tprintf("%.1f voxels", b.blend))
	} else {
		_ = kit_count(ctx, "Live vertices", &b.live_vertices, 10_000, 4_000_000)
		_ = kit_count(ctx, "Result vertices", &b.vertices, 10_000, 20_000_000)
	}
	_ = command_button(app, .Make_Boolean, variant = .Solid, tone = .Accent)
	if base != nil do ui.paragraph(ctx, fmt.tprintf("Base: %s%s%s.", object_label(base), " (clay: the marks are cut into its field, a mesh mark voxelised at its voxel size first, and Blend rounds the seam)" if base.voxel != nil else "", fmt.tprintf("; preview %.0f ms", b.ms) if b.shown else ""))
	// Hidden objects still take part, so hiding a cutter never changes the result unseen.
	hidden := 0
	for obj in app.scene.objects do if (obj.boolean != .None || obj == base) && !object_shown(app, obj) do hidden += 1
	if hidden > 0 do ui.paragraph(ctx, fmt.tprintf("%d of the objects it uses %s out of view and still %s part.", hidden, "is" if hidden == 1 else "are", "takes" if hidden == 1 else "take"))
	ui.paragraph(ctx, "Objects marked Union, Subtract or Intersect apply, in scene order, to the first object left unmarked. Live shows the result in their place; Make replaces the base with it and removes the marked ones.")
}

// The interface's Extract section.
kit_extract_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.ui.boolean
	_ = ui.slider(ctx, "Thickness", &b.thickness, 0.002, 0.2, .Logarithmic, fmt.tprintf("%.3f", b.thickness))
	_ = command_button(app, .Extract_Masked, tone = .Accent)
	ui.paragraph(ctx, "A new object: a shell over the masked part, this share of the object's size thick.")
}
