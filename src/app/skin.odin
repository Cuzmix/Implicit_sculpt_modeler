package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:time"

import "../geom"
import "../sculpt"

// The detail skin (sculpt/skin.odin) in the app: where a brush's detail goes, and adding,
// changing and taking off an object's skin.

// Where a brush's detail goes on an object with a detail skin, remembered per brush.
// Auto writes into the skin when the object has one; Mesh always moves vertices; Skin
// never moves a vertex, and refuses where there is no skin to write into. Grab, Pose,
// Cloth and the other brushes that move vertices sideways always move the mesh.
Detail_To :: enum u8 {
	Auto,
	Mesh,
	Skin,
}

@(rodata)
DETAIL_TO_NAMES := [Detail_To]string {
	.Auto = "Auto",
	.Mesh = "Mesh",
	.Skin = "Skin",
}

// The skin segments the Detail skin choice offers, Off first.
SKIN_SEGMENTS := [?]u32{0, 2, 4, 8, 16}

// The object's detail skin (on its current level's sculptor), nil for none, for a voxel
// object or a curve or cage, or while it sculpts HD.
object_skin :: proc(obj: ^Object) -> ^sculpt.Skin {
	if obj == nil || obj.voxel != nil || obj.curve != nil || obj.cage != nil || object_in_hd(obj) do return nil
	return sculpt.sculptor_skin(object_sculptor(obj))
}

// The detail skin on the object's top level, which a skin belongs to, whichever level is
// current; nil for none.
object_top_skin :: proc(obj: ^Object) -> ^sculpt.Skin {
	if obj == nil || obj.voxel != nil || obj.curve != nil || obj.cage != nil || len(obj.levels.levels) == 0 do return nil
	return sculpt.sculptor_skin(&obj.levels.levels[len(obj.levels.levels) - 1].sculptor)
}

// The commands a skinned object refuses: each would change the top level's triangles
// under the skin, or add finer detail that competes with it (HD, dynamic topology).
SKIN_REFUSED_COMMANDS :: Command_Set{.Subdivide, .Delete_Lower_Levels, .Delete_Higher_Levels, .Hd_Divide, .Hd_Sculpt, .Hd_Toggle, .Dyntopo_Toggle}

// The scene commands a skinned object refuses, for the same reasons, for scripts.
SKIN_REFUSED_SCENE :: bit_set[Scene_Command_Kind]{.Subdivide, .Delete_Higher, .Delete_Lower, .Hd_Enter, .Hd_Steps, .Dyntopo}

// Whether a stroke of `kind` on `obj` writes into its detail skin: a skin brush with
// Detail goes to on Auto or Skin. Auto moves the mesh while a sculpt layer records, since
// layers hold vertex moves only.
stroke_to_skin :: proc(app: ^App, obj: ^Object, kind: sculpt.Brush_Kind) -> bool {
	if kind not_in sculpt.SKIN_KINDS || object_skin(obj) == nil do return false
	switch app.brush.detail_to[kind] {
	case .Mesh: return false
	case .Skin: return true
	case .Auto: return sculpt.sculptor_layer_recording(object_sculptor(obj)) < 0
	}
	return false
}

// Whether a stroke of `kind` may start on `obj`: with Detail goes to on Skin, only where
// there is a skin and no sculpt layer records. With `say`, a refusal says why.
skin_stroke_allowed :: proc(app: ^App, obj: ^Object, kind: sculpt.Brush_Kind, say: bool) -> bool {
	if kind not_in sculpt.SKIN_KINDS || app.brush.detail_to[kind] != .Skin do return true
	if obj.voxel != nil do return true
	label := BRUSHES[kind].name
	if object_skin(obj) == nil {
		if say do report(app, Section.Hd, {.Warning}, "%s puts its detail in the skin, and %s has none: add a detail skin (HD detail card) or set Detail goes to Auto", label, object_label(obj))
		return false
	}
	if sculpt.sculptor_layer_recording(object_sculptor(obj)) >= 0 {
		if say do report(app, Section.Layers, {.Warning}, "%s puts its detail in the skin, and sculpt layers record vertex moves only: stop the recording or set Detail goes to Auto", label)
		return false
	}
	return true
}

// Why the object cannot have a detail skin now, or "" when it can.
skin_refusal :: proc(obj: ^Object) -> string {
	switch {
	case obj == nil: return "Select an object first."
	case obj.voxel != nil: return "Voxel clay has no skin: convert it to a mesh first."
	case obj.curve != nil || obj.cage != nil: return "A skin goes on a sculpt mesh."
	case object_dynamic(obj): return "Turn dynamic topology off to add a skin."
	case obj.levels.hd.steps > 0: return "Delete the HD level to add a skin: both sculpt finer than the mesh."
	case obj.levels.current != len(obj.levels.levels) - 1: return "A skin goes on the top level: go up to it first."
	}
	return ""
}

// Gives the selected object a detail skin of `segments` along each triangle edge, or
// with 0 takes it off, as an undo step. Says why when it cannot. With `why` (a skin added
// by itself, skin_auto_add) the note says that instead of the plain one.
skin_set :: proc(app: ^App, segments: u32, why := "") -> bool {
	stroke_finish(app)
	obj := selected_object(app)
	if refused := skin_refusal(obj); refused != "" {
		if segments != 0 || object_skin(obj) != nil do report(app, Section.Hd, {.Warning}, "%s", refused)
		return false
	}
	s := object_sculptor(obj)
	if !sculpt.sculptor_skin_change(s, segments) {
		if sk := sculpt.sculptor_skin(s); segments != 0 && (sk == nil || sk.segments != segments) {
			report(app, Section.Hd, {.Warning}, "%s needs a closed mesh for a skin: Rebuild or Close holes first", object_label(obj))
		}
		return false
	}
	obj.skin_declined = segments == 0 && why == ""
	what := "Remove detail skin" if segments == 0 else "Detail skin"
	history_record(app, obj, .Deform, what)
	if segments == 0 {
		report(app, nil, {.Undo}, "Took the detail skin off %s", object_label(obj))
	} else if why != "" {
		report(app, Section.Hd, {.Undo}, "%s", why)
	} else {
		report(app, nil, {.Undo}, "%s has a detail skin of %d segments", object_label(obj), segments)
	}
	return true
}

// Why the object's skin cannot be applied now, or "" when it can.
skin_apply_refusal :: proc(obj: ^Object) -> string {
	top := object_top_skin(obj)
	if top == nil do return "Add a detail skin first."
	levels := &obj.levels
	steps := sculpt.levels_skin_apply_steps(levels)
	switch {
	case levels.current != len(levels.levels) - 1: return "Go up to the top level first: the skin lies on it."
	case len(levels.levels) + steps > sculpt.MAX_LEVELS: return fmt.tprintf("Apply adds %d levels and the object has room for %d.", steps, sculpt.MAX_LEVELS - len(levels.levels))
	case levels.rule != .Loop: return "Apply builds Loop levels, and this object subdivides as Catmull-Clark."
	}
	if _, _, bytes := sculpt.levels_skin_apply_estimate(levels); bytes > MAX_SUBDIVIDE_BYTES {
		return fmt.tprintf("Apply would need about %s; the limit is %s.", bytes_label(bytes), bytes_label(MAX_SUBDIVIDE_BYTES))
	}
	return ""
}

// Bakes the selected object's detail skin into subdivision levels (sculpt.levels_skin_apply)
// as one undo step, a swap that puts the skin back. Returns false on a GPU failure.
skin_apply :: proc(app: ^App) -> bool {
	obj := selected_object(app)
	if obj == nil do return true
	if why := skin_apply_refusal(obj); why != "" {
		report(app, Section.Hd, {.Warning}, "%s", why)
		return true
	}
	stroke_finish(app)
	start := time.tick_now()
	levels := &obj.levels
	layers := len(levels.levels[len(levels.levels) - 1].sculptor.layers.list)
	before := history_snapshot(app, obj, "apply detail skin")
	if !sculpt.levels_skin_apply(levels, carry_layers = layers > 0) {
		history_snapshot_drop(before)
		report(app, Section.Hd, {.Warning}, "%s needs a closed mesh to apply its skin: Rebuild or Close holes first", object_label(obj))
		return true
	}
	history_record_swap(app, obj.id, before)
	object_forget_history(app, obj)
	app.layers_kept += layers
	report(app, nil, {.Undo}, "Applied the detail skin of %s: level %d has %s vertices", object_label(obj), levels.current + 1, count_label(geom.mesh_vertex_count(object_mesh(obj)^)))
	return object_show_level(app, obj, start)
}

// The most a detail skin added by itself may take: its heights and normals, six bytes a
// sample. A finer skin than this halves its segments until it fits.
SKIN_AUTO_BYTES :: 256 << 20

// The segments of a skin added by itself for a dab of `radius` on a mesh of `tris`
// triangles whose mean edge is `edge` (both in the object's space): the fewest that put
// a grid step under half the radius, so the dab spans four steps or more, then fewer while
// the skin would pass SKIN_AUTO_BYTES. 0 when the dab is not finer than the mesh.
skin_auto_segments :: proc(tris: int, edge, radius: f32) -> u32 {
	if tris == 0 || edge <= 0 || radius <= 0 || radius >= edge do return 0
	segments := SKIN_SEGMENTS[len(SKIN_SEGMENTS) - 1]
	for n in SKIN_SEGMENTS[1:] {
		if edge / f32(n) <= 0.5 * radius {
			segments = n
			break
		}
	}
	for segments > SKIN_SEGMENTS[1] && skin_auto_bytes(tris, segments) > SKIN_AUTO_BYTES do segments /= 2
	return segments if skin_auto_bytes(tris, segments) <= SKIN_AUTO_BYTES else 0
}

// The segments of a skin on a rebuilt mesh of `tris` triangles that holds at least as
// many samples as `samples` (the old surface's: its skin's, or its vertices'), so no
// detail is lost to a coarser grid: the smallest power of two, 2 to 16, at or past the
// square root of twice their ratio (a triangle of S segments adds about S * S / 2
// samples), fewer while the skin would pass SKIN_AUTO_BYTES. 0 when not even 2 fits.
skin_carry_segments :: proc(tris, samples: int) -> u32 {
	if tris <= 0 do return 0
	want := math.sqrt(2 * f64(samples) / f64(tris))
	segments := SKIN_SEGMENTS[len(SKIN_SEGMENTS) - 1]
	for n in SKIN_SEGMENTS[1:] do if f64(n) >= want {
		segments = n
		break
	}
	for segments > SKIN_SEGMENTS[1] && skin_auto_bytes(tris, segments) > SKIN_AUTO_BYTES do segments /= 2
	return segments if skin_auto_bytes(tris, segments) <= SKIN_AUTO_BYTES else 0
}

// What a skin of `segments` takes on a closed mesh of `tris` triangles, near enough: half
// as many vertices and one and a half times as many edges as triangles.
@(private = "file")
skin_auto_bytes :: proc(tris: int, segments: u32) -> int {
	S := int(segments)
	samples := tris / 2 + (3 * tris / 2) * (S - 1) + tris * (S - 1) * (S - 2) / 2
	return 6 * samples
}

// At the press of a stroke of `kind` on `obj`, gives it a detail skin when the dab is
// finer than its mesh and none is there: Detail goes to Auto, Add a skin by itself on, a
// brush that writes into a skin, an object that may have one and whose skin was not taken
// off by hand. `radius` is the dab's, in the object's space. The skin is an undo step of
// its own, before the stroke's. Returns whether it added one.
skin_auto_add :: proc(app: ^App, obj: ^Object, kind: sculpt.Brush_Kind, radius: f32) -> bool {
	if !app.skin_auto || kind not_in sculpt.SKIN_KINDS || app.brush.detail_to[kind] != .Auto do return false
	if obj == nil || obj.skin_declined || object_skin(obj) != nil || skin_refusal(obj) != "" do return false
	if obj.voxel != nil || sculpt.sculptor_layer_recording(object_sculptor(obj)) >= 0 do return false
	m := object_mesh(obj)
	tris := len(m.indices) / 3
	// A mesh too dense for even the coarsest skin within SKIN_AUTO_BYTES (about 22M
	// triangles) never gets one, so it is not measured: this runs at every press.
	if tris == 0 || skin_auto_bytes(tris, SKIN_SEGMENTS[1]) > SKIN_AUTO_BYTES do return false
	// The mean edge from the mean triangle area, as if the triangles were equilateral, the
	// mean taken over at most SKIN_AUTO_SAMPLES triangles spread over the mesh: close
	// enough to judge a dab by, and well under a millisecond where measuring every
	// triangle took 130 ms a press at 25M.
	edge := f32(math.sqrt(4 * skin_mean_area(m^, tris) / math.sqrt(f64(3))))
	segments := skin_auto_segments(tris, edge, radius)
	if segments == 0 do return false
	why := fmt.tprintf("Added a detail skin of %d segments to %s: %s's dab is finer than its mesh, so the detail goes into the skin (Detail skin section; Add a skin by itself turns this off)", segments, object_label(obj), BRUSHES[kind].name)
	return skin_set(app, segments, why)
}

// Triangles skin_mean_area measures at most.
SKIN_AUTO_SAMPLES :: 1 << 12

// The mean area of `m`'s `tris` triangles, measured on every triangle up to
// SKIN_AUTO_SAMPLES of them and on evenly spaced ones past that.
@(private = "file")
skin_mean_area :: proc(m: geom.Mesh, tris: int) -> f64 {
	step := max(1, tris / SKIN_AUTO_SAMPLES)
	sum, count := f64(0), 0
	for t := 0; t < tris; t += step {
		a := m.positions[m.indices[3 * t]]
		b := m.positions[m.indices[3 * t + 1]]
		c := m.positions[m.indices[3 * t + 2]]
		sum += 0.5 * f64(linalg.length(linalg.cross(b - a, c - a)))
		count += 1
	}
	return sum / f64(count)
}

// Squeeze: a dense sculpt becomes a lighter mesh holding its forms and a detail skin
// holding the rest, so it sculpts and draws as the lighter mesh does. The shares of the
// vertices the light mesh keeps, as the Detail skin section offers them.
SQUEEZE_SHARES := [?]int{4, 8, 16}

// Why the selected object cannot be squeezed, "" when it can.
skin_squeeze_refusal :: proc(obj: ^Object) -> string {
	switch {
	case obj == nil: return "Select an object first."
	case obj.voxel != nil: return "A voxel object has no mesh to squeeze: Convert to mesh first."
	case obj.cage != nil || obj.curve != nil: return "Squeeze works on a sculpted mesh, not on a cage or a curve."
	case object_dynamic(obj): return "Turn dynamic topology off first."
	case geom.mesh_vertex_count(object_mesh(obj)^) < SQUEEZE_MIN_VERTICES: return fmt.tprintf("Squeeze is for dense sculpts, of %s vertices or more.", count_label(SQUEEZE_MIN_VERTICES))
	}
	return ""
}

// Below this a squeezed mesh would be too coarse to hold the forms.
SQUEEZE_MIN_VERTICES :: 20_000

// Squeezes the selected object to 1 / `share` of its vertices: remeshed evenly to that
// count, with a skin of as many samples as it had vertices (and its skin samples, if it
// had one) carrying the rest of its surface, as one undo step. The note gives how far
// the result strays at worst and on average; the Skin detail view shows where (its heat).
skin_squeeze :: proc(app: ^App, share: int) -> bool {
	obj := selected_object(app)
	if why := skin_squeeze_refusal(obj); why != "" {
		report(app, Section.Hd, {.Warning}, "%s", why)
		return true
	}
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	source := object_mesh(obj)^
	s := object_sculptor(obj)
	samples := geom.mesh_vertex_count(source)
	if sk := sculpt.levels_skin(&obj.levels); sk != nil do samples = max(samples, len(sk.heights))
	area, bounds := geom.mesh_area_bounds(source, &app.pool)
	groups := sculpt.sculptor_groups(s)
	report_: geom.Remesh_Report
	defer geom.remesh_report_destroy(&report_)
	setup := Remesh_Setup{smooth = geom.REMESH_SMOOTH_DEFAULT, keep_thin = true}
	mesh, built := geom.remesh_voxel_measured(source, area, bounds, max(samples / max(share, 1), 1000), &app.pool, options = remesh_options(setup, groups), report = &report_)
	if !built {
		report(app, Section.Hd, {.Warning}, "%s has no volume to squeeze: close its holes first", object_label(obj))
		return true
	}
	surface := remesh_surface(report_, mesh, source, sculpt.sculptor_paint_shown(s), groups)
	defer surface_free(&surface)
	segments := skin_carry_segments(len(mesh.indices) / 3, samples)
	if segments == 0 {
		geom.mesh_destroy(&mesh)
		report(app, Section.Hd, {.Warning}, "The skin %s needs is past %s: squeeze by less", object_label(obj), bytes_label(SKIN_AUTO_BYTES))
		return true
	}
	before := history_snapshot(app, obj, "squeeze")
	if !object_rebuild(app, obj, mesh, start, normals = true, surface = surface, squeeze = segments) {
		history_snapshot_drop(before)
		scene_delete_selected(app, undoable = false)
		return false
	}
	history_record_swap(app, obj.id, before)
	app.skin_squeezes += 1
	rep := app.skin_carry
	size := linalg.length(bounds.hi - bounds.lo)
	report(app, nil, {.Undo}, "Squeezed %s from %s to %s vertices and a skin of %d segments (%.1f s): off by %.3f%% of its size at worst, %.4f%% on average", object_label(obj), count_label(samples), count_label(geom.mesh_vertex_count(object_mesh(obj)^)), segments, time.duration_seconds(time.tick_since(start)), 100 * rep.worst / size, 100 * rep.mean / size)
	return true
}
