package main

import "core:fmt"
import "core:log"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../sculpt"
import "../ui"

// Object > Shape > Modify topology's repairs, the best of ZBrush's Modify Topology and
// Mesh Integrity, Blender's Clean Up and Meshmixer's Inspector: Close holes, Delete
// hidden, Weld points, Check mesh, Fix mesh and Delete half (geom repair.odin and
// slice.odin). Each but Check rebuilds the object, as Mirror and weld does: its levels,
// HD detail, mask and strokes go and its shown level's sculpt layers come across. Where
// vertices and triangles stay, their polypaint and polygroups stay too; a cap takes the
// colours of its border and a polygroup of its own, so it can be masked or hidden at
// once. Each is one undo step.

Repair_Kind :: enum u8 {
	Close_Holes,
	Delete_Hidden,
	Weld_Points,
	Check_Mesh,
	Fix_Mesh,
	Delete_Half,
}

@(rodata)
REPAIR_NAMES := [Repair_Kind]string {
	.Close_Holes   = "Close holes",
	.Delete_Hidden = "Delete hidden",
	.Weld_Points   = "Weld points",
	.Check_Mesh    = "Check mesh",
	.Fix_Mesh      = "Fix mesh",
	.Delete_Half   = "Delete half",
}

// What the History calls each step.
@(rodata)
REPAIR_UNDO_NAMES := [Repair_Kind]string {
	.Close_Holes   = "close holes",
	.Delete_Hidden = "delete hidden",
	.Weld_Points   = "weld points",
	.Check_Mesh    = "check mesh",
	.Fix_Mesh      = "fix mesh",
	.Delete_Half   = "delete half",
}

// Weld points' distance, as a share of the object's largest side: from a hundred
// thousandth (seams of a file that wrote its numbers short) to a hundredth (gaps a
// person can see), on a logarithmic slider.
WELD_DISTANCE_MIN :: 1e-5
WELD_DISTANCE_MAX :: 1e-2
WELD_DISTANCE_DEFAULT :: 1e-4

// What the repairs did this run, for the exit stats.
Repair_Stats :: struct {
	count: int, // repairs that changed an object
	ms:    f64, // the last one's, to the new mesh
	last:  Repair_Kind,
	check: geom.Mesh_Integrity, // the last Check mesh's
}

// Repairs the object as `cmd.repair` says (not Check mesh, which repair_check does).
// `changed` says whether it did; ok is false only when the old mesh is gone and the new
// one could not be uploaded.
object_repair :: proc(app: ^App, obj: ^Object, cmd: Scene_Command) -> (changed, ok: bool) {
	kind := cmd.repair
	name := REPAIR_NAMES[kind]
	if kind == .Delete_Hidden {
		start := time.tick_now()
		parts: [dynamic]int
		parts, changed, ok = object_split(app, obj, .Hidden, keep_parts = false)
		delete(parts)
		if changed do repair_done(app, obj, kind, start, "the hidden part is gone")
		return
	}
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	s := object_sculptor(obj)
	source := object_mesh(obj)^
	packed: geom.Mesh
	paged := object_dynamic(obj)
	if paged {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(s)
		delete(mask)
		source = packed
	}
	mesh: geom.Mesh
	from: geom.Repair_Map
	defer geom.repair_map_destroy(&from)
	built: bool
	what, why: string
	switch kind {
	case .Close_Holes:
		r: geom.Close_Report
		mesh, from, r, built = geom.mesh_close_holes(source, cmd.on, &app.pool)
		why = "it has no hole" if r.left_open == 0 else "its one hole is the largest, which stays open"
		what = fmt.tprintf("closed %d hole%s", r.closed, plural(r.closed))
		if r.left_open > 0 do what = fmt.tprintf("%s and left the largest open", what)
		if r.fanned > 0 do what = fmt.tprintf("%s (%d folded over, fanned from the middle)", what, r.fanned)
	case .Weld_Points:
		bounds := geom.AABB_EMPTY
		for p in source.positions do geom.aabb_grow(&bounds, p)
		extent := bounds.hi - bounds.lo
		distance := cmd.distance * max(extent.x, extent.y, extent.z)
		r: geom.Weld_Report
		mesh, from, r, built = geom.mesh_weld_points(source, distance, &app.pool)
		why = fmt.tprintf("no two vertices are within %g of each other", distance)
		what = fmt.tprintf("welded %d vertices", r.welded)
		if dropped := r.dropped_triangles + r.duplicate_triangles; dropped > 0 do what = fmt.tprintf("%s, dropping %d triangles", what, dropped)
	case .Fix_Mesh:
		r: geom.Fix_Report
		mesh, from, r, built = geom.mesh_fix(source, &app.pool)
		why = "nothing in it needs fixing"
		what = repair_fix_text(r)
	case .Delete_Half:
		normal: Vec3
		normal[clamp(cmd.axis, 0, 2)] = 1
		front, back, cut := geom.mesh_slice(source, {}, normal, false, &app.pool)
		if cmd.on {
			mesh = front
			geom.mesh_destroy(&back)
		} else {
			mesh = back
			geom.mesh_destroy(&front)
		}
		built = cut
		why = "its plane does not cut it in two"
		axes := [3]string{"X", "Y", "Z"}
		what = fmt.tprintf("kept its %s%s side", "+" if cmd.on else "-", axes[clamp(cmd.axis, 0, 2)])
	case .Delete_Hidden, .Check_Mesh:
	}
	// Polypaint and polygroups follow the vertices and triangles they were on.
	surface: Surface
	if built && !paged && from.vertex_from != nil do surface = repair_surface(s, from)
	defer {
		delete(surface.color)
		delete(surface.groups)
	}
	// What the report says, out of the temp memory freed below.
	what = strings.clone(what)
	defer delete(what)
	geom.mesh_destroy(&packed)
	if !built {
		report(app, .Mirror, {}, "%s: %s", name, why)
		free_all(context.temp_allocator)
		return false, true
	}
	free_all(context.temp_allocator)
	made := time.tick_now()
	_ = sdl.WaitForGPUIdle(app.renderer.device)
	if !object_rebuild(app, obj, mesh, made, normals = true, surface = surface) do return true, false
	app.repair.ms = time.duration_milliseconds(time.tick_diff(start, made))
	repair_done(app, obj, kind, start, what)
	return true, true
}

// Counts a repair and says what it did.
@(private = "file")
repair_done :: proc(app: ^App, obj: ^Object, kind: Repair_Kind, start: time.Tick, what: string) {
	app.repair.count += 1
	app.repair.last = kind
	ms := time.duration_milliseconds(time.tick_since(start))
	report(app, .Mirror, {.Undo}, "%s on %s: %s, %s vertices, in %.0f ms", REPAIR_NAMES[kind], object_label(obj), what, count_label(object_vertex_count(obj)), ms)
}

// The repaired mesh's polypaint and polygroups from the sculptor's, through where each
// vertex and triangle came from. A cap's triangles take a new polygroup each (numbered
// after the highest), as ZBrush's Close Holes gives them, even on an object that had
// none. Heap memory, or nil for what there is none of.
repair_surface :: proc(s: ^sculpt.Sculptor, from: geom.Repair_Map) -> (surface: Surface) {
	if s.color != nil {
		surface.color = make([]sculpt.Color, len(from.vertex_from))
		for v, i in from.vertex_from do surface.color[i] = s.color[v]
	}
	groups := sculpt.sculptor_groups(s)
	capped := false
	for t in from.tri_from do capped ||= t >= geom.REPAIR_NEW
	if groups == nil && !capped do return
	next: u32
	for g in groups do next = max(next, u32(g) + 1)
	if groups == nil do next = 1
	surface.groups = make([]u16, len(from.tri_from))
	for t, i in from.tri_from {
		switch {
		case t < geom.REPAIR_NEW:
			surface.groups[i] = groups[t] if groups != nil else 0
		case:
			surface.groups[i] = u16(min(next + (t - geom.REPAIR_NEW), u32(max(u16))))
		}
	}
	return
}

// Fix mesh's report as words.
@(private = "file")
repair_fix_text :: proc(r: geom.Fix_Report) -> string {
	b := strings.builder_make(context.temp_allocator)
	part :: proc(b: ^strings.Builder, n: int, what: string) {
		if n == 0 do return
		if strings.builder_len(b^) > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "%d %s", n, what)
	}
	part(&b, r.dropped_triangles, "broken triangles dropped")
	part(&b, r.duplicate_triangles, "duplicates dropped")
	part(&b, r.flipped_triangles, "triangles turned")
	part(&b, r.turned_shells, "inside-out pieces turned outward")
	part(&b, r.dropped_vertices, "loose vertices dropped")
	return strings.to_string(b)
}

// Checks the object and says what is wrong with it, as ZBrush's Check Mesh Integrity and
// Blender's 3D print checks do, changing nothing.
repair_check :: proc(app: ^App, obj: ^Object) {
	stroke_finish(app)
	start := time.tick_now()
	source := object_mesh(obj)^
	packed: geom.Mesh
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		source = packed
	}
	defer geom.mesh_destroy(&packed)
	r := geom.mesh_integrity(source, &app.pool)
	app.repair.check = r
	c := r.check
	b := strings.builder_make(context.temp_allocator)
	part :: proc(b: ^strings.Builder, n: int, one, many: string) {
		if n == 0 do return
		if strings.builder_len(b^) > 0 do strings.write_string(b, ", ")
		fmt.sbprintf(b, "%d %s", n, one if n == 1 else many)
	}
	part(&b, r.holes, "hole", "holes")
	part(&b, c.non_manifold_edges, "edge of more than two triangles", "edges of more than two triangles")
	part(&b, c.inconsistent_edges, "edge between triangles facing opposite ways", "edges between triangles facing opposite ways")
	part(&b, c.degenerate_triangles, "triangle with no area", "triangles with no area")
	part(&b, r.duplicate_triangles, "duplicate triangle", "duplicate triangles")
	part(&b, r.unused_vertices, "loose vertex", "loose vertices")
	if c.closed && c.inverted do part(&b, 1, "inside out", "inside out")
	problems := strings.to_string(b)
	pieces := fmt.tprintf("%d piece%s", r.pieces, plural(r.pieces))
	text: string
	switch {
	case problems == "" && c.closed:
		text = fmt.tprintf("sound: closed, %s, %.4g cubic units", pieces, c.volume)
	case problems == "":
		text = fmt.tprintf("open, %s", pieces)
	case:
		text = fmt.tprintf("%s; %s", problems, pieces)
	}
	ms := time.duration_milliseconds(time.tick_since(start))
	log.infof("check mesh: %v", r)
	report(app, .Mirror, {}, "Check mesh on %s: %s (%.0f ms)", object_label(obj), text, ms)
}

@(private = "file")
plural :: proc(n: int) -> string {return "" if n == 1 else "s"}

// Object > Shape > Modify topology: Mirror and weld with its axis and side, then the
// repairs; Close holes and Delete hidden in sight, the rest under More.
kit_topology :: proc(app: ^App) {
	ctx := &app.kit.ctx
	axes := [3]string{"X", "Y", "Z"}
	if picked := ui.tabs(ctx, "mirror axis", axes[:], int(app.ui.mirror_axis)); picked >= 0 do app.ui.mirror_axis = i32(picked)
	_ = ui.switch_row(ctx, "Keep the - side", &app.ui.mirror_negative)
	_ = command_button(app, .Mirror_Weld, tone = .Accent)
	_ = command_button(app, .Close_Holes)
	_ = command_button(app, .Delete_Hidden, tone = .Danger)
	ui.paragraph(ctx, "Mirror and weld replaces one half with a mirror image of the other, across the object's own plane on the axis (the one symmetry uses). Close holes caps every opening with a surface as even as the one around it, each cap a polygroup of its own. Each rebuilds the object: levels and mask go; Ctrl+Z brings them back.")
	if kit_more(app, .Mirror) {
		_ = ui.switch_row(ctx, "Leave the largest hole", &app.ui.holes_leave_largest)
		_ = command_button(app, .Delete_Half, tone = .Danger)
		_ = ui.slider(ctx, "Weld distance", &app.ui.weld_distance, WELD_DISTANCE_MIN, WELD_DISTANCE_MAX, .Logarithmic, fmt.tprintf("%.3g %%", 100 * app.ui.weld_distance))
		_ = command_button(app, .Weld_Points)
		kit_command_pair(app, .Check_Mesh, .Fix_Mesh)
		ui.paragraph(ctx, "Delete half deletes the side the axis and Keep the - side do not keep, leaving it open for Mirror and weld or Close holes. Weld points joins vertices closer than the distance (a share of the object's size). Check mesh counts holes, pieces and broken edges; Fix mesh drops broken and duplicate triangles and turns the ones facing the wrong way.")
		kit_more_end(app)
	}
	kit_last_result(app, .Mirror)
}
