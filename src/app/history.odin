package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"
import "../voxel"

// Scene-wide undo order. Each level of each object keeps its own strokes; this records
// which object and level each stroke belongs to, newest last, so Ctrl+Z walks back
// across objects and levels. Undoing a stroke made on another level first switches the
// object to that level, as ZBrush does: strokes come back newest first on every level,
// which keeps the levels consistent with each other.
History :: struct {
	done:   [dynamic]History_Entry,
	undone: [dynamic]History_Entry,
	// What the snapshots of every swap entry in both lists take, for the limit.
	swap_bytes: int,
	// Counts every change to the lists (a step recorded, undone, redone or forgotten, or
	// all cleared), so what is derived from the sculpt (object_has_mask) knows when to
	// look again. It keeps counting across a clear, so a scene opened over another, whose
	// ids may be the old ones, still reads as changed.
	serial: u64,
	// Counts the changes serial counts that change what a scene file stores: not the
	// forgetting, and not the steps inside an HD window, whose detail no file holds.
	// The autosave's fingerprint (autosave.odin) follows it.
	edits:  u64,
	// The bytes swap snapshots may take before the oldest go; 0 for SWAP_LIMIT_BYTES (a
	// test sets a small one).
	swap_limit: int,
}

History_Entry :: struct {
	id:    int, // object
	level: int, // or HD_LEVEL: the object's HD window
	// Set for a change a stroke's undo cannot take back, because it rebuilds the object
	// or adds or removes it (remesh, dynamic topology on or off, deleting levels, adding
	// or deleting the object): the object as it was on the other side of the change.
	swap:  ^Object_Snapshot,
	// Undone and redone together with the entry before it, as one step: a slice changes
	// one object and adds another.
	chain: bool,
	// What the step was and when it was made, for the History panel's timeline.
	kind:  History_Kind,
	what:  string, // not owned: a constant
	at:    time.Tick,
	// A stroke set to a share of itself after the fact (Adjust last stroke), and the share.
	adjusted: bool,
	amount:   f32,
	// A .Transform entry's object as it was placed before the change and after it: undo
	// puts back the one, redo the other. Its level is always 0, and it outlives the
	// object's strokes, since the strokes are in the mesh's own space.
	before, after: Transform,
	// An .Arrange entry's tree before the change and after it (scene_tree.odin), owned.
	arrange: ^Arrange_Step,
	// A group command's table of group materials before and after it (group_materials.odin),
	// owned; nil when the command left the table as it was.
	group_table: ^Group_Table_Step,
}

Arrange_Step :: struct {
	before, after: ^Scene_Layout,
}

// Frees what an entry owns: a swap's snapshot, an arrangement's layouts or a group
// command's tables.
@(private = "file")
entry_free :: proc(h: ^History, e: History_Entry) {
	group_table_step_free(e.group_table)
	if e.swap != nil {
		h.swap_bytes -= len(e.swap.bytes)
		snapshot_free(e.swap)
	}
	if e.arrange != nil {
		layout_free(e.arrange.before)
		layout_free(e.arrange.after)
		free(e.arrange)
	}
}

// What kind of change a step is; the History panel colours its timeline by it.
History_Kind :: enum u8 {
	Stroke,  // a brush stroke
	Mask,    // a mask command or shape
	Hide,    // hiding or showing
	Deform,  // a whole-object deformation: Smooth all, Clip
	Rebuild, // a swap entry: the object rebuilt, added or removed
	Paint,   // a polypaint or polygroup command
	Layer,   // a sculpt layer added, removed, shown, hidden or dialled
	Transform, // the object moved, turned or scaled
	Arrange, // the tree changed: folders, names or order
}

// An object as object_put writes it, or that it did not exist. Undoing or redoing a swap
// entry trades the live object for its snapshot and keeps the live one in its place, so
// the same entry goes back and forth.
Object_Snapshot :: struct {
	exists: bool,
	index:  int, // where in the scene's list the object was
	bytes:  [dynamic]u8,
	what:   string, // the change, for the log and the undo and redo buttons' tooltips (not owned)
}

HD_LEVEL :: -1

// Swap snapshots above this many bytes in all drop the oldest ones (never the newest).
// A snapshot costs about 37 bytes a base vertex plus 12 a vertex of each level above, so
// a 10M-vertex object takes about 370 MB.
SWAP_LIMIT_BYTES :: 1536 << 20

history_destroy :: proc(h: ^History) {
	history_clear(h)
	delete(h.done)
	delete(h.undone)
	h^ = {}
}

// Drops every entry, freeing the snapshots.
history_clear :: proc(h: ^History) {
	for list in ([2]^[dynamic]History_Entry{&h.done, &h.undone}) {
		for e in list do entry_free(h, e)
		clear(list)
	}
	h.swap_bytes = 0
	h.serial += 1
	h.edits += 1
}

@(private = "file")
snapshot_free :: proc(snap: ^Object_Snapshot) {
	if snap == nil do return
	delete(snap.bytes)
	free(snap)
}

// The object as it is now, before a change that rebuilds, adds or removes it; nil for
// an object that does not exist yet. Pass it to history_record_swap once the change has
// happened, or to history_snapshot_drop if it did not.
history_snapshot :: proc(app: ^App, obj: ^Object, what: string) -> ^Object_Snapshot {
	snap := new(Object_Snapshot)
	snap.what = what
	if obj == nil do return snap
	snap.exists = true
	for o, i in app.scene.objects do if o == obj do snap.index = i
	object_put(app, &snap.bytes, obj)
	return snap
}

history_snapshot_drop :: proc(snap: ^Object_Snapshot) {snapshot_free(snap)}

// Lists a change to object `id` that `before` (from history_snapshot) undoes as the
// newest undo step, or with `chain` as part of the newest step. The object's strokes
// from before it are dropped, since the sculptors they were made with are gone.
history_record_swap :: proc(app: ^App, id: int, before: ^Object_Snapshot, chain := false) {
	history_drop_redo(app)
	history_forget_strokes(app, id)
	app.history.serial += 1
	app.history.edits += 1
	append(&app.history.done, History_Entry{id = id, swap = before, chain = chain && len(app.history.done) > 0, kind = .Rebuild, what = before.what, at = time.tick_now()})
	app.history.swap_bytes += len(before.bytes)
	// Over the limit, the oldest snapshots go, with every entry older than them, since
	// undo cannot skip a swap; strokes older than a swap are dropped anyway, so the
	// only older entries are other objects' strokes. A step goes whole, with every entry
	// chained to it, and the newest step never goes: half a step undone would leave, say,
	// a merged object beside the one merged into it.
	h := &app.history
	limit := h.swap_limit if h.swap_limit > 0 else SWAP_LIMIT_BYTES
	for h.swap_bytes > limit {
		newest := len(h.done) - 1
		for newest > 0 && h.done[newest].chain do newest -= 1
		oldest := -1
		for e, i in h.done do if e.swap != nil {oldest = i; break}
		if oldest < 0 || oldest >= newest do break
		end := oldest + 1
		for end < len(h.done) && h.done[end].chain do end += 1
		// The strokes among them stay in their sculptors, out of reach, until the
		// sculptors' own limit drops them.
		for e in h.done[:end] do entry_free(h, e)
		remove_range(&h.done, 0, end)
	}
}

// Lists adding the selected object, the one just added, as the newest undo step.
history_record_added :: proc(app: ^App) {
	if obj := selected_object(app); obj != nil do history_record_swap(app, obj.id, history_snapshot(app, nil, "add object"))
}

// What Ctrl+Z would take back, for the undo button's tooltip.
history_next_label :: proc(list: []History_Entry) -> string {
	if len(list) == 0 do return "stroke"
	e := list[len(list) - 1]
	if e.swap != nil do return e.swap.what
	if e.kind == .Transform || e.kind == .Arrange do return e.what
	return "stroke"
}

// Ends what is changing the mesh under the pointer, as its undo step when it changed
// anything: a brush stroke, or a pose of the gizmo, so whatever runs next (a command, an
// undo, a save) finds the mesh settled.
stroke_finish :: proc(app: ^App) {
	brush_stroke_finish(app)
	if app.move.drag.posed || app.move.topo.phase != .None do move_end(app)
}

// Ends the brush stroke in progress, if any, and records it when it changed the mesh.
// The frame loop calls this each frame a tool other than the brush is on, which leaves a
// pose under way alone.
brush_stroke_finish :: proc(app: ^App) {
	if !app.stroke.active do return
	app.stroke.active = false
	if st := app.stroke; st.pivot_count > 0 {
		app.pivot.object, app.pivot.at, app.pivot.set, app.pivot.pinned = st.object, st.pivot_sum / f32(st.pivot_count), true, false
	}
	// Where a stroke laying dabs ended, for the next to join (Stroke_End).
	e := &app.stroke_end
	e.valid = false
	if st := app.stroke; !st.grab && !st.hook && !st.cloth && !st.rect {
		e.valid, e.object, e.pos, e.dir, e.travel, e.size, e.camera = true, st.object, st.pos, st.dir, st.travel, st.size, app.camera
	}
	obj := object_by_id(app, app.stroke.object)
	if obj == nil do return
	if vp := obj.voxel; vp != nil {
		// The clay's stroke: its band is repaired and its step kept when it changed anything.
		if voxel.clay_stroke_end(&vp.clay) do history_record(app, obj, .Stroke, BRUSHES[app.stroke.kind].name)
		return
	}
	// A stroke joining this one keeps its locked plane, so a long Flatten laid in
	// pieces flattens to one plane.
	e.locked = sculpt.sculptor_locked_plane(object_sculptor(obj))
	sculpt.sculptor_grab_end(object_sculptor(obj))
	sculpt.sculptor_cloth_end(object_sculptor(obj))
	if sculpt.sculptor_stroke_end(object_sculptor(obj)) {
		history_record(app, obj, .Mask if .Mask in BRUSHES[app.stroke.kind].flags else .Stroke, BRUSHES[app.stroke.kind].name)
		adjust_set_stroke(app, obj)
	}
}

// Applies a mask command to the selected object as an undo step of its own; Blur,
// Sharpen, Grow and Shrink take the Mask section's step count. What it did and how long
// it took show in the Mask section, since many steps on a large mesh take a moment.
// With `toast` (a tap chose it, so nothing on screen says what ran) the result is a toast
// with Undo rather than only the Mask section's last line.
mask_command :: proc(app: ^App, command: sculpt.Mask_Command, toast := false) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	start := time.tick_now()
	steps := int(max(app.ui.mask_steps, 1))
	changed := sculpt.sculptor_mask_command(object_sculptor(obj), command, steps)
	ms := time.duration_milliseconds(time.tick_since(start))
	if changed do history_record(app, obj, .Mask, MASK_COMMAND_NAMES[command])
	// A tap that changed nothing still says so, without Undo.
	flags := Report_Flags{.Quiet}
	if toast do flags = {.Undo} if changed else {}
	report(app, Kit_Section.Mask, flags, "%s%s in %.0f ms%s", MASK_COMMAND_NAMES[command], fmt.tprintf(", %d steps", steps) if command >= .Blur else "", ms, "" if changed else ", nothing changed")
}

// Masks (or unmasks) what of the selected object falls inside `shape`, a polygon in
// normalized device coordinates, as an undo step of its own (sculpt.sculptor_mask_shape).
mask_shape_command :: proc(app: ^App, shape: [][2]f32, size: [2]f32, unmask: bool) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	start := time.tick_now()
	front: sculpt.Front_Only
	if app.brush.front_only {
		t := obj.transform
		front = {
			on       = true,
			parallel = app.camera.ortho,
			eye      = to_local(t, camera.orbit_eye(app.camera)),
			toward   = to_local_dir(t, -camera.orbit_toward(app.camera, app.camera.target)),
		}
	}
	changed := sculpt.sculptor_mask_shape(object_sculptor(obj), object_clip(app, obj, size), shape, unmask, front)
	ms := time.duration_milliseconds(time.tick_since(start))
	report(app, Kit_Section.Mask, {.Quiet}, "%s in %.0f ms%s", "Unmask shape" if unmask else "Mask shape", ms, "" if changed else ", nothing changed")
	if changed do history_record(app, obj, .Mask, "Unmask shape" if unmask else "Mask shape")
}

// Smooths the whole selected object `steps` times as an undo step of its own
// (sculpt.sculptor_smooth_all), on the GPU when the Deformation section asks and the
// compute pipeline can be made, otherwise on the CPU.
smooth_command :: proc(app: ^App, steps: int) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	start := time.tick_now()
	Gpu_Run :: struct {
		app:    ^App,
		timing: render.Smooth_Timing,
	}
	run := Gpu_Run{app = app}
	gpu: sculpt.Smooth_Gpu
	if app.ui.smooth_on_gpu && smooth_gpu_ready(app) {
		gpu = {&run, proc(data: rawptr, job: sculpt.Smooth_Gpu_Job) -> bool {
			run := cast(^Gpu_Run)data
			timing, ok := render.smooth_compute_run(&run.app.renderer, &run.app.smooth_gpu, job.positions, job.indices,
				job.faces.offsets, job.faces.tris, job.weights, job.steps, 0)
			run.timing = timing
			return ok
		}}
	}
	changed, on_gpu := sculpt.sculptor_smooth_all(object_sculptor(obj), max(steps, 1), app.ui.smooth_strength, gpu)
	ms := time.duration_milliseconds(time.tick_since(start))
	if changed do history_record(app, obj, .Deform, "Smooth all")
	report(app, Kit_Section.Deform, {.Undo} if changed else {}, "Smoothed %s: %d step%s on the %s in %.0f ms%s", object_label(obj), max(steps, 1), "" if steps <= 1 else "s", "GPU" if on_gpu else "CPU", ms, "" if changed else ", nothing changed")
	if changed do adjust_set(app, .Smooth_All, {}, obj.id)
	if t := run.timing; on_gpu do report_detail(app, "GPU: upload %.1f ms (%.0f MB), compute %.1f ms, readback %.1f ms.", t.upload_ms, t.upload_mb, t.compute_ms, t.readback_ms)
}

// Makes the compute pipeline the first time the GPU is asked to smooth. False (and the
// CPU smooths) when the device refuses it; it is not asked again.
@(private = "file")
smooth_gpu_ready :: proc(app: ^App) -> bool {
	if app.smooth_gpu.pipeline != nil do return true
	if app.smooth_gpu_failed do return false
	if !render.smooth_compute_init(&app.renderer, &app.smooth_gpu) {
		app.smooth_gpu_failed = true
		return false
	}
	return true
}

// Hides or shows all of the selected object at once, as an undo step of its own
// (sculpt.sculptor_hide_command).
hide_command :: proc(app: ^App, command: sculpt.Hide_Command) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || !hide_allowed(app, obj) do return
	start := time.tick_now()
	changed := sculpt.sculptor_hide_command(object_sculptor(obj), command)
	hide_done(app, obj, changed, start, HIDE_COMMAND_NAMES[command])
	if !changed && sculpt.sculptor_hide_refused_all(object_sculptor(obj)) {
		report(app, Kit_Section.Visibility, {.Quiet}, "%s would hide everything, so nothing changed", HIDE_COMMAND_NAMES[command])
	}
}

// Keeps only what of the selected object falls inside `shape` (a polygon in normalized
// device coordinates) shown, or with `inside` hides that, as an undo step of its own
// (sculpt.sculptor_hide_shape).
hide_shape_command :: proc(app: ^App, shape: [][2]f32, size: [2]f32, inside: bool) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil || !hide_allowed(app, obj) do return
	start := time.tick_now()
	changed := sculpt.sculptor_hide_shape(object_sculptor(obj), object_clip(app, obj, size), shape, .Hide if inside else .Show_Only)
	hide_done(app, obj, changed, start, "hide inside" if inside else "show only inside")
}

// Hides the part of `obj` on one side of the middle of its bounds across `axis` (the +
// side when `positive`), for a script's `hide`.
hide_axis :: proc(app: ^App, obj: ^Object, axis: int, positive: bool) {
	if !hide_allowed(app, obj) do return
	start := time.tick_now()
	bounds := geom.AABB_EMPTY
	for p in object_mesh(obj).positions do geom.aabb_grow(&bounds, p)
	middle := (bounds.lo + bounds.hi) / 2
	other := (axis + 1) % 3
	// The axis becomes screen x and the next one screen y, both through the middle.
	clip: matrix[4, 4]f32
	clip[0, axis], clip[0, 3] = 1, -middle[axis]
	clip[1, other], clip[1, 3] = 1, -middle[other]
	clip[3, 3] = 1
	far: f32 = 1e3
	x0, x1: f32 = 0, far
	if !positive do x0, x1 = -far, 0
	shape := [][2]f32{{x0, -far}, {x1, -far}, {x1, far}, {x0, far}}
	changed := sculpt.sculptor_hide_shape(object_sculptor(obj), clip, shape, .Hide)
	hide_done(app, obj, changed, start, "hide half")
}

// Hiding works on a level's own triangles: not in an HD window, whose sculptor fades its
// border, nor under dynamic topology, whose triangles change as it sculpts.
@(private = "file")
hide_allowed :: proc(app: ^App, obj: ^Object) -> bool {
	switch {
	case object_in_hd(obj):
		report(app, Kit_Section.Visibility, {.Warning}, "Hiding needs the HD window left first (A)")
		return false
	case object_dynamic(obj):
		report(app, Kit_Section.Visibility, {.Warning}, "Hiding does not work with dynamic topology on")
		return false
	}
	return true
}

@(private = "file")
hide_done :: proc(app: ^App, obj: ^Object, changed: bool, start: time.Tick, what: string) {
	hidden := sculpt.sculptor_hidden_count(object_sculptor(obj))
	report(app, Kit_Section.Visibility, {.Quiet}, "%s: %s of %s triangles hidden, %.0f ms%s", what, thousands(hidden), thousands(object_triangle_count(obj)), time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if !changed do return
	history_record(app, obj, .Hide, what)
	render.viewport_invalidate(&app.target)
}

// The plane through the screen line `a`-`b` (viewport pixels) and the view direction,
// in the object's space; `normal` points to the right of the drag.
screen_line_plane :: proc(app: ^App, obj: ^Object, a, b, size: [2]f32) -> (point, normal: sculpt.Vec3) {
	// Three points of the plane in the object's space: both ends of the line on the
	// near plane and one on the far plane, so the plane holds the view direction in
	// either projection, and a scaled object still gets its plane right.
	inv := linalg.inverse(object_clip(app, obj, size))
	at :: proc(inv: matrix[4, 4]f32, p, size: [2]f32, depth: f32) -> sculpt.Vec3 {
		q := inv * [4]f32{2 * p.x / size.x - 1, 1 - 2 * p.y / size.y, depth, 1}
		return q.xyz / q.w
	}
	na, nb, fa := at(inv, a, size, 0), at(inv, b, size, 0), at(inv, a, size, 1)
	// With y down on screen, the right of the drag is this side.
	return na, linalg.normalize(linalg.cross(fa - na, nb - na))
}

// Asks for the selected object to be sliced along the screen line `a`-`b`, at the start
// of the next frame (object_slice).
slice_request :: proc(app: ^App, a, b, size: [2]f32) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	point, normal := screen_line_plane(app, obj, a, b, size)
	app.ui.scene_command = {kind = .Slice, point = point, normal = normal}
}

// Clips the selected object along the screen line `a`-`b` (viewport pixels), as an undo
// step of its own (sculpt.sculptor_clip).
clip_command :: proc(app: ^App, a, b: [2]f32, flip: bool, size: [2]f32) {
	stroke_finish(app)
	obj := selected_object(app)
	if obj == nil do return
	start := time.tick_now()
	point, normal := screen_line_plane(app, obj, a, b, size)
	if flip do normal = -normal
	planes := make([dynamic]sculpt.Clip_Plane, 0, sculpt.SYM_IMAGES_MAX, context.temp_allocator)
	sym := brush_symmetry(app, obj)
	for img in sculpt.symmetry_images(sym) do append(&planes, sculpt.Clip_Plane{point = sculpt.sym_point(img, sym.sym_center, point), normal = img.turn * normal})
	changed := sculpt.sculptor_clip(object_sculptor(obj), planes[:])
	report(app, Kit_Section.Visibility, {.Quiet}, "Clip in %.0f ms%s", time.duration_milliseconds(time.tick_since(start)), "" if changed else ", nothing changed")
	if changed do history_record(app, obj, .Deform, "Clip")
}

// Lists the stroke (or mask command) the object's current sculptor just finished as
// the newest undo step.
history_record :: proc(app: ^App, obj: ^Object, kind: History_Kind, what: string) {
	history_drop_redo(app)
	app.history.serial += 1
	if !object_in_hd(obj) do app.history.edits += 1
	append(&app.history.done, History_Entry{id = obj.id, level = HD_LEVEL if object_in_hd(obj) else obj.levels.current, kind = kind, what = what, at = time.tick_now()})
}

@(private = "file", rodata)
HIDE_COMMAND_NAMES := [sculpt.Hide_Command]string {
	.Show_All    = "show all",
	.Invert      = "invert visibility",
	.Masked      = "hide masked",
	.Unmasked    = "hide unmasked",
	.Grow        = "grow visibility",
	.Shrink      = "shrink visibility",
	.Grow_All    = "grow all",
	.Outer_Ring  = "outer ring",
	.Grow_Groups = "grow to groups",
	.Show_Masked = "show masked",
}

@(private = "file", rodata)
MASK_COMMAND_NAMES := [sculpt.Mask_Command]string {
	.Clear   = "Clear mask",
	.Invert  = "Invert mask",
	.Fill    = "Mask all",
	.Cavity  = "Mask cavities",
	.Region  = "Mask region",
	.Hidden  = "Mask hidden",
	.Blur    = "Blur mask",
	.Sharpen = "Sharpen mask",
	.Grow    = "Grow mask",
	.Shrink  = "Shrink mask",
}

// Lists placing `obj` anew (moved, turned or scaled from `before` to where it is now) as
// the newest undo step, or with `chain` as part of the newest (the rest of a selection
// moved together); nothing when it ended where it began.
history_record_transform :: proc(app: ^App, obj: ^Object, before: Transform, what: string, chain := false) {
	if obj.transform == before do return
	history_drop_redo(app)
	app.history.serial += 1
	app.history.edits += 1
	append(&app.history.done, History_Entry{id = obj.id, kind = .Transform, what = what, at = time.tick_now(), before = before, after = obj.transform, chain = chain && len(app.history.done) > 0})
}

// Lists `e`, a change that is no stroke and no swap, as the newest undo step.
history_push :: proc(app: ^App, e: History_Entry) {
	history_drop_redo(app)
	app.history.serial += 1
	app.history.edits += 1
	append(&app.history.done, e)
}

// A new step discards everything that could have been redone, everywhere.
@(private = "file")
history_drop_redo :: proc(app: ^App) {
	for e in app.history.undone {
		if e.swap != nil || e.arrange != nil || e.kind == .Transform {
			// Nothing of it is kept anywhere else.
		} else if obj := object_by_id(app, e.id); obj != nil && obj.voxel != nil {
			voxel.clay_clear_redo(&obj.voxel.clay)
		} else if s := entry_sculptor(app, e); s != nil {
			sculpt.sculptor_clear_redo(s)
		}
		entry_free(&app.history, e)
	}
	clear(&app.history.undone)
}

history_can_undo :: proc(app: ^App) -> bool {return !history_busy(app) && len(app.history.done) > 0}
history_can_redo :: proc(app: ^App) -> bool {return !history_busy(app) && len(app.history.undone) > 0}

// A stroke, a gizmo or inspector drag of a transform, or a deformer's Amount drag is
// under way: it becomes a step of its own when it ends, so nothing is undone or redone
// beneath it.
@(private = "file")
history_busy :: proc(app: ^App) -> bool {
	return app.stroke.active || app.move.drag.handle != .None || topo_held(app) || app.ui.transform_drag.active || app.ui.deform.drag.active
}

history_undo :: proc(app: ^App) {
	// A topological mask let go and still settling finishes first, as its own step.
	topo_settle(app)
	inspector_drags_end(app)
	macro_undoing(app)
	// A chained entry goes back with the one before it.
	for history_step(app, &app.history.done, &app.history.undone, sculpt.sculptor_can_undo, sculpt.sculptor_undo) {
		if top := app.history.undone[len(app.history.undone) - 1]; !top.chain || len(app.history.done) == 0 do break
	}
}

history_redo :: proc(app: ^App) {
	topo_settle(app)
	inspector_drags_end(app)
	for history_step(app, &app.history.undone, &app.history.done, sculpt.sculptor_can_redo, sculpt.sculptor_redo) {
		if len(app.history.undone) == 0 || !app.history.undone[len(app.history.undone) - 1].chain do break
	}
}

// Takes one entry from `from` to `to`; false when there was none to take.
@(private = "file")
history_step :: proc(app: ^App, from, to: ^[dynamic]History_Entry, can, step: proc(s: ^sculpt.Sculptor) -> bool) -> bool {
	if history_busy(app) do return false
	// Entries whose step a sculptor already dropped (memory limit) are skipped.
	for len(from) > 0 {
		e := pop(from)
		app.history.serial += 1
		// The last stroke's end may be undone with it, so the next press joins nothing.
		app.stroke_end.valid = false
		if e.level != HD_LEVEL || e.swap != nil do app.history.edits += 1
		if e.swap != nil {
			if !history_swap(app, e) do app.running = false // GPU failure
			append(to, e)
			return true
		}
		if e.arrange != nil {
			// The tree changes no level and no sculptor; layout_apply copes with objects
			// that came or went since.
			layout_apply(app, e.arrange.before if from == &app.history.done else e.arrange.after)
			append(to, e)
			return true
		}
		if e.kind == .Transform {
			// Placing the object anew changes no level and no sculptor; an object that is
			// gone takes the step with it.
			obj := object_by_id(app, e.id)
			if obj == nil {
				entry_free(&app.history, e)
				continue
			}
			obj.transform = e.before if from == &app.history.done else e.after
			app.move.drag = {}
			append(to, e)
			return true
		}
		if obj := object_by_id(app, e.id); obj != nil && obj.voxel != nil {
			// A voxel stroke: the clay swaps the bricks the step saved back in (undo) or out
			// again (redo); a step the clay dropped (memory limit) is skipped.
			c := &obj.voxel.clay
			backwards := from == &app.history.done
			stepped: bool
			if backwards do stepped = voxel.clay_undo(c)
			else do stepped = voxel.clay_redo(c)
			if !stepped {
				entry_free(&app.history, e)
				continue
			}
			append(to, e)
			return true
		}
		s := entry_sculptor(app, e)
		if s == nil || !can(s) {
			entry_free(&app.history, e)
			continue
		}
		// A stroke from outside HD leaves the window first; one inside it is only listed
		// while the window is open.
		if e.level != HD_LEVEL && !object_set_level(app, object_by_id(app, e.id), e.level) do app.running = false // GPU failure
		hidden := sculpt.sculptor_hidden_stamp(s)
		_ = step(s)
		// A group command's materials go back or forward with its groups.
		if t := e.group_table; t != nil {
			table := t.before if from == &app.history.done else t.after
			group_materials_replace(app, object_by_id(app, e.id), table[:])
		}
		// What is hidden changed: which chunks are drawn changed with it.
		if sculpt.sculptor_hidden_stamp(s) != hidden do render.viewport_invalidate(&app.target)
		append(to, e)
		return true
	}
	return false
}

// The sculptor an entry's stroke was made with, or nil if it is gone.
entry_sculptor :: proc(app: ^App, e: History_Entry) -> ^sculpt.Sculptor {
	obj := object_by_id(app, e.id)
	switch {
	case obj == nil:
		return nil
	case e.level == HD_LEVEL:
		return &obj.levels.hd.window.sculptor if object_in_hd(obj) else nil
	case e.level >= len(obj.levels.levels):
		return nil
	}
	return &obj.levels.levels[e.level].sculptor
}

// Trades the object the entry names, as it is now, for the entry's snapshot, and keeps
// what it was in the snapshot instead, so the entry can go back the other way. Returns
// false only on a GPU failure.
@(private = "file")
history_swap :: proc(app: ^App, e: History_Entry) -> bool {
	snap := e.swap
	start := time.tick_now()
	stroke_finish(app)
	app.move.drag = {}
	obj := object_by_id(app, e.id)
	live := history_snapshot(app, obj, snap.what)
	defer snapshot_free(live)
	restored: ^Object
	if snap.exists {
		r := geom.byte_reader(snap.bytes[:])
		read, made: bool
		restored, read, made = object_get(app, &r)
		if !read {
			// Written by this run a moment ago; only running out of memory gets here.
			log.errorf("undo: could not rebuild object %d", e.id)
			return true
		}
		if !made {
			_ = sdl.WaitForGPUIdle(app.renderer.device)
			object_discard(app, restored)
			return false
		}
	}
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	history_forget_strokes(app, e.id)
	scene := &app.scene
	if obj != nil {
		// Whether it is in view is not part of the step: the object comes back as it is
		// shown now, not as it was when the snapshot was taken.
		// Nor is its material, which no step records.
		if restored != nil do restored.off, restored.ghost, restored.folder, restored.vis_off, restored.material = obj.off, obj.ghost, obj.folder, obj.vis_off, obj.material
		index := live.index
		ordered_remove(&scene.objects, index)
		object_free(app, obj)
		scene.selected = min(scene.selected, len(scene.objects) - 1)
	}
	if restored != nil {
		index := clamp(snap.index, 0, len(scene.objects))
		inject_at(&scene.objects, index, restored)
		scene.selected = index
	}
	scene_folders_normalize(app)
	scene_selection_fix(app)
	app.history.swap_bytes += len(live.bytes) - len(snap.bytes)
	snap.exists, snap.index = live.exists, live.index
	snap.bytes, live.bytes = live.bytes, snap.bytes
	render.viewport_invalidate(&app.target)
	log.infof("swap: %s on object %d in %.0f ms", snap.what, e.id, time.duration_milliseconds(time.tick_since(start)))
	return true
}

// Drops an object's entries, when its sculptors (and so its strokes) go away.
history_forget :: proc(app: ^App, id: int) {
	history_forget_level(app, id, nil)
}

// Drops an object's strokes on every level but keeps its swap and transform entries,
// which hold the whole object or only where it is placed, and so stay right whatever
// happened to its sculptors.
history_forget_strokes :: proc(app: ^App, id: int) {
	app.history.serial += 1
	for list in ([2]^[dynamic]History_Entry{&app.history.done, &app.history.undone}) {
		kept := 0
		for e in list {
			if e.id != id || e.swap != nil || e.arrange != nil || e.kind == .Transform {
				list[kept] = e
				kept += 1
			} else {
				entry_free(&app.history, e)
			}
		}
		resize(list, kept)
	}
}

// Drops an object's entries on one level (all levels when nil): for the HD window,
// whose strokes go when it closes, since its detail is then stored. One level keeps the
// object's transform entries, which belong to no level.
history_forget_level :: proc(app: ^App, id: int, level: Maybe(int)) {
	app.history.serial += 1
	for list in ([2]^[dynamic]History_Entry{&app.history.done, &app.history.undone}) {
		kept := 0
		for e in list {
			only, one := level.?
			if e.id != id || e.arrange != nil || (one && (e.level != only || e.swap != nil || e.kind == .Transform)) {
				list[kept] = e
				kept += 1
			} else {
				entry_free(&app.history, e)
			}
		}
		resize(list, kept)
	}
}

// Drops an object's strokes on every level, when its levels are renumbered or some
// are deleted: undoing a stroke from one level is only right once every later stroke,
// on any level, has been undone.
object_forget_history :: proc(app: ^App, obj: ^Object) {
	history_forget_strokes(app, obj.id)
	if vp := obj.voxel; vp != nil do voxel.clay_clear_history(&vp.clay)
	for lv in obj.levels.levels {
		sculpt.sculptor_clear_history(&lv.sculptor)
		// The History brush's target is out of reach without the steps (and 12 bytes a vertex).
		sculpt.sculptor_recall_clear(&lv.sculptor)
	}
}

object_by_id :: proc(app: ^App, id: int) -> ^Object {
	for obj in app.scene.objects do if obj.id == id do return obj
	return nil
}

// What object_has_mask last found, and for which object, level and history: a fact
// derived from the sculpt, rebuilt whenever any of them changes, never state of its own.
Mask_Seen :: struct {
	id, level, levels: int,
	serial: u64,
	has:    bool,
	valid:  bool,
	scans:  int, // how many times it looked, for the tests and the exit stats
}

// Whether any of the object's shown vertices is masked (its HD window's, while one is
// open). Looking means reading every vertex's mask, so the answer is kept until the
// object, its level or the history changes: every mask change is a history step (strokes,
// mask commands and taps, shapes, undo and redo), a level change changes the level, and a
// rebuild is a swap step.
object_has_mask :: proc(app: ^App, obj: ^Object) -> bool {
	level := HD_LEVEL if object_in_hd(obj) else obj.levels.current
	m := &app.mask_seen
	if m.valid && m.id == obj.id && m.level == level && m.levels == len(obj.levels.levels) && m.serial == app.history.serial do return m.has
	s := object_sculptor(obj)
	m^ = {id = obj.id, level = level, levels = len(obj.levels.levels), serial = app.history.serial, valid = true, scans = m.scans}
	if s.mask != nil {
		m.has = sculpt.sculptor_has_mask(s)
		m.scans += 1
	}
	return m.has
}
