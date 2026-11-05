package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"

import "../geom"
import "../jobs"
import "../sculpt"
import "../ui"

// Remesh's options beside its density, as DynaMesh offers Blur, Project and Groups
// beside its resolution: carried in the Scene_Command so Adjust last, macros and the long
// job run the very options the panel held. The geometry's own form is geom.Remesh_Options;
// remesh_options makes one from this and the object's polygroups.
Remesh_Setup :: struct {
	smooth:      int,  // relax rounds, 0 to geom.REMESH_SMOOTH_MAX
	keep_detail: bool, // the result put back on the old surface, its polypaint and polygroups along
	keep_thin:   bool, // parts thinner than a cell kept whole, about a cell thick (geom's keep_thin)
	// The polypaint, polygroups and mask carried from the old triangle nearest each vertex
	// without Keep detail too (Keep detail carries them from the one under it anyway).
	keep_paint:  bool,
	groups:      bool, // each polygroup a closed piece of its own
	quads:       bool, // a closed mesh of quads only (the marching cubes' dual), kept as the object's polygons
	mirror:      geom.Remesh_Mirror, // Keep symmetry: the brush's symmetry planes, which the result keeps (remesh_mirror)
	// The lattice spacing in the object's mesh space, or 0 for the one the command's
	// vertex count gives: Rebuild's Cell size, or the object's own cell for Remesh again.
	cell:        f32,
	// Subdivision levels built on the result, 0 to REMESH_LEVELS_MAX: the remesh is made
	// at a quarter of the count (or twice the cell) a level, divided back up to it and the
	// top fitted onto the old surface, so the dense result can be shaped from its coarse
	// levels, as ZBrush's DynaMesh then Divide and Project All gives (remesh_build_levels).
	levels:      int,
}

// The most levels Build levels offers: three make a 15M top from a base of about 230k.
REMESH_LEVELS_MAX :: 3
REMESH_LEVELS_NAMES := [REMESH_LEVELS_MAX + 1]string{"None", "1", "2", "3"}

// How Rebuild's Even goal sets its density: a vertex count, for a budget, or a cell size in
// millimetres, as Blender's voxel size, so objects of one scene get the same detail
// whatever their size and a remesh can be asked for at the size a print needs.
Remesh_By :: enum u8 {
	Vertices,
	Cell,
}

REMESH_BY_NAMES := [Remesh_By]string {
	.Vertices = "Vertices",
	.Cell     = "Cell size",
}

// The cell sizes Rebuild offers, in millimetres at the scene's print scale: from a
// hundredth of a millimetre, finer than any printer, to 50 mm, the starting sphere's
// whole width at the default scale. The default is a millimetre: 25 cells across the
// starting sphere's radius, about 10k vertices.
REMESH_CELL_MM_MIN :: 0.01
REMESH_CELL_MM_MAX :: 50
REMESH_CELL_MM_DEFAULT :: 1

// The panel's options, as a command takes them, with the symmetry on now.
remesh_setup :: proc(app: ^App) -> Remesh_Setup {
	obj := selected_object(app)
	cell := remesh_cell_of_mm(app, obj, app.ui.remesh_cell_mm) if app.ui.remesh_by == .Cell else 0
	return {smooth = int(app.ui.remesh_smooth), keep_detail = app.ui.remesh_keep_detail, keep_thin = app.ui.remesh_keep_thin, keep_paint = app.ui.remesh_keep_paint, groups = app.ui.remesh_groups, quads = app.ui.remesh_quads, mirror = remesh_mirror(app, obj), cell = cell, levels = int(clamp(app.ui.remesh_levels, 0, REMESH_LEVELS_MAX))}
}

// What Remesh again (Ctrl+R) runs: the panel's options at the object's own cell, the one
// its last remesh used, so the density stays as the sculpt grows, as ZBrush's DynaMesh
// keeps its resolution (and its count, when no remesh made it).
remesh_again_setup :: proc(app: ^App, obj: ^Object) -> Remesh_Setup {
	s := remesh_setup(app)
	s.cell = obj.remesh_cell if obj != nil else 0
	return s
}

// A cell of `mm` millimetres at the scene's print scale in `obj`'s mesh space, which its
// placing scales by transform.scale; 0 without an object.
remesh_cell_of_mm :: proc(app: ^App, obj: ^Object, mm: f32) -> f32 {
	if obj == nil || !(obj.transform.scale > 0) do return 0
	return mm / (print_scale(app) * obj.transform.scale)
}

// A cell in `obj`'s mesh space in millimetres at the scene's print scale.
remesh_cell_mm :: proc(app: ^App, obj: ^Object, cell: f32) -> f32 {
	if obj == nil do return 0
	return cell * obj.transform.scale * print_scale(app)
}

// The planes a remesh of `obj` keeps symmetric across: the brush's (symmetry_planes)
// while Keep symmetry is on, none when it is off.
remesh_mirror :: proc(app: ^App, obj: ^Object) -> geom.Remesh_Mirror {
	return symmetry_planes(app, obj) if app.ui.remesh_keep_symmetry else {}
}

// The panel set to a command's options (Adjust last).
remesh_setup_set :: proc(app: ^App, s: Remesh_Setup) {
	app.ui.remesh_smooth, app.ui.remesh_keep_detail, app.ui.remesh_keep_thin, app.ui.remesh_keep_paint, app.ui.remesh_groups, app.ui.remesh_quads = i32(s.smooth), s.keep_detail, s.keep_thin, s.keep_paint, s.groups, s.quads
	app.ui.remesh_levels = i32(s.levels)
	if s.mirror.axes != {} do app.ui.remesh_keep_symmetry = true
	// A cell shows as one only where the panel sets cells; a count's panel keeps its count.
	if s.cell > 0 && app.ui.remesh_by == .Cell do app.ui.remesh_cell_mm = clamp(remesh_cell_mm(app, selected_object(app), s.cell), REMESH_CELL_MM_MIN, REMESH_CELL_MM_MAX)
}

// The geometry's options for `setup` on a mesh whose triangles have `groups` (nil for
// none, as under dynamic topology): Groups does nothing without them. `surface` says the
// mesh has polypaint, polygroups or a mask, which Keep paint and mask then has looked up.
remesh_options :: proc(setup: Remesh_Setup, groups: []u16, surface := false) -> geom.Remesh_Options {
	// With levels the remesh makes the base, whose cell is twice the top's a level.
	cell := setup.cell * f32(int(1) << uint(setup.levels)) if setup.cell > 0 else 0
	return {smooth = setup.smooth, keep_detail = setup.keep_detail, keep_thin = setup.keep_thin, groups = groups if setup.groups else nil, quads = setup.quads, mirror = setup.mirror, cell = cell, sources = surface && setup.keep_paint}
}

// The count the remesh itself makes for a result of about `vertices` under `setup`: a
// quarter a level, since each level has about four times the vertices of the one below.
remesh_base_count :: proc(vertices: int, setup: Remesh_Setup) -> int {
	return max(vertices >> (2 * uint(setup.levels)), 1)
}

// Builds `setup.levels` subdivision levels on levels `l` just made from a remesh of
// `source`, each made current in turn, then fits the top onto `source` (with `cell` the
// base's lattice spacing): each vertex goes along its normal to the old surface when it
// is within two cells, as Project All does, except where that would turn a triangle over,
// which keeps its corners where the division put them. The levels below then take the
// shape when the top is synced down (levels_sync), as after a stroke. Returns how many
// levels were made: fewer on a base that is not closed, or when the progress was
// cancelled. On the frame thread or a long job's alike; `pool` is the levels'.
remesh_build_levels :: proc(l: ^sculpt.Levels, source: geom.Mesh, setup: Remesh_Setup, cell: f32, pool: ^jobs.Pool, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}) -> int {
	made := 0
	for made < setup.levels {
		if jobs.progress_cancelled(progress) do return made
		if !sculpt.levels_subdivide(l) do break
		made += 1
		jobs.progress_set(progress, 0, 1, share[0] + (share[1] - share[0]) * 0.8 * f32(made) / f32(setup.levels))
	}
	if made == 0 || len(source.indices) == 0 || jobs.progress_cancelled(progress) do return made
	top := sculpt.levels_current(l)
	m := &top.mesh
	bvh := geom.bvh_build_morton(source, pool = pool, allocator = runtime.heap_allocator())
	defer geom.bvh_destroy(&bvh)
	next := make([]geom.Vec3, len(m.positions), runtime.heap_allocator())
	defer delete(next, runtime.heap_allocator())
	_ = geom.project_along_normals(m.positions[:], m.normals[:], source, &bvh, 2 * cell, pool, next, nil)
	remesh_keep_unfolded(m^, next)
	sculpt.sculptor_place_all(&top.sculptor, next)
	sculpt.sculptor_recompute_all(&top.sculptor)
	jobs.progress_set(progress, 0, 1, share[1])
	return made
}

// Puts back where they were the corners of each triangle of `m` that `next` would turn
// over (its normal against the one it has now), a few rounds, since a corner put back
// can turn a neighbour that kept its own.
@(private = "file")
remesh_keep_unfolded :: proc(m: geom.Mesh, next: []geom.Vec3) {
	for _ in 0 ..< 3 {
		reverted := 0
		for i := 0; i < len(m.indices); i += 3 {
			a, b, c := m.indices[i], m.indices[i + 1], m.indices[i + 2]
			was := linalg.cross(m.positions[b] - m.positions[a], m.positions[c] - m.positions[a])
			now := linalg.cross(next[b] - next[a], next[c] - next[a])
			if linalg.dot(was, now) > 0 do continue
			for v in ([3]u32{a, b, c}) {
				if next[v] != m.positions[v] {
					next[v] = m.positions[v]
					reverted += 1
				}
			}
		}
		if reverted == 0 do return
	}
}

// The polypaint, polygroups and mask the remeshed mesh `out` takes from the mesh it came
// from, through what the remesh reported: with Groups each triangle's piece names its
// group; each vertex's colour and mask are the old triangle's it landed on (with Keep
// detail) or nearest it, blended by where on it (the corners' weights), and a triangle's
// group is that of the old triangle of its first corner that found one, as Blender's
// voxel remesh carries them. A vertex that found nothing (a cap's, say) takes the colour
// and mask its neighbours agree on, else none. Nil for what the old mesh had none of;
// heap memory for surface_free.
remesh_surface :: proc(report: geom.Remesh_Report, out, source: geom.Mesh, color: []sculpt.Color, groups: []u16, mask: []u8 = nil) -> (surface: Surface) {
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
	if color != nil do surface.color = carry_per_vertex(sculpt.Color, color, tris, out, source)
	if mask != nil do surface.mask = transmute([]u8)carry_per_vertex([1]u8, transmute([][1]u8)mask, tris, out, source)
	return
}

// A per-vertex value of `source` (colour channels, or the mask as one) carried onto each
// vertex of `out` from the old triangle `tris` names, blended by where on it the vertex
// lies; the vertices that found none take the mean of their neighbours that did, one pass
// in triangle order. Heap memory.
@(private = "file")
carry_per_vertex :: proc($T: typeid/[$N]u8, values: []T, tris: []u32, out, source: geom.Mesh) -> []T {
	result := make([]T, len(out.positions))
	found := make([]bool, len(out.positions), context.temp_allocator)
	for old, v in tris {
		if old == max(u32) do continue
		a, b, c := source.indices[3 * old], source.indices[3 * old + 1], source.indices[3 * old + 2]
		_, bary := geom.closest_on_triangle(out.positions[v], source.positions[a], source.positions[b], source.positions[c])
		for ch in 0 ..< N {
			mixed := bary[0] * f32(values[a][ch]) + bary[1] * f32(values[b][ch]) + bary[2] * f32(values[c][ch])
			result[v][ch] = u8(clamp(mixed + 0.5, 0, 255))
		}
		found[v] = true
	}
	sum := make([][N]f32, len(out.positions), context.temp_allocator)
	count := make([]f32, len(out.positions), context.temp_allocator)
	for i := 0; i < len(out.indices); i += 3 {
		for c in 0 ..< 3 {
			v := out.indices[i + c]
			if found[v] do continue
			for d in 1 ..< 3 {
				w := out.indices[i + (c + d) % 3]
				if !found[w] do continue
				for ch in 0 ..< N do sum[v][ch] += f32(result[w][ch])
				count[v] += 1
			}
		}
	}
	for v in 0 ..< len(out.positions) {
		if found[v] || count[v] == 0 do continue
		for ch in 0 ..< N do result[v][ch] = u8(clamp(sum[v][ch] / count[v] + 0.5, 0, 255))
	}
	return result
}

surface_free :: proc(s: ^Surface) {
	delete(s.color)
	delete(s.groups)
	delete(s.mask)
	s^ = {}
}

// What the result line adds after the count for `setup`, from what the remesh reported:
// "; turned outward first; 2 triangles mended first; 2 holes closed first; 3 pieces, 1 too
// thin; thin parts kept; paint and mask kept; detail kept; quads", or
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
	if report.thickened > 0 do strings.write_string(&b, "; thin parts kept")
	if report.source_tris != nil && !setup.keep_detail do strings.write_string(&b, "; paint and mask kept")
	if setup.keep_detail do strings.write_string(&b, "; detail kept")
	if report.quads != nil do strings.write_string(&b, "; quads")
	if n := setup.levels; n > 0 do fmt.sbprintf(&b, "; %d level%s built", n, "" if n == 1 else "s")
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

// The option rows under Rebuild's Even density: whether Density is a count or a cell size
// (as Fewer keeps its share or count there), Smooth, Keep detail, Keep thin parts, Keep paint and mask, Quads, Groups (which has
// nothing to do on an object without polygroups, or under dynamic topology), Keep
// symmetry and Build levels.
kit_remesh_options :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	names: [len(Remesh_By)]string
	for b in Remesh_By do names[int(b)] = REMESH_BY_NAMES[b]
	if picked := ui.tabs(ctx, "remesh by", names[:], int(app.ui.remesh_by)); picked >= 0 do app.ui.remesh_by = Remesh_By(picked)
	smooth := f32(app.ui.remesh_smooth)
	if ui.slider(ctx, "Smooth", &smooth, 0, geom.REMESH_SMOOTH_MAX, .Linear, "None" if app.ui.remesh_smooth == 0 else fmt.tprintf("%d", app.ui.remesh_smooth)) {
		app.ui.remesh_smooth = i32(smooth + 0.5)
	}
	_ = ui.switch_row(ctx, "Keep detail", &app.ui.remesh_keep_detail)
	_ = ui.switch_row(ctx, "Keep thin parts", &app.ui.remesh_keep_thin)
	_ = ui.switch_row(ctx, "Keep paint and mask", &app.ui.remesh_keep_paint)
	_ = ui.switch_row(ctx, "Quads", &app.ui.remesh_quads)
	grouped := obj != nil && !object_dynamic(obj) && sculpt.sculptor_has_groups(object_sculptor(obj))
	_ = ui.switch_row(ctx, "Groups", &app.ui.remesh_groups, enabled = grouped)
	kit_keep_symmetry(app, &app.ui.remesh_keep_symmetry)
	ui.label(ctx, "Build levels")
	if picked := ui.select(ctx, "Build levels", REMESH_LEVELS_NAMES[:], int(clamp(app.ui.remesh_levels, 0, REMESH_LEVELS_MAX))); picked >= 0 do app.ui.remesh_levels = i32(picked)
}
