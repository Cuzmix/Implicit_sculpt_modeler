package main

import "core:fmt"
import "core:log"
import "core:slice"
import "core:strings"

import "../geom"
import "../sculpt"
import "../ui"

// Remesh's options beside its density, as DynaMesh offers Blur, Project and Groups
// beside its resolution: carried in the Scene_Command so Adjust last, macros and the long
// job run the very options the panel held. The geometry's own form is geom.Remesh_Options;
// remesh_options makes one from this and the object's polygroups.
Remesh_Setup :: struct {
	smooth:      int,  // relax rounds, 0 to geom.REMESH_SMOOTH_MAX
	keep_detail: bool, // the result put back on the old surface, its polypaint and polygroups along
	groups:      bool, // each polygroup a closed piece of its own
	quads:       bool, // a closed mesh of quads only (the marching cubes' dual), kept as the object's polygons
}

// The panel's options, as a command takes them.
remesh_setup :: proc(app: ^App) -> Remesh_Setup {
	return {int(app.ui.remesh_smooth), app.ui.remesh_keep_detail, app.ui.remesh_groups, app.ui.remesh_quads}
}

// The panel set to a command's options (Adjust last).
remesh_setup_set :: proc(app: ^App, s: Remesh_Setup) {
	app.ui.remesh_smooth, app.ui.remesh_keep_detail, app.ui.remesh_groups, app.ui.remesh_quads = i32(s.smooth), s.keep_detail, s.groups, s.quads
}

// The geometry's options for `setup` on a mesh whose triangles have `groups` (nil for
// none, as under dynamic topology): Groups does nothing without them.
remesh_options :: proc(setup: Remesh_Setup, groups: []u16) -> geom.Remesh_Options {
	return {smooth = setup.smooth, keep_detail = setup.keep_detail, groups = groups if setup.groups else nil, quads = setup.quads}
}

// The polypaint and polygroups the remeshed mesh `out` takes from the mesh it came from,
// through what the remesh reported: with Groups each triangle's piece names its group;
// with Keep detail each vertex's colour is the old triangle's under where it landed,
// blended by where on it (the corners' weights), and a triangle's group is that of the
// old triangle under its first corner that found one. A vertex that found nothing within
// a cell (a cap's, say) takes the colour its neighbours agree on, else none. Nil for what
// the old mesh had none of; heap memory for surface_free.
remesh_surface :: proc(report: geom.Remesh_Report, out, source: geom.Mesh, color: []sculpt.Color, groups: []u16) -> (surface: Surface) {
	if report.groups != nil do surface.groups = slice.clone(report.groups)
	tris := report.source_tris
	if tris == nil do return
	if groups != nil && surface.groups == nil {
		surface.groups = make([]u16, len(out.indices) / 3)
		for t in 0 ..< len(surface.groups) {
			for c in 0 ..< 3 {
				if old := tris[out.indices[3 * t + c]]; old != max(u32) {
					surface.groups[t] = groups[old]
					break
				}
			}
		}
	}
	if color == nil do return
	surface.color = make([]sculpt.Color, len(out.positions))
	found := make([]bool, len(out.positions), context.temp_allocator)
	for old, v in tris {
		if old == max(u32) do continue
		a, b, c := source.indices[3 * old], source.indices[3 * old + 1], source.indices[3 * old + 2]
		_, bary := geom.closest_on_triangle(out.positions[v], source.positions[a], source.positions[b], source.positions[c])
		for ch in 0 ..< 4 {
			mixed := bary[0] * f32(color[a][ch]) + bary[1] * f32(color[b][ch]) + bary[2] * f32(color[c][ch])
			surface.color[v][ch] = u8(clamp(mixed + 0.5, 0, 255))
		}
		found[v] = true
	}
	// The vertices that found nothing: the mean of their neighbours that did, one pass,
	// in triangle order.
	sum := make([][4]f32, len(out.positions), context.temp_allocator)
	count := make([]f32, len(out.positions), context.temp_allocator)
	for i := 0; i < len(out.indices); i += 3 {
		for c in 0 ..< 3 {
			v := out.indices[i + c]
			if found[v] do continue
			for d in 1 ..< 3 {
				w := out.indices[i + (c + d) % 3]
				if !found[w] do continue
				for ch in 0 ..< 4 do sum[v][ch] += f32(surface.color[w][ch])
				count[v] += 1
			}
		}
	}
	for v in 0 ..< len(out.positions) {
		if found[v] || count[v] == 0 do continue
		for ch in 0 ..< 4 do surface.color[v][ch] = u8(clamp(sum[v][ch] / count[v] + 0.5, 0, 255))
	}
	return
}

surface_free :: proc(s: ^Surface) {
	delete(s.color)
	delete(s.groups)
	s^ = {}
}

// What the result line adds after the count for `setup`, from what the remesh reported:
// "; turned outward first; 2 triangles mended first; 2 holes closed first; 3 pieces, 1 too
// thin; detail kept; quads", or
// nothing. Temporary, so made after anything that frees the temp memory.
remesh_note :: proc(report: geom.Remesh_Report, setup: Remesh_Setup) -> string {
	b := strings.builder_make(context.temp_allocator)
	if report.turned do strings.write_string(&b, "; turned outward first")
	if n := report.mended; n > 0 do fmt.sbprintf(&b, "; %d triangle%s mended first", n, "" if n == 1 else "s")
	if n := report.holes_closed; n > 0 do fmt.sbprintf(&b, "; %d hole%s closed first", n, "" if n == 1 else "s")
	if setup.groups && report.pieces > 0 {
		fmt.sbprintf(&b, "; %d piece%s", report.pieces, "" if report.pieces == 1 else "s")
		if report.dropped > 0 do fmt.sbprintf(&b, ", %d too thin", report.dropped)
	}
	if setup.keep_detail do strings.write_string(&b, "; detail kept")
	if report.quads != nil do strings.write_string(&b, "; quads")
	return strings.to_string(b)
}

// Gives the base level of levels just made from a remesh with Quads (levels_init with the
// renumbering maps) the remesh's quads as its polygons, under the Catmull-Clark rule, so
// the wireframe draws the quads' edges and Divide cuts them as quads; and as its quad
// faces, so export and UV layout see quads, as a Quad Remesh's result is kept
// (retopo_apply). `quads` are in the remeshed mesh's numbers, triangles 2q and 2q + 1 quad
// q's halves (geom.Remesh_Report). On the frame thread or a long job's alike.
remesh_take_quads :: proc(l: ^sculpt.Levels, quads: [][4]u32, old_to_new, tri_from: []u32) {
	polys: sculpt.Polys
	polys.first = make([]u32, len(quads) + 1)
	polys.corners = make([]u32, 4 * len(quads))
	for &f, q in quads {
		polys.first[q + 1] = u32(4 * (q + 1))
		for c in 0 ..< 4 do polys.corners[4 * q + c] = old_to_new[f[c]]
	}
	polys.tri_poly = make([]u32, len(tri_from))
	for old, t in tri_from do polys.tri_poly[t] = old / 2
	if !sculpt.levels_set_polys(l, polys, {}, .Smooth) {
		log.error("remesh: the quads did not fit the triangles cut from them, so the object keeps none")
		return
	}
	faces := make([][4]u32, len(quads))
	for &f, q in faces do copy(f[:], polys.corners[4 * q:][:4])
	sculpt.levels_set_quads(l, faces)
}

// The option rows under Rebuild's Even density: Smooth, Keep detail, Quads and Groups
// (which has nothing to do on an object without polygroups, or under dynamic topology).
kit_remesh_options :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	smooth := f32(app.ui.remesh_smooth)
	if ui.slider(ctx, "Smooth", &smooth, 0, geom.REMESH_SMOOTH_MAX, .Linear, "None" if app.ui.remesh_smooth == 0 else fmt.tprintf("%d", app.ui.remesh_smooth)) {
		app.ui.remesh_smooth = i32(smooth + 0.5)
	}
	_ = ui.switch_row(ctx, "Keep detail", &app.ui.remesh_keep_detail)
	_ = ui.switch_row(ctx, "Quads", &app.ui.remesh_quads)
	grouped := obj != nil && !object_dynamic(obj) && sculpt.sculptor_has_groups(object_sculptor(obj))
	_ = ui.switch_row(ctx, "Groups", &app.ui.remesh_groups, enabled = grouped)
}
