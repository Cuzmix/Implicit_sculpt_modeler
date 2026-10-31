package retopo

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:time"

import "../geom"
import "../jobs"
import "../quadmesh"
import "../sculpt"

// Package retopo is Quad Remesh's work with no scene, interface or GPU: about so many quads
// on a mesh by AutoRemesher (src/quadmesh) or the own engine (geom.mesh_retopo), with
// Close first, symmetry and UVs, so a long job runs it on its own thread and the
// benchmark and tests run it alone. The app makes the object from the result.

// Which quad remesher Quad Remesh (Rebuild's Quads) runs: AutoRemesher (src/quadmesh),
// whose edge flow follows the surface's curvature as ZBrush's ZRemesher does, or the own
// edge-pairing retopology (geom.mesh_retopo), quicker and plainer. AutoRemesher is the
// default; where it is not built, or refuses the mesh, the own one runs in its place and
// the report says why.
Engine :: enum u8 {
	Auto,
	Own,
}

ENGINE_NAMES := [Engine]string {
	.Auto = "AutoRemesher",
	.Own  = "Built-in",
}

// What a Quad Remesh runs with besides the count: carried in the scene command, so the
// long job's thread reads no interface state, and put back by Adjust last.
Options :: struct {
	engine:      Engine,
	adaptivity:  f32, // 0 quads of one size, 1 smaller ones where the surface bends (AutoRemesher; fewer quads than asked)
	// Keep symmetry: the planes the result is its own mirror image across (the brush's
	// symmetry, through the centre its dabs mirror about), none for a whole remesh. The
	// part on the + side of every plane is remeshed alone and mirrored, so the halves
	// match quad for quad along the seam, with either engine.
	mirror:      geom.Remesh_Mirror,
	close_first: bool, // an open or unsound mesh is voxel remeshed first, whichever engine runs
}

// UV padding around each chart, in texels of the largest map size, so even a 4096 map
// keeps charts apart when filtered.
UV_PADDING :: f32(8.0 / 4096)

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

// What Quad Remesh computes before it makes the object: the triangles drawn and sculpted,
// the polygons they came from and, when every polygon is a quad, the quads with their UVs.
Result :: struct {
	q:         geom.Quad_Mesh, // every polygon a quad: the quads, over positions `mesh` copied; nil otherwise
	how:       geom.Retopo_Report, // the own engine's account
	uv:        geom.Uv_Layout, // with `q`
	mesh:      geom.Mesh,
	polys:     sculpt.Polys, // AutoRemesher: the polygons as the base level keeps them, over `mesh`
	engine:    Engine, // the engine that made it: Auto may have given way to Own
	faces:     int, // AutoRemesher's polygons...
	quads:     int, // ...of which quads,
	triangles: int, // triangles
	ngons:     int, // and five corners or more
	capped:    int, // AutoRemesher: triangles the input was decimated to first, 0 for none
	closed:    int, // Close first: vertices of the voxel remesh that stood in for the input, 0 for none
	mirrored:  bool, // one part remeshed and mirrored, as the symmetry asked...
	mirror:    geom.Remesh_Mirror, // ...across these planes
	unmirrored: string, // symmetry asked but not kept: why (a literal, not owned)
	reason:    string, // owned: why AutoRemesher was not used, "" when it was
	built:     bool,
	retopo_ms: f64,
	uv_ms:     f64,
}

// The quads of about `quads` on `view` (with normals) by the engine and options, their
// UVs and triangles; touches no object or interface, so a long job runs it on its own
// thread with its own pool, and with `progress` it stops after a cancel, built false with
// nothing to free. AutoRemesher gives way to the own engine when it is not built or
// refuses the mesh, and `reason` then says why; the own engine knows no adaptivity, but
// Close first and symmetry serve it too.
compute :: proc(view: geom.Mesh, quads: int, options: Options, pool: ^jobs.Pool, progress: ^jobs.Progress = nil) -> (r: Result) {
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
	// Symmetry: the part on the + side of every plane, open along its cut, is remeshed
	// with the cut as a seam that stays on the planes, and mirrored.
	q: geom.Quad_Mesh
	how: geom.Retopo_Report
	built: bool
	if options.mirror.axes != {} {
		q, how, built, r.unmirrored = own_mirrored(input, quads, options.mirror, pool, progress, {from, 0.9})
		r.mirrored = built && r.unmirrored == ""
		if r.mirrored do r.mirror = options.mirror
	}
	if !r.mirrored && !jobs.progress_cancelled(progress) {
		if built do geom.quad_mesh_destroy(&q)
		bvh := geom.bvh_build_morton(input, geom.BVH_LEAF_SIZE, pool)
		defer geom.bvh_destroy(&bvh)
		q, how, built = geom.mesh_retopo(input, &bvh, quads, pool, progress = progress, share = {from, 0.9})
	}
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
	jobs.progress_set(progress, 0, 1, 1)
	return
}

// The own engine under symmetry: the part of `m` on the + side of every plane, cut open,
// remeshed to its share of `quads` with the cut as a seam, and mirrored. Not mirrored,
// with why, when a plane misses the mesh or the mirrored halves do not close along the
// seam; built false only when there was too little to remesh or after a cancel.
@(private = "file")
own_mirrored :: proc(m: geom.Mesh, quads: int, mirror: geom.Remesh_Mirror, pool: ^jobs.Pool, progress: ^jobs.Progress, share: [2]f32) -> (q: geom.Quad_Mesh, how: geom.Retopo_Report, built: bool, unmirrored: string) {
	half, cut := geom.mirror_cut(m, mirror, false, pool)
	defer geom.mesh_destroy(&half)
	if !cut do return {}, {}, false, "the mesh does not cross the plane"
	snap := mirror_snap(m)
	planes := geom.mirror_seam(half, mirror, snap)
	defer delete(planes)
	seam := make([]bool, len(planes))
	defer delete(seam)
	for p, v in planes do seam[v] = p != 0
	resize(&half.normals, len(half.positions))
	geom.mesh_recompute_normals(&half)
	bvh := geom.bvh_build_morton(half, geom.BVH_LEAF_SIZE, pool)
	defer geom.bvh_destroy(&bvh)
	parts := 0
	for a in mirror.axes do if a do parts += 1
	q, how, built = geom.mesh_retopo(half, &bvh, max(quads >> uint(parts), 8), pool, progress = progress, share = share, seam = seam)
	if !built do return
	// The seam again on the quads: the edges' middles on it lie on the plane too, and the
	// relaxation never moved an open edge's vertices.
	tris := geom.quad_mesh_triangulate(q)
	defer geom.mesh_destroy(&tris)
	quad_planes := geom.mirror_seam(tris, mirror, snap)
	defer delete(quad_planes)
	positions := make([dynamic]geom.Vec3, len(q.positions))
	copy(positions[:], q.positions)
	first := make([dynamic]u32, len(q.quads) + 1)
	defer delete(first)
	corners := make([dynamic]u32, 4 * len(q.quads))
	defer delete(corners)
	for &f, k in q.quads {
		first[k + 1] = u32(4 * k + 4)
		copy(corners[4 * k:][:4], f[:])
	}
	at := make([dynamic]u8, len(quad_planes))
	defer delete(at)
	copy(at[:], quad_planes)
	geom.mirror_polygons(&positions, &first, &corners, &at, mirror)
	mirrored := geom.Quad_Mesh{positions = positions[:], quads = make([][4]u32, len(corners) / 4)}
	for &f, k in mirrored.quads do copy(f[:], corners[4 * k:][:4])
	check := geom.mesh_check(geom.quad_mesh_triangulate(mirrored, context.temp_allocator))
	if check.non_manifold_edges > 0 || check.inconsistent_edges > 0 || len(corners) != 4 * (len(first) - 1) {
		log.warnf("quad remesh: the built-in engine's mirrored halves left %d non-manifold and %d flipped edges, so the whole mesh is remeshed instead", check.non_manifold_edges, check.inconsistent_edges)
		geom.quad_mesh_destroy(&mirrored)
		geom.quad_mesh_destroy(&q)
		return {}, {}, false, "the seam did not close"
	}
	geom.quad_mesh_destroy(&q)
	return mirrored, how, true, ""
}

// Within this share of a mesh's size of a symmetry plane, a vertex of its cut lies on it:
// mesh_slice puts what is within a tenth of that onto the plane.
@(private = "file")
MIRROR_SNAP :: f32(1e-4)

@(private = "file")
mirror_snap :: proc(m: geom.Mesh) -> f32 {
	lo, hi := m.positions[0], m.positions[0]
	for p in m.positions do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	extent := hi - lo
	return max(extent.x, extent.y, extent.z) * MIRROR_SNAP
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

// AutoRemesher's half of compute: refuses what it cannot take (or runs forever
// on) before it starts, decimates past the cap, remeshes, and turns the polygons into the
// triangles the object is built of, with the quads and UVs when every polygon is a quad.
@(private = "file")
quad_remesh_compute :: proc(view: geom.Mesh, quads: int, options: Options, pool: ^jobs.Pool, progress: ^jobs.Progress) -> (r: Result, outcome: Quad_Outcome) {
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
	// Symmetry: the part on the + side of every plane alone goes in and comes back
	// mirrored. It goes in closed, its cut capped flat on each plane, since AutoRemesher
	// fills a small hole of its own accord and smooths a larger one's rim off the plane;
	// the caps' polygons lie on the planes and are dropped after. The count asked for
	// covers the caps too, and the rim is kept as a sharp edge so the quads line up with
	// the seam. A plane the mesh does not cross leaves it whole.
	half: geom.Mesh
	defer geom.mesh_destroy(&half)
	mirror := options.mirror
	snap: f32
	asked := quads
	if mirror.axes != {} {
		ok: bool
		half, ok = geom.mirror_cut(input, mirror, true, pool)
		if ok {
			extent := c.bounds.hi - c.bounds.lo
			snap = max(extent.x, extent.y, extent.z) * QUAD_SEAM_SNAP
			total, cap := quad_cap_share(half, mirror, snap)
			parts := 0
			for a in mirror.axes do if a do parts += 1
			asked = int(f64(quads >> uint(parts)) * total / max(total - cap, total * 0.01))
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
	planes: [dynamic]u8
	defer delete(planes)
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
			cap, planes = quad_seam_classify(out, half, &bvh, mirror, snap)
			geom.bvh_destroy(&bvh)
			dropped := polygon_mesh_mirror(&out, mirror, cap, &planes)
			delete(cap)
			resize(&seam, len(planes))
			for p, v in planes do seam[v] = p != 0
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
		delete(planes)
		planes = nil
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
	if r.mirrored do r.mirror = mirror
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

// The area of `m` and of its triangles lying on one of the planes of `mirror` (within
// `snap`): a capped half's caps.
@(private = "file")
quad_cap_share :: proc(m: geom.Mesh, mirror: geom.Remesh_Mirror, snap: f32) -> (total, cap: f64) {
	for k := 0; k < len(m.indices); k += 3 {
		a, b, c := m.positions[m.indices[k]], m.positions[m.indices[k + 1]], m.positions[m.indices[k + 2]]
		area := f64(linalg.length(linalg.cross(b - a, c - a))) / 2
		total += area
		if flat_on(mirror, snap, a, b, c) != 0 do cap += area
	}
	return
}

// The planes of `mirror` (a bit each, by axis) that the triangle a b c lies on, within `snap`.
@(private = "file")
flat_on :: proc(mirror: geom.Remesh_Mirror, snap: f32, a, b, c: geom.Vec3) -> (planes: u8) {
	for x in 0 ..< 3 {
		o := mirror.center[x]
		if mirror.axes[x] && abs(a[x] - o) <= snap && abs(b[x] - o) <= snap && abs(c[x] - o) <= snap do planes |= 1 << u8(x)
	}
	return
}

// Turns every polygon round, so the surface faces the other way.
@(private = "file")
polygon_mesh_flip :: proc(m: ^quadmesh.Polygon_Mesh) {
	for f in 0 ..< len(m.first) - 1 do slice.reverse(m.corners[m.first[f]:m.first[f + 1]])
}

// Which of the remeshed half's polygons are its flat caps, to drop, and on which planes
// the vertices of the seam then lie (a bit each, by axis; 0 off the seam): a polygon is
// cap when the nearest point of the capped half `half` (with `bvh` over it) to its middle
// lies on a cap triangle (one with its three corners on a plane), and a seam vertex is one
// that a kept polygon and a dropped one share, on the planes of the caps it touches. The
// polygons' own distance to a plane does not tell: AutoRemesher's quads straddle the rim,
// a corner or two smoothed onto the side, so a cap polygon can have a corner off the plane
// and a side polygon one on it. The kept polygons' border is then exactly the seam edges,
// which the mirror closes.
@(private = "file")
quad_seam_classify :: proc(m: quadmesh.Polygon_Mesh, half: geom.Mesh, bvh: ^geom.Bvh, mirror: geom.Remesh_Mirror, snap: f32, allocator := context.allocator) -> (dropped: []bool, planes: [dynamic]u8) {
	on_cap := make([]u8, len(half.indices) / 3, context.temp_allocator)
	defer delete(on_cap, context.temp_allocator)
	for &flat, t in on_cap {
		flat = flat_on(mirror, snap, half.positions[half.indices[3 * t]], half.positions[half.indices[3 * t + 1]], half.positions[half.indices[3 * t + 2]])
	}
	faces := len(m.first) - 1
	dropped = make([]bool, faces, allocator)
	cap_of := make([]u8, faces, context.temp_allocator)
	defer delete(cap_of, context.temp_allocator)
	planes = make([dynamic]u8, len(m.positions), allocator)
	in_kept := make([]bool, len(m.positions), context.temp_allocator)
	defer delete(in_kept, context.temp_allocator)
	touches := make([]u8, len(m.positions), context.temp_allocator)
	defer delete(touches, context.temp_allocator)
	hint := geom.BVH_NONE
	for f in 0 ..< faces {
		corners := m.corners[m.first[f]:m.first[f + 1]]
		middle: geom.Vec3
		for c in corners do middle += m.positions[c]
		middle /= f32(len(corners))
		if tri, _, _, ok := geom.bvh_closest(bvh^, half, middle, max(f32), hint); ok {
			cap_of[f] = on_cap[tri]
			dropped[f] = cap_of[f] != 0
			hint = tri
		}
	}
	draw_seam :: proc(m: quadmesh.Polygon_Mesh, dropped: []bool, cap_of: []u8, in_kept: []bool, touches, planes: []u8) {
		for v in 0 ..< len(m.positions) do in_kept[v], touches[v] = false, 0
		for f in 0 ..< len(m.first) - 1 do for c in m.corners[m.first[f]:m.first[f + 1]] {
			if dropped[f] do touches[c] |= cap_of[f]
			else do in_kept[c] = true
		}
		for v in 0 ..< len(m.positions) do planes[v] = touches[v] if in_kept[v] else 0
	}
	draw_seam(m, dropped, cap_of, in_kept, touches, planes[:])
	// A chord: an edge between two kept polygons whose ends are both seam. Its mirror image
	// would make four faces on it, so the more cap-like of the two polygons goes too (on
	// the planes its seam corners touch), and the seam is drawn again, until no chord is
	// left (a round or two).
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
			if at[0] < 0 || at[1] < 0 || planes[e[0]] & planes[e[1]] == 0 do continue
			more :: proc(m: quadmesh.Polygon_Mesh, planes: []u8, f: i32) -> int {
				n := 0
				for c in m.corners[m.first[f]:m.first[f + 1]] do if planes[c] != 0 do n += 1
				return n
			}
			a, b := more(m, planes[:], at[0]), more(m, planes[:], at[1])
			f := at[0] if a > b || (a == b && at[0] < at[1]) else at[1]
			if !dropped[f] {
				dropped[f] = true
				cap_of[f] = planes[e[0]] & planes[e[1]]
				went += 1
			}
		}
		if went == 0 do break
		draw_seam(m, dropped, cap_of, in_kept, touches, planes[:])
	}
	return
}

// Mirrors the polygons across each plane of `mirror` (geom.mirror_polygons), the
// `dropped_faces` (the caps over the cut) left out: a vertex on a plane by `planes` is put
// on it and shared by both sides, every other vertex gets a mirrored copy, and every kept
// polygon a reversed copy over the copies, so the result is closed where the kept
// polygons' border is the seam. Returns how many polygons went; `planes` follows the
// vertices, which are compacted to those still used.
@(private = "file")
polygon_mesh_mirror :: proc(m: ^quadmesh.Polygon_Mesh, mirror: geom.Remesh_Mirror, dropped_faces: []bool, planes: ^[dynamic]u8) -> (dropped: int) {
	positions := make([dynamic]geom.Vec3, len(m.positions))
	copy(positions[:], m.positions)
	faces := len(m.first) - 1
	first := make([dynamic]u32, 1, faces + 1)
	corners := make([dynamic]u32, 0, len(m.corners))
	for f in 0 ..< faces {
		if dropped_faces[f] {
			dropped += 1
			continue
		}
		append(&corners, ..m.corners[m.first[f]:m.first[f + 1]])
		append(&first, u32(len(corners)))
	}
	dropped += geom.mirror_polygons(&positions, &first, &corners, planes, mirror)
	quadmesh.polygon_mesh_destroy(m)
	m^ = {positions[:], first[:], corners[:]}
	return
}

// Frees a computed retopology that will not become an object (a cancel, or the app
// ending while it ran).
result_destroy :: proc(r: ^Result) {
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
polys_renumber :: proc(p: ^sculpt.Polys, old_to_new, tri_from: []u32) {
	for &c in p.corners do c = old_to_new[c]
	was := make([]u32, len(p.tri_poly))
	defer delete(was)
	copy(was, p.tri_poly)
	for &f, t in p.tri_poly do f = was[tri_from[t]]
}

