package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

import "../geom"
import "../jobs"
import "../render"
import "../png_write"
import "../quadmesh"
import "../sculpt"
import "../ui"

// Retopology and baking on the app side: Quad Remesh makes a new object of quads from
// the selected one (quadmesh.remesh, or geom.mesh_retopo), with UVs laid out
// (geom.quad_uv_unwrap), next to it; Bake maps... then bakes another object's detail into normal and displacement maps
// on it (geom.bake_maps) and writes them to a folder with the quads as OBJ. Both work in
// the objects' own spaces, so moving or turning either object changes nothing.

// UV padding around each chart, in texels of the largest map size, so even a 4096 map
// keeps charts apart when filtered.
UV_PADDING :: f32(8.0 / 4096)

BAKE_SIZES := [?]i32{512, 1024, 2048, 4096}

Bake_Settings :: struct {
	source:          int, // id of the object to bake from; 0 picks the one the quads came from
	size:            i32, // texels square
	reach_edges:     f32, // how far rays look, in the quads' average edge length
	// The bake set's maps beyond normal and displacement (geom.Bake_Kind).
	base_color:      bool,
	orm:             bool,
	id:              bool,
	occlusion_rays:  i32, // per texel, 0 for none
	occlusion_reach: f32, // as a share of the source's size (its bounds' diagonal)
}

BAKE_OCCLUSION_RAYS_MAX :: 64

// The mesh to read the object's shape from: its top level (with the edits on any level
// carried up), or a packed copy when dynamic. Normals are computed fresh into `normals`
// (its own allocation, which the caller frees, along with `packed`).
object_shape :: proc(obj: ^Object, top: bool) -> (view: geom.Mesh, packed: geom.Mesh) {
	if object_dynamic(obj) {
		mask: []u8
		packed, mask = sculpt.sculptor_compact_mesh(object_sculptor(obj))
		delete(mask)
		view = packed
	} else {
		sculpt.levels_sync(&obj.levels)
		lv := obj.levels.levels[len(obj.levels.levels) - 1] if top else sculpt.levels_current(&obj.levels)
		// A view of the level's arrays, with normals of its own.
		view = geom.Mesh{positions = lv.mesh.positions, indices = lv.mesh.indices}
	}
	view.normals = make([dynamic]geom.Vec3, len(view.positions))
	geom.mesh_recompute_normals(&view)
	return
}

// Which quad remesher Quad Remesh (Rebuild's Quads) runs: AutoRemesher (src/quadmesh),
// whose edge flow follows the surface's curvature as ZBrush's ZRemesher does, or the own
// edge-pairing retopology (geom.mesh_retopo), quicker and plainer. AutoRemesher is the
// default; where it is not built, or refuses the mesh, the own one runs in its place and
// the report says why.
Quad_Engine :: enum u8 {
	Auto,
	Own,
}

QUAD_ENGINE_NAMES := [Quad_Engine]string {
	.Auto = "AutoRemesher",
	.Own  = "Built-in",
}

// Symmetry for AutoRemesher: the half of the object on the + side of the plane through
// its origin across the axis (the sculpt's own symmetry plane, as Mirror and weld cuts)
// is remeshed and mirrored, so the two halves match quad for quad along the seam.
Quad_Symmetry :: enum u8 {
	Off,
	X,
	Y,
	Z,
}

QUAD_SYMMETRY_NAMES := [Quad_Symmetry]string {
	.Off = "Whole",
	.X   = "Mirror X",
	.Y   = "Mirror Y",
	.Z   = "Mirror Z",
}

// What a Quad Remesh runs with besides the count: carried in the scene command, so the
// long job's thread reads no interface state, and put back by Adjust last.
Quad_Options :: struct {
	engine:      Quad_Engine,
	adaptivity:  f32, // 0 quads of one size, 1 smaller ones where the surface bends (AutoRemesher; fewer quads than asked)
	symmetry:    Quad_Symmetry, // AutoRemesher only
	close_first: bool, // an open or unsound mesh is voxel remeshed first, whichever engine runs
}

// The options as the Rebuild section has them set.
quad_options :: proc(app: ^App) -> Quad_Options {
	return {app.ui.retopo_engine, app.ui.retopo_adaptivity, app.ui.retopo_symmetry, app.ui.retopo_close_first}
}

quad_options_set :: proc(app: ^App, o: Quad_Options) {
	app.ui.retopo_engine, app.ui.retopo_adaptivity, app.ui.retopo_symmetry, app.ui.retopo_close_first = o.engine, o.adaptivity, o.symmetry, o.close_first
}

// Close first voxel remeshes at this many vertices a quad asked for (a lattice of a few
// cells across each quad, so the flow has a surface to follow), never under the floor.
QUAD_CLOSE_VERTICES_PER_QUAD :: 20
QUAD_CLOSE_MIN_VERTICES :: 20_000

// AutoRemesher takes seconds and hundreds of megabytes per million triangles, and past
// about that many its result depends little on the input's density, so a bigger input is
// decimated to this first.
QUAD_REMESH_MAX_TRIANGLES :: 1_000_000
// Each separate part is an island AutoRemesher parameterizes alone, with a floor of cells
// each, so a dust of fragments is refused rather than left to it.
QUAD_REMESH_MAX_PIECES :: 256
// A remeshed half's seam vertices within this share of the object's size of the symmetry
// plane are put on it: AutoRemesher smooths its boundary along the cut loop, which lies
// on the plane, so they are near it but not on it to the bit.
@(private = "file")
QUAD_SEAM_SNAP :: f32(1e-4)
// The rim between a half and its flat cap meets at 90 degrees on a smooth sculpt; kept as
// a sharp edge from this angle, so the quads line up with the seam.
@(private = "file")
QUAD_SEAM_SHARP_DEGREES :: f32(60)

// Where the progress ring stands after each of AutoRemesher's stages: the decimation past
// the cap, the check with Close first's voxel remesh, the remesh itself; the mirror and
// the UVs take the rest. The own engine, standing in, starts from the check.
@(private = "file")
QUAD_SHARE_CAPPED :: f32(0.05)
@(private = "file")
QUAD_SHARE_CHECKED :: f32(0.2)
@(private = "file")
QUAD_SHARE_REMESHED :: f32(0.85)

// Makes a new object of about `quads` quads on the shape of the level the selected
// object is on, with UVs, next to it, and selects it. Returns false only on a GPU failure.
// A long job (long_job.odin) runs the same two halves, retopo_compute on its thread.
object_retopo :: proc(app: ^App, obj: ^Object, quads: int, options: Quad_Options) -> (made, ok: bool) {
	stroke_finish(app)
	object_hd_leave(app, obj)
	start := time.tick_now()
	view, packed := object_shape(obj, top = false)
	r := retopo_compute(view, quads, options, &app.pool)
	delete(view.normals)
	geom.mesh_destroy(&packed)
	if !r.built {
		log.warnf("quad remesh: %s has too few triangles for %d quads", object_label(obj), quads)
		return false, true
	}
	return retopo_apply(app, obj, &r, start)
}

// What Quad Remesh computes before it makes the object: the triangles drawn and sculpted,
// the polygons they came from and, when every polygon is a quad, the quads with their UVs.
Retopo_Result :: struct {
	q:         geom.Quad_Mesh, // every polygon a quad: the quads, over positions `mesh` copied; nil otherwise
	how:       geom.Retopo_Report, // the own engine's account
	uv:        geom.Uv_Layout, // with `q`
	mesh:      geom.Mesh,
	polys:     sculpt.Polys, // AutoRemesher: the polygons as the base level keeps them, over `mesh`
	engine:    Quad_Engine, // the engine that made it: Auto may have given way to Own
	faces:     int, // AutoRemesher's polygons...
	quads:     int, // ...of which quads,
	triangles: int, // triangles
	ngons:     int, // and five corners or more
	capped:    int, // AutoRemesher: triangles the input was decimated to first, 0 for none
	closed:    int, // Close first: vertices of the voxel remesh that stood in for the input, 0 for none
	mirrored:  bool, // one half remeshed and mirrored, as the symmetry asked
	unmirrored: string, // symmetry asked but not done: why (a literal, not owned)
	reason:    string, // owned: why AutoRemesher was not used, "" when it was
	built:     bool,
	retopo_ms: f64,
	uv_ms:     f64,
}

// The quads of about `quads` on `view` (with normals) by the engine and options, their
// UVs and triangles; touches no object or interface, so a long job runs it on its own
// thread with its own pool, and with `progress` it stops after a cancel, built false with
// nothing to free. AutoRemesher gives way to the own engine when it is not built or
// refuses the mesh, and `reason` then says why; the own engine knows neither adaptivity
// nor symmetry, but Close first serves it too.
retopo_compute :: proc(view: geom.Mesh, quads: int, options: Quad_Options, pool: ^jobs.Pool, progress: ^jobs.Progress = nil) -> (r: Retopo_Result) {
	start := time.tick_now()
	from: f32 = 0
	closed: geom.Mesh
	defer geom.mesh_destroy(&closed)
	input := view
	if options.engine == .Auto {
		outcome: Quad_Outcome
		r, outcome = quad_remesh_compute(view, quads, options, pool, progress)
		if outcome != .Fallback do return
		from = QUAD_SHARE_CHECKED
	} else if options.close_first {
		closed, r.closed = quad_close_first(view, quads, pool, progress, {0, QUAD_SHARE_CHECKED})
		if jobs.progress_cancelled(progress) do return {}
		if r.closed > 0 {
			resize(&closed.normals, len(closed.positions))
			geom.mesh_recompute_normals(&closed)
			input = closed
		}
		from = QUAD_SHARE_CHECKED
	}
	bvh := geom.bvh_build_morton(input, geom.BVH_LEAF_SIZE, pool)
	defer geom.bvh_destroy(&bvh)
	q, how, built := geom.mesh_retopo(input, &bvh, quads, pool, progress = progress, share = {from, 0.9})
	free_all(context.temp_allocator)
	if !built || jobs.progress_cancelled(progress) {
		if built do geom.quad_mesh_destroy(&q)
		delete(r.reason)
		return {}
	}
	r.retopo_ms = time.duration_milliseconds(time.tick_since(start))
	uv_start := time.tick_now()
	r.uv = geom.quad_uv_unwrap(q, UV_PADDING)
	r.uv_ms = time.duration_milliseconds(time.tick_since(uv_start))
	r.mesh = geom.quad_mesh_triangulate(q)
	r.q, r.how, r.engine, r.built = q, how, .Own, true
	r.faces, r.quads = len(q.quads), len(q.quads)
	if options.symmetry != .Off do r.unmirrored = "the built-in engine knows no symmetry"
	jobs.progress_set(progress, 0, 1, 1)
	return
}

// Close first's voxel remesh of `m` when it is open, or unsound in a way the quad
// engines would refuse or mangle (an edge of three faces, a flipped, flat or doubled
// triangle): a closed, manifold surface at QUAD_CLOSE_VERTICES_PER_QUAD vertices a quad
// asked for, overlapping parts merged as Remesh merges them. A mesh that needs none, or
// that the remesh cannot take, gives back nothing (`vertices` 0).
@(private = "file")
quad_close_first :: proc(m: geom.Mesh, quads: int, pool: ^jobs.Pool, progress: ^jobs.Progress, share: [2]f32) -> (out: geom.Mesh, vertices: int) {
	whole := geom.mesh_integrity(m, pool)
	c := whole.check
	if c.closed && c.degenerate_triangles == 0 && c.inconsistent_edges == 0 && whole.duplicate_triangles == 0 do return
	target := clamp(QUAD_CLOSE_VERTICES_PER_QUAD * quads, QUAD_CLOSE_MIN_VERTICES, QUAD_REMESH_MAX_TRIANGLES / 2)
	area, bounds := geom.mesh_area_bounds(m, pool)
	ok: bool
	out, ok = geom.remesh_voxel_measured(m, area, bounds, target, pool, progress = progress, share = share)
	if !ok do return {}, 0
	return out, len(out.positions)
}

@(private = "file")
Quad_Outcome :: enum u8 {
	Built,
	Cancelled, // nothing kept
	Fallback, // only `reason` kept: the own engine runs instead
}

// AutoRemesher's half of retopo_compute: refuses what it cannot take (or runs forever
// on) before it starts, decimates past the cap, remeshes, and turns the polygons into the
// triangles the object is built of, with the quads and UVs when every polygon is a quad.
@(private = "file")
quad_remesh_compute :: proc(view: geom.Mesh, quads: int, options: Quad_Options, pool: ^jobs.Pool, progress: ^jobs.Progress) -> (r: Retopo_Result, outcome: Quad_Outcome) {
	start := time.tick_now()
	outcome = .Fallback
	// Fewer triangles first past the cap: more make AutoRemesher slower, not better, and
	// the check below has no cancel and a serial pass or two, so it runs on the smaller mesh.
	input := view
	capped: geom.Mesh
	defer geom.mesh_destroy(&capped)
	if len(view.indices) / 3 > QUAD_REMESH_MAX_TRIANGLES {
		ok: bool
		capped, _, ok = geom.mesh_decimate(view, QUAD_REMESH_MAX_TRIANGLES, pool, progress = progress, share = {0, QUAD_SHARE_CAPPED})
		if jobs.progress_cancelled(progress) do return {}, .Cancelled
		if ok {
			input = capped
			r.capped = len(capped.indices) / 3
		}
	}
	// Close first: an open or unsound mesh becomes a closed one before anything judges it.
	closed: geom.Mesh
	defer geom.mesh_destroy(&closed)
	if options.close_first {
		closed, r.closed = quad_close_first(input, quads, pool, progress, {QUAD_SHARE_CAPPED, QUAD_SHARE_CHECKED})
		if jobs.progress_cancelled(progress) do return {}, .Cancelled
		if r.closed > 0 do input = closed
	}
	// What AutoRemesher cannot take, or runs forever on, is refused before it starts.
	whole := geom.mesh_integrity(input, pool)
	jobs.progress_set(progress, 0, QUAD_SHARE_CHECKED, 1)
	c := whole.check
	switch {
	case c.triangles < 4:                       r.reason = fmt.aprintf("%d triangles are too few", c.triangles)
	case c.nan_count > 0:                       r.reason = fmt.aprintf("%d positions are not numbers", c.nan_count)
	case c.degenerate_triangles > 0:            r.reason = fmt.aprintf("%d triangles have no area", c.degenerate_triangles)
	case whole.duplicate_triangles > 0:         r.reason = fmt.aprintf("%d triangles lie over another", whole.duplicate_triangles)
	case c.non_manifold_edges > 0:              r.reason = fmt.aprintf("%d edges have more than two faces", c.non_manifold_edges)
	case c.inconsistent_edges > 0:              r.reason = fmt.aprintf("%d faces are turned inside out", c.inconsistent_edges)
	case whole.pieces > QUAD_REMESH_MAX_PIECES: r.reason = fmt.aprintf("%d separate pieces are too many", whole.pieces)
	}
	if r.reason != "" do return
	if jobs.progress_cancelled(progress) {
		delete(r.reason)
		return {}, .Cancelled
	}
	// Symmetry: the + half alone goes in and comes back mirrored. It goes in closed, its
	// cut capped flat on the plane, since AutoRemesher fills a small hole of its own
	// accord and smooths a larger one's rim off the plane; the cap's polygons lie on the
	// plane and are dropped after. The count asked for covers the cap too, and the rim is
	// kept as a sharp edge so the quads line up with the seam. A plane the mesh does not
	// cross leaves it whole.
	half: geom.Mesh
	defer geom.mesh_destroy(&half)
	axis := int(options.symmetry) - 1
	snap: f32
	asked := quads
	if options.symmetry != .Off {
		normal: geom.Vec3
		normal[axis] = 1
		back: geom.Mesh
		ok: bool
		half, back, ok = geom.mesh_slice(input, {}, normal, true, pool)
		geom.mesh_destroy(&back)
		if ok {
			extent := c.bounds.hi - c.bounds.lo
			snap = max(extent.x, extent.y, extent.z) * QUAD_SEAM_SNAP
			total, cap := quad_cap_share(half, axis, snap)
			asked = int(f64(quads / 2) * total / max(total - cap, total * 0.01))
			r.mirrored = true
		} else {
			r.unmirrored = "the mesh does not cross the plane"
		}
	}
	whole_input := input
	if r.mirrored do input = half
	params := quadmesh.DEFAULT_PARAMS
	params.adaptivity = clamp(options.adaptivity, 0, 1)
	params.threads = clamp(jobs.pool_size(pool) if pool != nil else 1, 1, quadmesh.MAX_THREADS)
	out: quadmesh.Polygon_Mesh
	defer quadmesh.polygon_mesh_destroy(&out)
	seam: [dynamic]bool
	defer delete(seam)
	mesh: geom.Mesh
	polys: sculpt.Polys
	check: geom.Mesh_Report
	report: quadmesh.Report
	// The mirrored result must close along its seam; when it does not (a cap AutoRemesher
	// laid across the cut that the plane did not catch), the whole mesh is remeshed instead.
	for {
		params.quads = asked
		params.sharp_degrees = QUAD_SEAM_SHARP_DEGREES if r.mirrored else quadmesh.DEFAULT_PARAMS.sharp_degrees
		err: quadmesh.Error
		reason: string
		out, report, err, reason = quadmesh.remesh(input.positions[:], input.indices[:], params, progress, {QUAD_SHARE_CHECKED, QUAD_SHARE_REMESHED})
		switch err {
		case .Cancelled:
			return {}, .Cancelled
		case .Refused, .Failed, .Unavailable:
			delete(r.reason)
			r.reason = strings.clone(reason)
			return
		case .None:
		}
		if r.mirrored {
			bvh := geom.bvh_build_morton(half, geom.BVH_LEAF_SIZE, pool)
			cap: []bool
			cap, seam = quad_seam_classify(out, half, &bvh, axis, snap)
			geom.bvh_destroy(&bvh)
			dropped := polygon_mesh_mirror(&out, axis, cap, &seam)
			delete(cap)
			if dropped > 0 do log.infof("quad remesh: %d polygons lay on the symmetry plane and went", dropped)
			report.faces = len(out.first) - 1
			report.quads, report.triangles, report.ngons = quadmesh.polygon_share(out)
		}
		mesh, polys = polygon_mesh_triangulate(out, seam[:])
		check = geom.mesh_check(mesh)
		if !r.mirrored || check.non_manifold_edges == 0 do break
		log.warnf("quad remesh: the mirrored halves left %d non-manifold edges along the seam, so the whole mesh is remeshed instead", check.non_manifold_edges)
		geom.mesh_destroy(&mesh)
		sculpt.polys_destroy(&polys)
		quadmesh.polygon_mesh_destroy(&out)
		delete(seam)
		seam = nil
		r.mirrored, r.unmirrored = false, "the seam did not close"
		input, asked = whole_input, quads
		if jobs.progress_cancelled(progress) do return {}, .Cancelled
	}
	r.faces, r.quads, r.triangles, r.ngons = report.faces, report.quads, report.triangles, report.ngons
	if check.closed && check.inverted {
		// AutoRemesher's winding follows its input's, so this is not expected; the sculpt
		// wants every face outward, so each polygon is turned round and cut again.
		polygon_mesh_flip(&out)
		geom.mesh_destroy(&mesh)
		sculpt.polys_destroy(&polys)
		mesh, polys = polygon_mesh_triangulate(out, seam[:])
		check = geom.mesh_check(mesh)
	}
	log.infof("quad remesh: AutoRemesher gave %d polygons (%d quads, %d triangles, %d larger) over %d vertices from %d triangles%s in %.0f ms; %s, %d boundary and %d non-manifold edges",
		r.faces, r.quads, r.triangles, r.ngons, len(mesh.positions), c.triangles, fmt.tprintf(" decimated to %d", r.capped) if r.capped > 0 else "", report.ms,
		"closed" if check.closed else "open", check.boundary_edges, check.non_manifold_edges)
	if jobs.progress_cancelled(progress) {
		geom.mesh_destroy(&mesh)
		sculpt.polys_destroy(&polys)
		return {}, .Cancelled
	}
	r.retopo_ms = time.duration_milliseconds(time.tick_since(start))
	if r.quads == r.faces {
		// Every face a quad: the quads as the base level keeps them, with UVs (the
		// triangles are already two a quad, in the quads' order, as quad_mesh_triangulate
		// cuts them).
		q: geom.Quad_Mesh
		q.positions = make([]geom.Vec3, len(mesh.positions))
		copy(q.positions, mesh.positions[:])
		q.quads = make([][4]u32, r.faces)
		for &f, k in q.quads do copy(f[:], polys.corners[4 * k:4 * k + 4])
		uv_start := time.tick_now()
		r.uv = geom.quad_uv_unwrap(q, UV_PADDING)
		r.uv_ms = time.duration_milliseconds(time.tick_since(uv_start))
		r.q = q
	}
	r.mesh, r.polys, r.engine, r.built = mesh, polys, .Auto, true
	jobs.progress_set(progress, 0, 1, 1)
	return r, .Built
}

// The polygons as triangles, counter-clockwise as the polygons are: a triangle as it is,
// a quad along its shorter diagonal (two triangles, quad k giving 2k and 2k + 1, as
// quad_mesh_triangulate does), a larger polygon as a fan from its first corner; `polys`
// says which polygon each triangle came from. A vertex no polygon uses is dropped, with
// the corners renumbered. Zero normals: the object's build computes them. With `seam`
// (per vertex, from a mirrored half) no cut runs between two seam vertices: a polygon and
// its mirror image would both cut there, and the edge would have four triangles.
@(private = "file")
polygon_mesh_triangulate :: proc(m: quadmesh.Polygon_Mesh, seam: []bool = nil, allocator := context.allocator) -> (mesh: geom.Mesh, polys: sculpt.Polys) {
	faces := len(m.first) - 1
	used := make([]u32, len(m.positions))
	defer delete(used)
	count: u32
	for c in m.corners do if used[c] == 0 {
		count += 1
		used[c] = count
	}
	mesh.positions = make([dynamic]geom.Vec3, count, allocator)
	for p, v in m.positions do if used[v] > 0 do mesh.positions[used[v] - 1] = p
	mesh.normals = make([dynamic]geom.Vec3, count, allocator)
	polys.first = make([]u32, faces + 1, allocator)
	polys.corners = make([]u32, len(m.corners), allocator)
	copy(polys.first, m.first)
	for c, i in m.corners do polys.corners[i] = used[c] - 1
	triangles := len(m.corners) - 2 * faces
	mesh.indices = make([dynamic]u32, 0, 3 * triangles, allocator)
	polys.tri_poly = make([]u32, triangles, allocator)
	t := 0
	for f in 0 ..< faces {
		corners := polys.corners[polys.first[f]:polys.first[f + 1]]
		// The seam flags are over the polygons' own numbering, before the compaction.
		given := m.corners[m.first[f]:m.first[f + 1]]
		on_seam :: proc(seam: []bool, c: u32) -> bool {return seam != nil && seam[c]}
		switch len(corners) {
		case 3:
			append(&mesh.indices, ..corners)
		case 4:
			c0, c1, c2, c3 := corners[0], corners[1], corners[2], corners[3]
			cut := geom.quad_split(mesh.positions[:], {c0, c1, c2, c3})
			switch {
			case on_seam(seam, given[0]) && on_seam(seam, given[2]): cut = {c0, c1, c3, c1, c2, c3}
			case on_seam(seam, given[1]) && on_seam(seam, given[3]): cut = {c0, c1, c2, c0, c2, c3}
			}
			append(&mesh.indices, ..cut[:])
		case:
			apex := 0
			for c, k in given do if !on_seam(seam, c) {
				apex = k
				break
			}
			count := len(corners)
			for k in 1 ..< count - 1 do append(&mesh.indices, corners[apex], corners[(apex + k) % count], corners[(apex + k + 1) % count])
		}
		for ; t < len(mesh.indices) / 3; t += 1 do polys.tri_poly[t] = u32(f)
	}
	return
}

// The area of `m` and of its triangles lying on the plane across `axis` (within `snap`):
// a capped half's cap.
@(private = "file")
quad_cap_share :: proc(m: geom.Mesh, axis: int, snap: f32) -> (total, cap: f64) {
	for k := 0; k < len(m.indices); k += 3 {
		a, b, c := m.positions[m.indices[k]], m.positions[m.indices[k + 1]], m.positions[m.indices[k + 2]]
		area := f64(linalg.length(linalg.cross(b - a, c - a))) / 2
		total += area
		if abs(a[axis]) <= snap && abs(b[axis]) <= snap && abs(c[axis]) <= snap do cap += area
	}
	return
}

// Turns every polygon round, so the surface faces the other way.
@(private = "file")
polygon_mesh_flip :: proc(m: ^quadmesh.Polygon_Mesh) {
	for f in 0 ..< len(m.first) - 1 do slice.reverse(m.corners[m.first[f]:m.first[f + 1]])
}

// Which of the remeshed half's polygons are its flat cap, to drop, and which vertices are
// then the seam: a polygon is cap when the nearest point of the capped half `half` (with
// `bvh` over it) to its middle lies on a cap triangle (one with its three corners on the
// plane), and a seam vertex is one that a kept polygon and a dropped one share. The
// polygons' own distance to the plane does not tell: AutoRemesher's quads straddle the
// rim, a corner or two smoothed onto the side, so a cap polygon can have a corner off the
// plane and a side polygon one on it. The kept polygons' border is then exactly the seam
// edges, which the mirror closes.
@(private = "file")
quad_seam_classify :: proc(m: quadmesh.Polygon_Mesh, half: geom.Mesh, bvh: ^geom.Bvh, axis: int, snap: f32, allocator := context.allocator) -> (dropped: []bool, seam: [dynamic]bool) {
	on_cap := make([]bool, len(half.indices) / 3, context.temp_allocator)
	defer delete(on_cap, context.temp_allocator)
	for &flat, t in on_cap {
		a, b, c := half.positions[half.indices[3 * t]], half.positions[half.indices[3 * t + 1]], half.positions[half.indices[3 * t + 2]]
		flat = abs(a[axis]) <= snap && abs(b[axis]) <= snap && abs(c[axis]) <= snap
	}
	faces := len(m.first) - 1
	dropped = make([]bool, faces, allocator)
	seam = make([dynamic]bool, len(m.positions), allocator)
	in_kept := make([]bool, len(m.positions), context.temp_allocator)
	defer delete(in_kept, context.temp_allocator)
	in_dropped := make([]bool, len(m.positions), context.temp_allocator)
	defer delete(in_dropped, context.temp_allocator)
	hint := geom.BVH_NONE
	for f in 0 ..< faces {
		corners := m.corners[m.first[f]:m.first[f + 1]]
		middle: geom.Vec3
		for c in corners do middle += m.positions[c]
		middle /= f32(len(corners))
		if tri, _, _, ok := geom.bvh_closest(bvh^, half, middle, max(f32), hint); ok {
			dropped[f] = on_cap[tri]
			hint = tri
		}
		for c in corners {
			if dropped[f] do in_dropped[c] = true
			else do in_kept[c] = true
		}
	}
	for v in 0 ..< len(m.positions) do seam[v] = in_kept[v] && in_dropped[v]
	// A chord: an edge between two kept polygons whose ends are both seam. Its mirror image
	// would make four faces on it, so the more cap-like of the two polygons goes too, and
	// the seam is drawn again, until no chord is left (a round or two).
	edges := make(map[[2]u32][2]i32, context.temp_allocator)
	defer delete(edges)
	for _ in 0 ..< 8 {
		clear(&edges)
		for f in 0 ..< faces {
			if dropped[f] do continue
			corners := m.corners[m.first[f]:m.first[f + 1]]
			for c, k in corners {
				d := corners[(k + 1) % len(corners)]
				e := [2]u32{min(c, d), max(c, d)}
				at := edges[e] if e in edges else [2]i32{-1, -1}
				if at[0] < 0 {
					at[0] = i32(f)
				} else {
					at[1] = i32(f)
				}
				edges[e] = at
			}
		}
		went := 0
		for e, at in edges {
			if at[0] < 0 || at[1] < 0 || !seam[e[0]] || !seam[e[1]] do continue
			more :: proc(m: quadmesh.Polygon_Mesh, seam: []bool, f: i32) -> int {
				n := 0
				for c in m.corners[m.first[f]:m.first[f + 1]] do if seam[c] do n += 1
				return n
			}
			a, b := more(m, seam[:], at[0]), more(m, seam[:], at[1])
			f := at[0] if a > b || (a == b && at[0] < at[1]) else at[1]
			if !dropped[f] {
				dropped[f] = true
				went += 1
			}
		}
		if went == 0 do break
		for v in 0 ..< len(m.positions) do in_kept[v], in_dropped[v] = false, false
		for f in 0 ..< faces do for c in m.corners[m.first[f]:m.first[f + 1]] {
			if dropped[f] do in_dropped[c] = true
			else do in_kept[c] = true
		}
		for v in 0 ..< len(m.positions) do seam[v] = in_kept[v] && in_dropped[v]
	}
	return
}

// Mirrors the polygons across the plane through the origin across `axis`, the `dropped`
// ones (the cap over the cut) left out: a `seam` vertex is put on the plane and shared by
// both halves, every other vertex gets a mirrored copy, and every kept polygon a reversed
// copy over the copies, so the result is closed where the kept polygons' border is the
// seam. Returns how many polygons went; `seam` grows to cover the copies (none of them seam).
@(private = "file")
polygon_mesh_mirror :: proc(m: ^quadmesh.Polygon_Mesh, axis: int, dropped_faces: []bool, seam: ^[dynamic]bool) -> (dropped: int) {
	n := len(m.positions)
	twin := make([]u32, n)
	defer delete(twin)
	positions := make([dynamic]geom.Vec3, n, 2 * n)
	copy(positions[:], m.positions)
	for v in 0 ..< n {
		if seam[v] {
			positions[v][axis] = 0
			twin[v] = u32(v)
		} else {
			append(seam, false)
			q := positions[v]
			q[axis] = -q[axis]
			twin[v] = u32(len(positions))
			append(&positions, q)
		}
	}
	faces := len(m.first) - 1
	first := make([dynamic]u32, 1, 2 * faces + 1)
	corners := make([dynamic]u32, 0, 2 * len(m.corners))
	for f in 0 ..< faces {
		if dropped_faces[f] {
			dropped += 1
			continue
		}
		append(&corners, ..m.corners[m.first[f]:m.first[f + 1]])
		append(&first, u32(len(corners)))
	}
	kept := len(first) - 1
	for f in 0 ..< kept {
		lo, hi := int(first[f]), int(first[f + 1])
		// Indexed, not sliced: the array grows under the loop.
		for k := hi - 1; k >= lo; k -= 1 do append(&corners, twin[corners[k]])
		append(&first, u32(len(corners)))
	}
	quadmesh.polygon_mesh_destroy(m)
	m^ = {positions[:], first[:], corners[:]}
	return
}

// Frees a computed retopology that will not become an object (a cancel, or the app
// ending while it ran).
retopo_result_destroy :: proc(r: ^Retopo_Result) {
	delete(r.reason)
	if r.built {
		geom.quad_mesh_destroy(&r.q)
		geom.uv_layout_destroy(&r.uv)
		geom.mesh_destroy(&r.mesh)
		sculpt.polys_destroy(&r.polys)
	}
	r^ = {}
}

// The polygons over the object's triangles once the build renumbered them: each corner
// through `old_to_new`, and triangle t's polygon that of the triangle `tri_from[t]` it was.
retopo_polys_renumber :: proc(p: ^sculpt.Polys, old_to_new, tri_from: []u32) {
	for &c in p.corners do c = old_to_new[c]
	was := make([]u32, len(p.tri_poly))
	defer delete(was)
	copy(was, p.tri_poly)
	for &f, t in p.tri_poly do f = was[tri_from[t]]
}

// Makes the object from a computed retopology of `obj`, next to it, and selects it; the
// result's parts become the object's. `start` is when the work began, for the mesh's build.
retopo_apply :: proc(app: ^App, obj: ^Object, r: ^Retopo_Result, start: time.Tick) -> (made, ok: bool) {
	res := r^
	r^ = {}
	defer delete(res.reason)
	old_to_new := make([]u32, len(res.mesh.positions))
	defer delete(old_to_new)
	tri_from: []u32
	if res.polys.first != nil do tri_from = make([]u32, len(res.mesh.indices) / 3)
	defer delete(tri_from)
	delete(res.q.positions)
	// Not in temp memory, which building frees.
	name := fmt.aprintf("%s retopo", object_label(obj))
	defer delete(name)
	t := obj.transform
	t.position = next_free_position(app)
	if !scene_add_mesh(app, res.mesh, name, obj.file, t, start, old_to_new, material = obj.material, tri_from = tri_from) {
		delete(res.q.quads)
		geom.uv_layout_destroy(&res.uv)
		sculpt.polys_destroy(&res.polys)
		return false, false
	}
	twin := selected_object(app)
	if res.polys.first != nil {
		// The base level keeps the polygons, so Wireframe draws their edges and Subdivide
		// cuts them as Catmull-Clark cuts quads.
		retopo_polys_renumber(&res.polys, old_to_new, tri_from)
		if !sculpt.levels_set_polys(&twin.levels, res.polys, {}, .Smooth) do log.errorf("quad remesh: the polygons did not fit the triangles cut from them, so %s keeps none", object_label(twin))
	}
	charts := 0
	if res.q.quads != nil {
		for &f in res.q.quads do for &v in f do v = old_to_new[v]
		sculpt.levels_set_quads(&twin.levels, res.q.quads)
		sculpt.levels_set_uvs(&twin.levels, res.uv)
		charts = res.uv.charts
	}
	app.ui.bake.source = obj.id
	// "Quad remeshed X: 1,180 quads (AutoRemesher), UVs in 12 charts, 226 ms", with the
	// other polygons and no UVs when some are not quads, and why the built-in engine ran
	// when it was not asked for.
	engine := QUAD_ENGINE_NAMES[res.engine]
	if res.reason != "" do engine = fmt.tprintf("built-in, as AutoRemesher said %s", res.reason)
	if res.mirrored do engine = fmt.tprintf("%s, mirrored", engine)
	if res.unmirrored != "" do engine = fmt.tprintf("%s, not mirrored since %s", engine, res.unmirrored)
	if res.closed > 0 do engine = fmt.tprintf("%s, closed first", engine)
	flags: Report_Flags
	if res.reason != "" || res.quads != res.faces do flags += {.Warning}
	faces := fmt.tprintf("%s quads", thousands(res.quads))
	if res.quads != res.faces do faces = fmt.tprintf("%s quads, %d triangles and %d larger faces, so no UVs", thousands(res.quads), res.triangles, res.ngons)
	uvs := fmt.tprintf(", UVs in %d charts", charts) if charts > 0 else ""
	report(app, Kit_Section.Retopo, flags, "Quad remeshed %s: %s (%s)%s, %.0f ms", object_label(obj), faces, engine, uvs, res.retopo_ms + res.uv_ms)
	if res.engine == .Own {
		how := res.how
		log.infof("quad remesh: built-in decimated to %d triangles, %d paired; %d vertices not put back; UVs fill %.0f%% in %.0f ms", how.decimated, how.paired, how.unprojected, 100 * res.uv.filled, res.uv_ms)
	}
	return true, true
}

// The object Bake maps... reads the detail from: the one chosen, else the one the
// quads came from, else none.
bake_source :: proc(app: ^App, low: ^Object) -> ^Object {
	src := object_by_id(app, app.ui.bake.source)
	return src if src != low else nil
}

// Bakes the bake source's detail onto the selected quad object and writes, into
// `folder`, NAME_normal.png (tangent space, OpenGL's green up), NAME_displacement.png
// (16-bit grey, 32768 for none), NAME_displacement.txt (the distance the full range
// stands for) and NAME.obj (the quads with their UVs), NAME being the object's.
bake_to_folder :: proc(app: ^App, folder: string) {
	low := selected_object(app)
	if low == nil || !sculpt.levels_has_uvs(&low.levels) {
		file_note(app, true, "Bake: select an object made by Quad Remesh first")
		return
	}
	src := bake_source(app, low)
	if src == nil {
		file_note(app, true, "Bake: choose the object to bake from")
		return
	}
	stroke_finish(app)
	object_hd_leave(app, low)
	object_hd_leave(app, src)
	start := time.tick_now()
	view, packed := object_shape(src, top = true)
	defer {
		delete(view.normals)
		geom.mesh_destroy(&packed)
	}
	bvh := geom.bvh_build_morton(view, geom.BVH_LEAF_SIZE, &app.pool)
	defer geom.bvh_destroy(&bvh)
	sculpt.levels_sync(&low.levels)
	quads := sculpt.levels_quad_mesh(&low.levels)
	edge: f32
	for f in quads.quads do for k in 0 ..< 4 do edge += linalg.length(quads.positions[f[(k + 1) % 4]] - quads.positions[f[k]])
	edge /= f32(max(4 * len(quads.quads), 1))
	size := int(app.ui.bake.size)
	set := &app.ui.bake
	kinds: bit_set[geom.Bake_Kind]
	if set.base_color do kinds += {.Base_Color}
	if set.orm do kinds += {.Orm}
	if set.id do kinds += {.Id}
	source := bake_source_of(app, src, view, &bvh)
	maps := geom.bake_maps(quads, low.levels.faces.uv, source, size, set.reach_edges * edge, kinds, &app.pool)
	defer geom.bake_maps_destroy(&maps)
	baked_ms := time.duration_milliseconds(time.tick_since(start))

	base, _ := strings.replace_all(object_label(low), " ", "_", context.temp_allocator)
	path :: proc(folder, base, suffix: string) -> string {
		joined, _ := filepath.join({folder, strings.concatenate({base, suffix}, context.temp_allocator)}, context.temp_allocator)
		return joined
	}
	normal_png := png_write.encode(maps.normal, size, size, false)
	defer delete(normal_png)
	// The bake set's maps, each with its file's suffix.
	Extra :: struct {
		pixels: []u8,
		suffix: string,
	}
	extras := [?]Extra{{maps.base_color, "_base_color.png"}, {maps.orm, "_orm.png"}, {maps.id, "_id.png"}}
	written := make([dynamic]string, context.temp_allocator)
	samples := geom.bake_displacement_samples(maps)
	defer delete(samples)
	disp_png := png_write.encode_gray16(samples, size, size)
	defer delete(disp_png)
	obj_text := make([dynamic]u8)
	defer delete(obj_text)
	geom.quad_mesh_write_obj(&obj_text, quads.positions, quads.quads, low.levels.faces.uv.uvs, low.file.scale, low.file.position)
	full := maps.max_displacement * low.file.scale
	note := fmt.tprintf("Displacement %s_displacement.png: 16-bit grey, 32768 is the surface of %s.obj, 0 and 65535 are %v units in and out along its normal (in the OBJ's units).\n", base, base, full)
	if !write_file_safely(app, path(folder, base, "_normal.png"), normal_png, "bake") do return
	if !write_file_safely(app, path(folder, base, "_displacement.png"), disp_png, "bake") do return
	if !write_file_safely(app, path(folder, base, "_displacement.txt"), transmute([]u8)note, "bake") do return
	if !write_file_safely(app, path(folder, base, ".obj"), obj_text[:], "bake") do return
	pngs: [len(extras)][]u8
	defer for p in pngs do delete(p)
	for e, k in extras {
		if e.pixels == nil do continue
		pngs[k] = png_write.encode(e.pixels, size, size, false)
		if !write_file_safely(app, path(folder, base, e.suffix), pngs[k], "bake") do return
		append(&written, e.suffix)
	}
	glb := make([dynamic]u8)
	defer delete(glb)
	bake_glb(&glb, low, quads, source, object_label(low), normal_png, pngs[0], pngs[1], set.occlusion_rays > 0)
	if !write_file_safely(app, path(folder, base, ".glb"), glb[:], "bake") do return
	append(&written, ".glb")
	// The maps stay on the object, shown through its UVs (textures.odin): the first bake of
	// a run turns the view on so the result shows at once. The ID map is a mask source, not
	// a look, so it stays a file.
	kept: Object_Textures
	for img, m in ([render.Texture_Map][]u8{.Base_Color = pngs[0], .Orm = pngs[1], .Normal = normal_png}) {
		if img == nil do continue
		kept.image[m] = make([]u8, len(img))
		copy(kept.image[m], img)
	}
	textures_replace(app, low, kept, "bake maps")
	if app.texture_view == .Off do app.texture_view = .Textured
	share := 100 * f64(maps.hit) / f64(max(maps.covered, 1))
	more := strings.join(written[:], ", ", context.temp_allocator)
	report(app, Kit_Section.Retopo, {.Warning} if share < 99 else {}, "Baked %s from %s at %d x %d in %.0f ms: %.1f%% of texels found the surface, displacement up to %.4g; %s_normal.png, _displacement.png%s%s and .obj written, and the maps shown on it (View > Textures)%s",
		object_label(low), object_label(src), size, size, baked_ms, share, full, base, ", " if more != "" else "", more,
		"; it has dynamic topology, so no paint or polygroups to bake" if object_dynamic(src) && kinds & {.Base_Color, .Id} != {} else "")
}

// The baked quad object `low` as a binary glTF, ready to look at in another program
// (quad_object_glb), with the maps just written (`base_color` and `orm` nil when not
// baked). Without a base colour map the material takes the source's own colour, and
// without an ORM map its roughness and metal; `occlusion` says whether the ORM map's red
// is baked occlusion.
bake_glb :: proc(out: ^[dynamic]u8, low: ^Object, quads: geom.Quad_Mesh, src: geom.Bake_Source, name: string, normal, base_color, orm: []u8, occlusion: bool) {
	own := src.surfaces[0] if len(src.surfaces) > 0 else geom.Bake_Surface{base = 0.6, roughness = 0.5}
	mat := geom.Export_Material {
		name      = fmt.tprintf("%s baked", name),
		base      = own.base,
		metallic  = own.metallic,
		roughness = own.roughness,
	}
	_, _ = quad_object_glb(out, low, quads, name, {.Base_Color = base_color, .Orm = orm, .Normal = normal}, mat, occlusion)
}

// Quad object `obj` (`quads`, its base level) as a binary glTF: its quads as triangles,
// split where the UVs are, with normals, UVs and the tangents the normal map was baked
// in, and material `mat` with `maps` (nil for none) embedded as its textures: a base
// colour map stands for the material's colour, and an ORM map for its roughness and metal
// and, with `occlusion`, its occlusion. A map that is neither PNG nor JPEG, the two glTF
// reads, goes as PNG. `morphs` are the base level's layers and `colors` its vertex colours
// (nil for none), carried onto the split vertices, and `lights` go beside the mesh.
// Returns how many vertices were
// written; false when the file would pass glTF's 4 GB.
quad_object_glb :: proc(out: ^[dynamic]u8, obj: ^Object, quads: geom.Quad_Mesh, name: string, maps: [render.Texture_Map][]u8, mat: geom.Export_Material, occlusion: bool, morphs: []geom.Morph_Target = nil, colors: [][3]u8 = nil, lights: []geom.Export_Light = nil) -> (vertices: int, ok: bool) {
	maps := maps
	for &img in maps {
		if img == nil || geom.image_mime(img) == "image/jpeg" || (len(img) >= 4 && string(img[:4]) == "\x89PNG") do continue
		pixels, w, h, failed := matcap_pixels(img, context.temp_allocator)
		img = png_write.encode(pixels, w, h, false, context.temp_allocator) if failed == "" else nil
	}
	uvs := obj.levels.faces.uv
	normals := geom.quad_mesh_normals(quads, context.temp_allocator)
	frame := geom.quad_mesh_tangents(quads, uvs, normals, context.temp_allocator)
	positions, split_normals, texcoords, indices := geom.quad_mesh_split_uvs(quads, uvs, normals, frame, context.temp_allocator)
	images := make([dynamic]geom.Export_Image, context.temp_allocator)
	mat := mat
	if img := maps[.Base_Color]; img != nil {
		append(&images, geom.Export_Image{"base colour", img})
		mat.textures[.Base_Color], mat.base = len(images), 1
	}
	if img := maps[.Orm]; img != nil {
		append(&images, geom.Export_Image{"occlusion, roughness, metal", img})
		mat.textures[.Orm], mat.metallic, mat.roughness = len(images), 1, 1
		if occlusion do mat.textures[.Occlusion] = len(images)
	}
	if img := maps[.Normal]; img != nil {
		append(&images, geom.Export_Image{"normal", img})
		mat.textures[.Normal] = len(images)
	}
	// A layer moves a vertex, and so every slot the split made of it.
	split := make([]geom.Morph_Target, len(morphs), context.temp_allocator)
	at := make([]i32, len(quads.positions), context.temp_allocator)
	for m, k in morphs {
		slice.fill(at, -1)
		for v, i in m.vertices do at[v] = i32(i)
		vertices := make([dynamic]u32, context.temp_allocator)
		deltas := make([dynamic]geom.Vec3, context.temp_allocator)
		for v, slot in frame.vertex {
			if at[v] < 0 do continue
			append(&vertices, u32(slot))
			append(&deltas, m.deltas[at[v]])
		}
		split[k] = {m.name, m.weight, vertices[:], deltas[:]}
	}
	split_colors: [][3]u8
	if colors != nil {
		split_colors = make([][3]u8, len(frame.vertex), context.temp_allocator)
		for v, slot in frame.vertex do split_colors[slot] = colors[v]
	}
	m := geom.Mesh_Export {
		name      = name,
		positions = positions,
		normals   = split_normals,
		indices   = indices,
		texcoords = texcoords,
		tangents  = frame.tangents,
		images    = images[:],
		material  = mat,
		morphs    = split,
		colors    = split_colors,
		scale     = obj.file.scale,
		offset    = obj.file.position,
		lights    = lights,
	}
	return len(positions), geom.mesh_write_glb(out, m)
}

// What a bake reads from object `src`, whose top level (or packed copy, when dynamic) is
// `view` with `bvh` over it: its paint, polygroups and materials (its own and its
// groups'), and the occlusion settings. In temporary memory, but for the views of the
// level's arrays.
bake_source_of :: proc(app: ^App, src: ^Object, view: geom.Mesh, bvh: ^geom.Bvh) -> (s: geom.Bake_Source) {
	s.mesh, s.bvh = view, bvh
	set := app.ui.bake
	if set.occlusion_rays > 0 {
		box := geom.AABB_EMPTY
		for p in view.positions do box = {linalg.min(box.lo, p), linalg.max(box.hi, p)}
		s.occlusion_rays = int(set.occlusion_rays)
		s.occlusion_reach = set.occlusion_reach * linalg.length(box.hi - box.lo) if len(view.positions) > 0 else 0
	}
	which, materials := group_slots(app, src)
	s.surfaces = make([]geom.Bake_Surface, len(materials), context.temp_allocator)
	for m, k in materials do s.surfaces[k] = {m.base, m.metallic, m.roughness}
	// A dynamic object's packed copy has neither its paint nor its groups.
	if object_dynamic(src) || src.voxel != nil do return
	sculpt.levels_paint_to_top(&src.levels)
	top := &src.levels.levels[len(src.levels.levels) - 1].sculptor
	s.paint = top.color
	s.groups = top.groups.tris
	if s.groups != nil && len(src.group_materials) > 0 {
		s.slots = make([]u8, len(s.groups), context.temp_allocator)
		for g, t in s.groups do s.slots[t] = which[g]
	}
	return
}

// The interface's UVs and baking section: Quad Remesh itself is Shape > Rebuild's Quads.
kit_retopo_section :: proc(app: ^App) {
	ctx := &app.kit.ctx
	obj := selected_object(app)
	kit_last_result(app, .Retopo)
	if obj == nil || !sculpt.levels_has_uvs(&obj.levels) {
		ui.paragraph(ctx, "Bakes onto an object with UVs: make one with Shape > Rebuild > Quads, then select it here.")
		return
	}
	src := bake_source(app, obj)
	names := make([dynamic]string, context.temp_allocator)
	ids := make([dynamic]int, context.temp_allocator)
	append(&names, "Choose the source")
	append(&ids, 0)
	chosen := 0
	for other in app.scene.objects {
		if other == obj do continue
		if other == src do chosen = len(names)
		append(&names, fmt.tprintf("Bake from %s##%d", object_label(other), other.id))
		append(&ids, other.id)
	}
	if picked := ui.select(ctx, "bake from", names[:], chosen); picked >= 0 do app.ui.bake.source = ids[picked]
	bake, uvs := kit_button_pair(ctx, "Bake maps...", "New UVs")
	if bake do file_dialog(app, .Bake)
	if uvs do app.ui.scene_command = {kind = .Layout_Uvs}
	ui.paragraph(ctx, "Bakes the source's detail (its top level) into normal and displacement maps on this object's UVs, with its colour and the other maps chosen under More options, and writes them with the quads as OBJ into a folder.")
	if kit_more(app, .Retopo) {
		sizes: [len(BAKE_SIZES)]string
		size := -1
		for s, i in BAKE_SIZES {
			sizes[i] = fmt.tprintf("%d", s)
			if s == app.ui.bake.size do size = i
		}
		if picked := ui.tabs(ctx, "bake size", sizes[:], size); picked >= 0 do app.ui.bake.size = BAKE_SIZES[picked]
		_ = ui.slider(ctx, "Reach", &app.ui.bake.reach_edges, 0.5, 10, .Linear, fmt.tprintf("%.1f edges", app.ui.bake.reach_edges))
		set := &app.ui.bake
		_ = ui.switch_row(ctx, "Base colour", &set.base_color)
		_ = ui.switch_row(ctx, "Occlusion, roughness, metal", &set.orm)
		_ = ui.switch_row(ctx, "Polygroup colours", &set.id)
		if set.orm {
			rays := f32(set.occlusion_rays)
			if ui.slider(ctx, "Occlusion rays", &rays, 0, BAKE_OCCLUSION_RAYS_MAX, .Linear, fmt.tprintf("%d", set.occlusion_rays) if set.occlusion_rays > 0 else "Off") do set.occlusion_rays = i32(rays + 0.5)
			if set.occlusion_rays > 0 do _ = ui.slider(ctx, "Occlusion reach", &set.occlusion_reach, 0.01, 1, .Logarithmic, fmt.tprintf("%.0f%% of its size", 100 * set.occlusion_reach))
		}
		ui.paragraph(ctx, "The maps' size in texels, and Reach: how far each texel looks either way. Base colour is the polypaint over the materials; occlusion, roughness and metal go in one map's red, green and blue, as glTF reads them; polygroup colours make an ID map. More occlusion rays are smoother and slower.")
		kit_more_end(app)
	}
}
