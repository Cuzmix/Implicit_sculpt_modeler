package geom

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../jobs"

// Voxel remesh, like ZBrush's DynaMesh: rebuilds a mesh as an even surface of about a
// chosen number of vertices that keeps its shape down to the voxel size, whatever its
// triangles looked like before. Overlapping and self-intersecting parts merge into
// one surface, and anything thinner than a voxel goes.
//
//  1. Inside or outside, on a lattice of spacing h: a ray along x through every
//     lattice row collects where it crosses the mesh and which way, and a lattice
//     point is inside where the winding number is positive. The crossings are found
//     with exact fixed-point edge tests and a top-left rule, so a ray through a shared
//     edge or vertex counts it once and closed meshes give exact answers.
//  2. Rays along y and z the same way: where the surface crosses the lattice's y and
//     z edges.
//  3. Marching cubes over the cells whose corners differ, with one rule on ambiguous
//     faces (the surface keeps the face's inside corners apart), which makes the result
//     closed and manifold: every edge between exactly two triangles.
//  4. A few rounds of relaxation along the surface even out the triangles.
//
// Rays, crossings and cells are only ever stored where the surface is, so memory
// grows with the surface's area, not the lattice's volume.

REMESH_MAX_LATTICE :: 4096 // lattice points along any axis (DynaMesh's top resolution)

@(private = "file")
EDGE_MARGIN :: 0.05 // vertices stay this far (in lattice steps) from lattice points
@(private = "file")
RELAX_RATE :: 0.5

// Relax rounds after marching: Smooth's default and the most it offers (past eight the
// triangles no longer change much and the shape starts to shrink at sharp turns).
REMESH_SMOOTH_DEFAULT :: 3
REMESH_SMOOTH_MAX :: 8

// What a remesh does beyond its density, as ZBrush's DynaMesh offers beside its
// resolution: Smooth is the relax rounds; Keep detail projects the result back onto the
// surface it came from within one cell, as DynaMesh's Project does, and tells the caller
// which old triangle each vertex landed on, for the polypaint and polygroups to follow;
// `groups`, a group per triangle of the input, remeshes each group as a closed piece of
// its own (DynaMesh's Groups), nil for the whole as one.
Remesh_Options :: struct {
	smooth:      int,
	keep_detail: bool,
	groups:      []u16,
}

REMESH_OPTIONS_DEFAULT :: Remesh_Options{smooth = REMESH_SMOOTH_DEFAULT}

// What a remesh did that its caller reports: the holes capped before the rays, the group
// pieces made and those that gave nothing (thinner than a cell), each output triangle's
// group (with `groups` asked, else nil) and each output vertex's old triangle (with Keep
// detail, else nil; max(u32) where the projection found nothing within a cell). The two
// slices are the caller's to free (remesh_report_destroy).
Remesh_Report :: struct {
	holes_closed: int,
	turned:       bool, // the mesh was inside out (its volume negative) and was turned outward first
	pieces:       int,
	dropped:      int,
	groups:       []u16,
	source_tris:  []u32,
}

remesh_report_destroy :: proc(r: ^Remesh_Report, allocator := context.allocator) {
	delete(r.groups, allocator)
	delete(r.source_tris, allocator)
	r^ = {}
}

// Lattice spacing for a remesh of about `target` vertices: a surface of area A crosses
// about 1.5 A / h² lattice edges (the mean of |nx| + |ny| + |nz| over all directions
// is 1.5), and each crossing becomes a vertex.
remesh_spacing :: proc(m: Mesh, target: int, pool: ^jobs.Pool = nil) -> f32 {
	area, _ := mesh_area_bounds(m, pool)
	return remesh_spacing_of(area, target)
}

@(private = "file")
remesh_spacing_of :: proc(area: f64, target: int) -> f32 {
	return f32(math.sqrt(1.5 * area / f64(max(target, 1))))
}

// Remeshes `m` to about `target` vertices (fewer when that would need more than
// REMESH_MAX_LATTICE lattice points along an axis). The result has normals. Returns
// false for an empty mesh or one without volume.
remesh_voxel :: proc(m: Mesh, target: int, pool: ^jobs.Pool = nil, allocator := context.allocator) -> (out: Mesh, ok: bool) {
	if len(m.indices) < 3 do return {}, false
	area, bounds := mesh_area_bounds(m, pool)
	return remesh_voxel_measured(m, area, bounds, target, pool, allocator)
}

// remesh_voxel with the area and box mesh_area_bounds gave for `m` (or for the same
// triangles in another layout), so that a caller that measured them for the density
// preview remeshes on exactly the lattice the preview showed. With `progress` (a job on
// a thread of its own) it says how far it has come between its stages, over the `share`
// of the whole that it is, and stops at the next one after a cancel, returning not ok with
// nothing to free.
remesh_voxel_measured :: proc(m: Mesh, area: f64, bounds: Aabb, target: int, pool: ^jobs.Pool = nil, allocator := context.allocator, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}, options := REMESH_OPTIONS_DEFAULT, report: ^Remesh_Report = nil) -> (out: Mesh, ok: bool) {
	if len(m.indices) < 3 do return {}, false
	h, _ := remesh_lattice(area, bounds, target) or_return
	own: Remesh_Report
	r := report if report != nil else &own
	r^ = {}
	smooth := clamp(options.smooth, 0, REMESH_SMOOTH_MAX)
	// The projection back onto the old surface takes the last tenth of the share.
	rays_share := share
	if options.keep_detail do rays_share[1] = share[0] + 0.9 * (share[1] - share[0])
	// A mesh inside out as a whole (an import wound the other way) has nothing inside by
	// its winding: it is turned outward first. Shells inside out among others are left to
	// Fix mesh, which turns them one by one.
	input := m
	if mesh_signed_volume(m, pool) < 0 {
		input.indices = make([dynamic]u32, len(m.indices), runtime.heap_allocator())
		for i := 0; i < len(m.indices); i += 3 {
			input.indices[i], input.indices[i + 1], input.indices[i + 2] = m.indices[i], m.indices[i + 2], m.indices[i + 1]
		}
		r.turned = true
	}
	defer if r.turned do delete(input.indices)
	if options.groups != nil {
		out = remesh_groups(input, options.groups, h, bounds, smooth, pool, allocator, progress, rays_share, r) or_return
	} else {
		out = remesh_closed_first(input, h, bounds, smooth, pool, allocator, progress, rays_share, r) or_return
	}
	if options.keep_detail {
		if progress != nil && jobs.progress_cancelled(progress) {
			mesh_destroy(&out)
			remesh_report_destroy(r, allocator)
			return {}, false
		}
		bvh := bvh_build_morton(m, pool = pool)
		defer bvh_destroy(&bvh)
		next := make([]Vec3, len(out.positions), runtime.heap_allocator())
		defer delete(next, runtime.heap_allocator())
		r.source_tris = make([]u32, len(out.positions), allocator)
		_ = project_along_normals(out.positions[:], out.normals[:], m, &bvh, h, pool, next, r.source_tris)
		copy(out.positions[:], next)
		mesh_recompute_normals(&out)
		jobs.progress_set(progress, share[0], share[1], 1)
	}
	return out, true
}

// The volume `m` encloses by its winding, negative for a mesh inside out: each
// triangle's signed tetrahedron with the origin, summed in fixed ranges added in order,
// so the pool changes nothing.
mesh_signed_volume :: proc(m: Mesh, pool: ^jobs.Pool = nil) -> f64 {
	Volume :: struct {
		m:    Mesh,
		sums: []f64,
	}
	tcount := len(m.indices) / 3
	ranges := (tcount + RANGE_GRAIN - 1) / RANGE_GRAIN
	job := Volume{m, make([]f64, max(ranges, 1), runtime.heap_allocator())}
	defer delete(job.sums, runtime.heap_allocator())
	jobs.parallel_ranges(pool, tcount, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Volume)data
		sum: f64
		for t in lo ..< hi {
			a, b, c := job.m.positions[job.m.indices[3 * t]], job.m.positions[job.m.indices[3 * t + 1]], job.m.positions[job.m.indices[3 * t + 2]]
			sum += f64(linalg.dot(a, linalg.cross(b, c)))
		}
		job.sums[lo / RANGE_GRAIN] = sum
	}, RANGE_GRAIN)
	total: f64
	for s in job.sums do total += s
	return total / 6
}

// Whether the directed edges of `m` pair off, each edge run as often one way as the
// other: a closed surface (manifold or not; a doubled triangle pairs too) in one pass
// with no memory, which is what tells a remesh to cap holes first. A mixing hash of each
// edge is added one way and taken off the other, wrapping, in fixed ranges added in order,
// so the sum is zero when they pair off and otherwise not, short of a 2^-64 collision,
// which would only cost the uncapped remesh an open mesh got before.
mesh_edges_paired :: proc(m: Mesh, pool: ^jobs.Pool = nil) -> bool {
	Pair :: struct {
		m:    Mesh,
		sums: []u64,
	}
	tcount := len(m.indices) / 3
	ranges := (tcount + RANGE_GRAIN - 1) / RANGE_GRAIN
	job := Pair{m, make([]u64, max(ranges, 1), runtime.heap_allocator())}
	defer delete(job.sums, runtime.heap_allocator())
	jobs.parallel_ranges(pool, tcount, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Pair)data
		mix :: #force_inline proc(a, b: u32) -> u64 {
			// splitmix64's finaliser over the ordered pair.
			x := u64(a) << 32 | u64(b)
			x = (x ~ (x >> 30)) * 0xbf58476d1ce4e5b9
			x = (x ~ (x >> 27)) * 0x94d049bb133111eb
			return x ~ (x >> 31)
		}
		sum: u64
		idx := job.m.indices[:]
		for t in lo ..< hi {
			a, b, c := idx[3 * t], idx[3 * t + 1], idx[3 * t + 2]
			sum += mix(a, b) + mix(b, c) + mix(c, a)
			sum -= mix(b, a) + mix(c, b) + mix(a, c)
		}
		job.sums[lo / RANGE_GRAIN] = sum
	}, RANGE_GRAIN)
	total: u64
	for s in job.sums do total += s
	return total == 0
}

// The remesh of `m` on the lattice, its holes capped first when it has any: a ray's
// winding behind a sheet it crosses once never comes back, so an open part would be
// filled or dropped by the luck of which way it faces and left open at the lattice's
// edge; capped, a bowl becomes a solid whichever way it opens, as DynaMesh makes it.
@(private = "file")
remesh_closed_first :: proc(m: Mesh, h: f32, bounds: Aabb, smooth: int, pool: ^jobs.Pool, allocator: runtime.Allocator, progress: ^jobs.Progress, share: [2]f32, r: ^Remesh_Report) -> (out: Mesh, ok: bool) {
	if mesh_edges_paired(m, pool) do return remesh_run(m, h, bounds, len(m.indices) / 3, .Merge, pool, allocator, progress, share, smooth)
	heap := runtime.heap_allocator()
	capped, from, closed, did := mesh_close_holes(m, false, pool, heap)
	if !did do return remesh_run(m, h, bounds, len(m.indices) / 3, .Merge, pool, allocator, progress, share, smooth)
	defer mesh_destroy(&capped)
	defer repair_map_destroy(&from, heap)
	// A cap's vertices are raised to a membrane over the border's heights, which can
	// leave the box the lattice was placed from; the lattice needs every vertex inside
	// it (a step and a half from its outer points), so they are held within the box.
	for &p in capped.positions do for a in 0 ..< 3 do p[a] = clamp(p[a], bounds.lo[a], bounds.hi[a])
	r.holes_closed += closed.closed
	return remesh_run(capped, h, bounds, len(capped.indices) / 3, .Merge, pool, allocator, progress, share, smooth)
}

// Each group of `m` remeshed on the same lattice as a closed piece of its own, then all
// in one mesh with r.groups saying each triangle's group. Groups are taken in ascending
// order of their number, so the pieces' order, and the result, follow from the mesh alone.
@(private = "file")
remesh_groups :: proc(m: Mesh, groups: []u16, h: f32, bounds: Aabb, smooth: int, pool: ^jobs.Pool, allocator: runtime.Allocator, progress: ^jobs.Progress, share: [2]f32, r: ^Remesh_Report) -> (out: Mesh, ok: bool) {
	heap := runtime.heap_allocator()
	tcount := len(m.indices) / 3
	assert(len(groups) == tcount)
	// The groups present, numbered densely in ascending order.
	seen := make([]bool, int(max(u16)) + 1, heap)
	defer delete(seen, heap)
	for g in groups do seen[g] = true
	dense := make([]u32, int(max(u16)) + 1, heap)
	defer delete(dense, heap)
	ids := make([dynamic]u16, 0, 16, heap)
	defer delete(ids)
	for present, g in seen do if present {
		dense[g] = u32(len(ids))
		append(&ids, u16(g))
	}
	part := make([]u32, tcount, heap)
	defer delete(part, heap)
	for g, t in groups do part[t] = dense[g]
	pieces := mesh_split(m, part, len(ids), heap)
	defer split_parts_destroy(pieces, heap)
	made := make([dynamic]Mesh, 0, len(pieces), heap)
	defer {
		for &p in made do mesh_destroy(&p)
		delete(made)
	}
	made_ids := make([dynamic]u16, 0, len(pieces), heap)
	defer delete(made_ids)
	span := (share[1] - share[0]) / f32(max(len(pieces), 1))
	for &piece, i in pieces {
		r.pieces += 1
		piece_share := [2]f32{share[0] + f32(i) * span, share[0] + f32(i + 1) * span}
		// The piece's own box, its low corner snapped down onto the whole mesh's lattice,
		// so its lattice points are the whole's (neighbouring pieces meet on them) while
		// its rays cover only the piece, not the whole box over again. The seams it is
		// capped along are not holes the mesh had, so they go uncounted.
		_, box := mesh_area_bounds(piece.mesh, pool)
		for a in 0 ..< 3 do box.lo[a] = bounds.lo[a] + math.floor((box.lo[a] - bounds.lo[a]) / h) * h
		seams: Remesh_Report
		one, built := remesh_closed_first(piece.mesh, h, box, smooth, pool, heap, progress, piece_share, &seams)
		if progress != nil && jobs.progress_cancelled(progress) do return {}, false
		if !built {
			r.dropped += 1
			continue
		}
		append(&made, one)
		append(&made_ids, ids[i])
	}
	if len(made) == 0 do return {}, false
	out = mesh_join(made[:], allocator)
	r.groups = make([]u16, len(out.indices) / 3, allocator)
	at := 0
	for p, i in made {
		for _ in 0 ..< len(p.indices) / 3 {
			r.groups[at] = made_ids[i]
			at += 1
		}
	}
	return out, true
}

// The lattice a remesh of a surface of `area` inside `bounds` to about `target` vertices
// uses: its spacing, and where its first point is (as remesh_run places it). The density
// preview draws these very cells, so what it shows is what the remesh will build.
remesh_lattice :: proc(area: f64, bounds: Aabb, target: int) -> (h: f32, origin: Vec3, ok: bool) {
	if bounds.lo.x > bounds.hi.x do return
	extent := bounds.hi - bounds.lo
	h = max(remesh_spacing_of(area, target), max(extent.x, extent.y, extent.z) / (REMESH_MAX_LATTICE - 4))
	if !(h > 0) do return 0, {}, false
	return h, bounds.lo - 1.5 * h, true
}

// The area of `m` and the box around its triangles' corners, skipping the zeroed slots
// of a dynamic topology layout. The sums are taken a fixed range at a time and added in
// order, so the result is the same, bit for bit, with or without the pool, and whether
// the ranges are measured at once or a few at a time (mesh_area_parts).
mesh_area_bounds :: proc(m: Mesh, pool: ^jobs.Pool = nil) -> (area: f64, bounds: Aabb) {
	parts := make([]Area_Part, mesh_area_part_count(m), runtime.heap_allocator())
	defer delete(parts, runtime.heap_allocator())
	mesh_area_parts(m, parts, 0, len(parts), pool)
	return mesh_area_total(parts)
}

// One range of RANGE_GRAIN triangles' area and box.
Area_Part :: struct {
	area:   f64,
	bounds: Aabb,
}

mesh_area_part_count :: proc(m: Mesh) -> int {
	return (len(m.indices) / 3 + RANGE_GRAIN - 1) / RANGE_GRAIN
}

// Measures parts [from, to) of `m` into `parts` (mesh_area_part_count long), so that a
// caller can spread a big mesh over several frames.
mesh_area_parts :: proc(m: Mesh, parts: []Area_Part, from, to: int, pool: ^jobs.Pool = nil) {
	Work :: struct {
		m:     Mesh,
		parts: []Area_Part,
		from:  int,
	}
	work := Work{m, parts, from}
	jobs.parallel_for(pool, to - from, &work, proc(data: rawptr, i: int) {
		w := cast(^Work)data
		at := w.from + i
		part := Area_Part{0, AABB_EMPTY}
		for t in at * RANGE_GRAIN ..< min((at + 1) * RANGE_GRAIN, len(w.m.indices) / 3) {
			i0, i1, i2 := w.m.indices[3 * t], w.m.indices[3 * t + 1], w.m.indices[3 * t + 2]
			if i0 == i1 && i1 == i2 do continue
			p0, p1, p2 := w.m.positions[i0], w.m.positions[i1], w.m.positions[i2]
			part.area += f64(linalg.length(linalg.cross(p1 - p0, p2 - p0))) * 0.5
			aabb_grow(&part.bounds, p0)
			aabb_grow(&part.bounds, p1)
			aabb_grow(&part.bounds, p2)
		}
		w.parts[at] = part
	})
}

// The parts added up in order.
mesh_area_total :: proc(parts: []Area_Part) -> (area: f64, bounds: Aabb) {
	bounds = AABB_EMPTY
	for part in parts {
		area += part.area
		bounds = aabb_union(bounds, part.bounds)
	}
	return
}

// Remeshes `m` on a lattice of spacing `h` (see remesh_voxel).
remesh_voxel_spacing :: proc(m: Mesh, h: f32, pool: ^jobs.Pool = nil, allocator := context.allocator) -> (out: Mesh, ok: bool) {
	// Straight to the rays: the starters and primitives that use it are closed.
	_, bounds := mesh_area_bounds(m, pool)
	return remesh_run(m, h, bounds, len(m.indices) / 3, .Merge, pool, allocator, smooth = REMESH_SMOOTH_DEFAULT)
}

// What is inside the remeshed surface. Merge: inside any part of the mesh. The others
// take the mesh as two, A (the triangles before `split`) and B (the rest), and keep
// what is inside either (Union), inside A but not B (Subtract), or inside both
// (Intersect). B's crossings count BOOL_WEIGHT times A's in the winding number, which
// keeps the two apart in one sum: A's own winding stays far below the weight.
Remesh_Op :: enum u8 {
	Merge,
	Union,
	Subtract,
	Intersect,
}

@(private = "file")
BOOL_WEIGHT :: i32(1 << 12)

@(private = "file")
inside :: #force_inline proc(op: Remesh_Op, wind: i32) -> bool {
	if op == .Merge do return wind > 0
	b := (wind + BOOL_WEIGHT / 2) >> 12 // rounded to the nearest multiple, negatives too
	a := wind - b * BOOL_WEIGHT
	switch op {
	case .Union:     return a > 0 || b > 0
	case .Subtract:  return a > 0 && b <= 0
	case .Intersect: return a > 0 && b > 0
	case .Merge:
	}
	return wind > 0
}

// The remesh of `m` at spacing `h`, its triangles from `split` on being B for `op`;
// `bounds` is the box around its triangles (mesh_area_bounds), which places the lattice
// as remesh_lattice says.
remesh_run :: proc(m: Mesh, h: f32, bounds: Aabb, split: int, op: Remesh_Op, pool: ^jobs.Pool, allocator: runtime.Allocator, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}, smooth := REMESH_SMOOTH_DEFAULT) -> (out: Mesh, ok: bool) {
	if bounds.lo.x > bounds.hi.x do return {}, false
	extent := bounds.hi - bounds.lo
	r := Remesher{m = m, pool = pool, h = h, origin = bounds.lo - 1.5 * h, split = split, op = op}
	for a in 0 ..< 3 {
		// The mesh starts 1.5 steps in and ends at least half a step before the last
		// point, so the lattice's outer points are all outside.
		r.n[a] = int(extent[a] / h) + 4
		if r.n[a] > REMESH_MAX_LATTICE + 4 do return {}, false
	}
	// Each stage's share of the whole, as a remesh of a 2M-vertex sculpt to 1M spends it,
	// so a job's ring moves about evenly; a stage boundary is also where a cancel stops it.
	STAGES :: [?]f32{0, 0.02, 0.08, 0.16, 0.24, 0.26, 0.28, 0.33, 0.65, 1}
	stage := 0
	next :: proc(progress: ^jobs.Progress, stage: ^int, share: [2]f32) -> bool {
		stages := STAGES
		stage^ += 1
		jobs.progress_set(progress, share[0], share[1], stages[stage^])
		return !jobs.progress_cancelled(progress)
	}
	r.q = lattice_quantize(m, r.origin, h, pool, context.temp_allocator)
	defer for &rays in r.rays do lattice_rays_destroy(&rays)
	if !next(progress, &stage, share) do return {}, false
	for axis in 0 ..< 3 {
		r.rays[axis] = lattice_rays_cast(m, r.q, r.origin, h, r.n, axis, split, BOOL_WEIGHT, pool, runtime.heap_allocator())
		if !next(progress, &stage, share) do return {}, false
	}
	find_flips(&r)
	defer {
		delete(r.flip_e, runtime.heap_allocator())
		delete(r.flip_w, runtime.heap_allocator())
		delete(r.flip_count, runtime.heap_allocator())
		delete(r.x_base, runtime.heap_allocator())
		delete(r.y_base, runtime.heap_allocator())
		delete(r.z_base, runtime.heap_allocator())
	}
	if !next(progress, &stage, share) do return {}, false
	count_vertices(&r)
	if r.vertex_count == 0 do return {}, false
	if !next(progress, &stage, share) do return {}, false
	sync.once_do(&mc_once, mc_build_table)

	out.positions = make([dynamic]Vec3, r.vertex_count, allocator)
	out.normals = make([dynamic]Vec3, r.vertex_count, allocator)
	r.out = &out
	place_vertices(&r)
	if next(progress, &stage, share) do march_cells(&r, allocator)
	if next(progress, &stage, share) do relax(&out, pool, smooth)
	if !next(progress, &stage, share) {
		mesh_destroy(&out)
		return {}, false
	}
	return out, true
}

@(private = "file")
Remesher :: struct {
	m:            Mesh,
	pool:         ^jobs.Pool,
	h:            f32,
	split:        int,       // triangles from here on are B (Remesh_Op)
	op:           Remesh_Op,
	origin:       Vec3,
	n:            [3]int,     // lattice points per axis
	q:            [][3]i32,   // vertex positions in fixed point, lattice steps * LATTICE_FIX
	rays:         [3]Lattice_Rays, // along x, y and z (lattice_rays.odin)
	// Per x ray, where insideness changes: the lattice edges [e, e + 1] it changes on,
	// and where. Stored like that ray's hits, flip_count[r] of them.
	flip_e:       []i32,
	flip_w:       []f32,
	flip_count:   []u32,
	// First vertex number of each x ray's flips, each y strip's and each z strip's
	// changes. A y strip is the pair of x rays (j, k) and (j + 1, k), numbered
	// j + (n.y - 1) * k; its vertices are where the two disagree, on the y edges
	// between them. A z strip is (j, k) and (j, k + 1), numbered j + n.y * k.
	x_base:       []u32,
	y_base:       []u32,
	z_base:       []u32,
	vertex_count: int,
	out:          ^Mesh,
	slabs:        [][dynamic]u32, // per k: the triangles of the cells there
	slab_at:      []int,          // where each slab's indices go in the result
}

// Where insideness changes along each x ray: on the lattice edge [e, e + 1] holding
// the crossings that change it, at the last of them that does.
@(private = "file")
find_flips :: proc(r: ^Remesher) {
	rays := &r.rays[0]
	heap := runtime.heap_allocator()
	r.flip_e = make([]i32, len(rays.hits), heap)
	r.flip_w = make([]f32, len(rays.hits), heap)
	r.flip_count = make([]u32, rays.nu * rays.nv, heap)
	jobs.parallel_ranges(r.pool, rays.nu * rays.nv, r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Remesher)data
		rays := &r.rays[0]
		for ray in lo ..< hi {
			first := int(rays.first[ray])
			hs := rays.hits[first:rays.first[ray + 1]]
			count := 0
			for i := 0; i < len(hs); {
				e := i32(hs[i].w)
				before: i32 = hs[i - 1].wind if i > 0 else 0
				at := f32(-1)
				for i < len(hs) && i32(hs[i].w) == e {
					prev: i32 = hs[i - 1].wind if i > 0 else 0
					if inside(r.op, prev) != inside(r.op, hs[i].wind) do at = hs[i].w
					i += 1
				}
				if inside(r.op, before) == inside(r.op, hs[i - 1].wind) do continue
				r.flip_e[first + count] = e
				r.flip_w[first + count] = clamp(at, f32(e) + EDGE_MARGIN, f32(e) + 1 - EDGE_MARGIN)
				count += 1
			}
			r.flip_count[ray] = u32(count)
		}
	}, 1 << 12)
}

@(private = "file")
flips_of :: #force_inline proc(r: ^Remesher, ray: int) -> []i32 {
	first := r.rays[0].first[ray]
	return r.flip_e[first:][:r.flip_count[ray]]
}

// How many lattice points two x rays disagree on: insideness toggles at e + 1 for each
// flip e, so they disagree between consecutive toggles of either, every other time.
@(private = "file")
xor_count :: proc(fa, fb: []i32) -> int {
	count, start := 0, i32(0)
	state := false
	ia, ib := 0, 0
	for ia < len(fa) || ib < len(fb) {
		t: i32
		if ib >= len(fb) || (ia < len(fa) && fa[ia] <= fb[ib]) {
			t = fa[ia] + 1
			ia += 1
		} else {
			t = fb[ib] + 1
			ib += 1
		}
		if state do count += int(t - start)
		state, start = !state, t
	}
	return count
}

// Numbers the vertices: x rays' flips first, then y strips', then z strips'.
@(private = "file")
count_vertices :: proc(r: ^Remesher) {
	ny, nz := r.n[1], r.n[2]
	heap := runtime.heap_allocator()
	r.x_base = make([]u32, ny * nz + 1, heap)
	r.y_base = make([]u32, (ny - 1) * nz + 1, heap)
	r.z_base = make([]u32, ny * (nz - 1) + 1, heap)
	jobs.parallel_ranges(r.pool, nz, r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Remesher)data
		ny, nz := r.n[1], r.n[2]
		for k in lo ..< hi {
			for j in 0 ..< ny {
				ray := j + ny * k
				r.x_base[ray + 1] = r.flip_count[ray]
				if j + 1 < ny do r.y_base[j + (ny - 1) * k + 1] = u32(xor_count(flips_of(r, ray), flips_of(r, ray + 1)))
				if k + 1 < nz do r.z_base[ray + 1] = u32(xor_count(flips_of(r, ray), flips_of(r, ray + ny)))
			}
		}
	}, 16)
	total: u32
	for base in ([3][]u32{r.x_base, r.y_base, r.z_base}) {
		base[0] += total
		for i in 1 ..< len(base) do base[i] += base[i - 1]
		total = base[len(base) - 1]
	}
	r.vertex_count = int(total)
}

// Where the surface crosses the y (or z) edges between lattice points p, j..j + 1
// (k..k + 1): from the crossings of the ray along that edge, the one that changes its
// insideness; the middle of the edge when that ray disagrees with the x rays.
@(private = "file")
crossing_on :: proc(rays: ^Lattice_Rays, op: Remesh_Op, ray: int, lo: int) -> f32 {
	hs := rays.hits[rays.first[ray]:rays.first[ray + 1]]
	at := f32(lo) + 0.5
	i, _ := slice.binary_search_by(hs, f32(lo), proc(h: Lattice_Hit, w: f32) -> slice.Ordering {return .Less if h.w < w else .Greater})
	for ; i < len(hs) && hs[i].w < f32(lo + 1); i += 1 {
		prev: i32 = hs[i - 1].wind if i > 0 else 0
		if inside(op, prev) != inside(op, hs[i].wind) do at = hs[i].w
	}
	return clamp(at, f32(lo) + EDGE_MARGIN, f32(lo) + 1 - EDGE_MARGIN)
}

// Calls fn(i, rank) for each lattice point i where two x rays disagree, in order.
@(private = "file")
each_disagreement :: #force_inline proc(fa, fb: []i32, data: rawptr, fn: proc(data: rawptr, i, rank: int)) {
	start := i32(0)
	state := false
	ia, ib, rank := 0, 0, 0
	for ia < len(fa) || ib < len(fb) {
		t: i32
		if ib >= len(fb) || (ia < len(fa) && fa[ia] <= fb[ib]) {
			t = fa[ia] + 1
			ia += 1
		} else {
			t = fb[ib] + 1
			ib += 1
		}
		if state {
			for i in start ..< t {
				fn(data, int(i), rank)
				rank += 1
			}
		}
		state, start = !state, t
	}
}

@(private = "file")
place_vertices :: proc(r: ^Remesher) {
	jobs.parallel_ranges(r.pool, r.n[2], r, proc(data: rawptr, lo, hi: int) {
		r := cast(^Remesher)data
		ny, nz := r.n[1], r.n[2]
		Strip :: struct {
			r:    ^Remesher,
			j, k: int,
			base: u32,
		}
		for k in lo ..< hi {
			for j in 0 ..< ny {
				ray := j + ny * k
				first := r.rays[0].first[ray]
				for f in 0 ..< int(r.flip_count[ray]) {
					r.out.positions[int(r.x_base[ray]) + f] = r.origin + r.h * Vec3{r.flip_w[int(first) + f], f32(j), f32(k)}
				}
				if j + 1 < ny {
					s := Strip{r, j, k, r.y_base[j + (ny - 1) * k]}
					each_disagreement(flips_of(r, ray), flips_of(r, ray + 1), &s, proc(data: rawptr, i, rank: int) {
						s := cast(^Strip)data
						r := s.r
						// The y ray through x = i, z = k.
						w := crossing_on(&r.rays[1], r.op, s.k + r.n[2] * i, s.j)
						r.out.positions[int(s.base) + rank] = r.origin + r.h * Vec3{f32(i), w, f32(s.k)}
					})
				}
				if k + 1 < nz {
					s := Strip{r, j, k, r.z_base[ray]}
					each_disagreement(flips_of(r, ray), flips_of(r, ray + ny), &s, proc(data: rawptr, i, rank: int) {
						s := cast(^Strip)data
						r := s.r
						// The z ray through x = i, y = j.
						w := crossing_on(&r.rays[2], r.op, i + r.n[0] * s.j, s.k)
						r.out.positions[int(s.base) + rank] = r.origin + r.h * Vec3{f32(i), f32(s.j), w}
					})
				}
			}
		}
	}, 4)
}

// Marching cubes over the cells with differing corners, a column of cells (fixed j,
// k, every i) at a time, walking only the stretches where something changes.
@(private = "file")
march_cells :: proc(r: ^Remesher, allocator: runtime.Allocator) {
	r.slabs = make([][dynamic]u32, r.n[2] - 1, context.temp_allocator)
	jobs.parallel_for(r.pool, r.n[2] - 1, r, proc(data: rawptr, k: int) {
		r := cast(^Remesher)data
		r.slabs[k] = make([dynamic]u32, 0, 1024, runtime.heap_allocator())
		for j in 0 ..< r.n[1] - 1 do march_column(r, j, k, &r.slabs[k])
	})
	// Then all into one array, the slabs copied in parallel: the copy is mostly first
	// touches of new memory, slow enough on one thread to cost more than the marching.
	r.slab_at = make([]int, len(r.slabs) + 1, context.temp_allocator)
	for s, k in r.slabs do r.slab_at[k + 1] = r.slab_at[k] + len(s)
	r.out.indices = make([dynamic]u32, r.slab_at[len(r.slabs)], allocator)
	jobs.parallel_for(r.pool, len(r.slabs), r, proc(data: rawptr, k: int) {
		r := cast(^Remesher)data
		copy(r.out.indices[r.slab_at[k]:], r.slabs[k][:])
		delete(r.slabs[k])
	})
}

@(private = "file")
march_column :: proc(r: ^Remesher, j, k: int, out: ^[dynamic]u32) {
	ny := r.n[1]
	// The four x rays at the column's corners, numbered dy | dz << 1.
	rays := [4]int{j + ny * k, j + 1 + ny * k, j + ny * (k + 1), j + 1 + ny * (k + 1)}
	flips: [4][]i32
	total := 0
	for b in 0 ..< 4 {
		flips[b] = flips_of(r, rays[b])
		total += len(flips[b])
	}
	if total == 0 do return
	// The y strips at z = k, k + 1 (rays 0-1, 2-3) and z strips at y = j, j + 1 (0-2, 1-3).
	strip_base := [4]u32{r.y_base[j + (ny - 1) * k], r.y_base[j + (ny - 1) * (k + 1)], r.z_base[j + ny * k], r.z_base[j + 1 + ny * k]}
	strip_rank: [4]u32

	// Toggle points, sorted and unique.
	stack: [64]i32
	toggles := stack[:total] if total <= len(stack) else make([]i32, total, context.temp_allocator)
	count := 0
	for b in 0 ..< 4 do for e in flips[b] {
		toggles[count] = e + 1
		count += 1
	}
	slice.sort(toggles)
	toggles = slice.unique(toggles)

	ptr: [4]int // per ray: flips with e < the last point asked about
	inside_at :: #force_inline proc(flips: ^[4][]i32, ptr: ^[4]int, p: i32) -> (bits: u8) {
		for b in 0 ..< 4 {
			for ptr[b] < len(flips[b]) && flips[b][ptr[b]] < p do ptr[b] += 1
			if ptr[b] & 1 == 1 do bits |= 1 << u8(b)
		}
		return
	}
	last_point := i32(-1)
	ids_next: [4]i32 // strip vertices at the last point accounted
	account :: #force_inline proc(bits: u8, strip_base: [4]u32, strip_rank: ^[4]u32) -> (ids: [4]i32) {
		strip_rays := [4][2]u8{{0, 1}, {2, 3}, {0, 2}, {1, 3}}
		for s in 0 ..< 4 {
			ids[s] = -1
			if (bits >> strip_rays[s][0]) & 1 != (bits >> strip_rays[s][1]) & 1 {
				ids[s] = i32(strip_base[s] + strip_rank[s])
				strip_rank[s] += 1
			}
		}
		return
	}
	cell :: proc(r: ^Remesher, i: i32, flips: ^[4][]i32, ptr: ^[4]int, rays: [4]int, strip_base: [4]u32, strip_rank: ^[4]u32, last_point: ^i32, ids_next: ^[4]i32, out: ^[dynamic]u32) {
		lo := inside_at(flips, ptr, i)
		// x edges at e = i: a flip there, numbered by its place on its ray.
		x_ids: [4]i32
		for b in 0 ..< 4 {
			x_ids[b] = -1
			if ptr[b] < len(flips[b]) && flips[b][ptr[b]] == i do x_ids[b] = i32(r.x_base[rays[b]]) + i32(ptr[b])
		}
		ids_lo := ids_next^ if last_point^ == i else account(lo, strip_base, strip_rank)
		hi := inside_at(flips, ptr, i + 1)
		ids_hi := account(hi, strip_base, strip_rank)
		last_point^, ids_next^ = i + 1, ids_hi
		corners := u32(lo) | u32(hi) << 4 // corner dx | dy << 1 | dz << 2 below is remapped
		// Corner c = dx | dy << 1 | dz << 2 is ray dy | dz << 1 at point i + dx.
		mc_case: u8
		for c in 0 ..< 8 {
			b := c >> 1
			if (corners >> u32(b + 4 * (c & 1))) & 1 == 1 do mc_case |= 1 << u8(c)
		}
		if mc_case == 0 || mc_case == 0xff do return
		// Vertex of each cell edge (see mc_build_table for the numbering).
		edge: [12]i32
		for b in 0 ..< 4 do edge[b] = x_ids[b]              // x edges: ray dy | dz << 1
		for idx in 0 ..< 4 {
			dx, d2 := idx & 1, idx >> 1
			ids := ids_hi if dx == 1 else ids_lo
			edge[4 + idx] = ids[d2]     // y edges: dx | dz << 1, strip y at z = k + dz
			edge[8 + idx] = ids[2 + d2] // z edges: dx | dy << 1, strip z at y = j + dy
		}
		tris := mc_tris[mc_case][:3 * int(mc_tri_count[mc_case])]
		for e in tris {
			assert(edge[e] >= 0, "marching cubes edge without a vertex")
			append(out, u32(edge[e]))
		}
	}

	n0 := i32(r.n[0])
	start := i32(0)
	for t_index := 0; t_index <= len(toggles); t_index += 1 {
		end := toggles[t_index] if t_index < len(toggles) else n0
		bits := inside_at(&flips, &ptr, start)
		agree := bits == 0 || bits == 0xf
		if !agree {
			for i in start ..< end - 1 do cell(r, i, &flips, &ptr, rays, strip_base, &strip_rank, &last_point, &ids_next, out)
		}
		if end < n0 && end - 1 >= 0 do cell(r, end - 1, &flips, &ptr, rays, strip_base, &strip_rank, &last_point, &ids_next, out)
		start = end
	}
}

// Marching cubes triangles per case (corner c inside when bit c is set), as cell edge
// numbers, three per triangle. Corner c sits at (c & 1, c >> 1 & 1, c >> 2 & 1). Edge
// a * 4 + idx runs along axis a from the corner whose other two coordinates are the
// bits of idx (lower axis first).
@(private = "file")
mc_tris: [256][30]u8
@(private = "file")
mc_tri_count: [256]u8

// Builds the table from one rule rather than by hand: on each cube face, the surface
// joins the face's crossing edges in pairs, keeping the face's inside corners apart
// when two of them sit diagonally, and runs clockwise around the inside seen from
// outside the cube. Neighbouring cells see the same face the same way, so the
// surface is closed and manifold. Each cell's crossing edges then form loops, each
// fanned into triangles that face outward.
@(private = "file")
mc_once: sync.Once

@(private = "file")
mc_build_table :: proc() {
	edges: [12][2]u8
	for a in 0 ..< 3 {
		o1, o2 := (a + 1) % 3, (a + 2) % 3
		if o1 > o2 do o1, o2 = o2, o1
		for idx in 0 ..< 4 {
			c0 := u8((idx & 1) << uint(o1) | (idx >> 1) << uint(o2))
			edges[a * 4 + idx] = {c0, c0 | 1 << uint(a)}
		}
	}
	corner_pos :: proc(c: u8) -> [3]f32 {return {f32(c & 1), f32(c >> 1 & 1), f32(c >> 2 & 1)}}
	for mc_case in 0 ..< 256 {
		inside :: proc(mc_case: int, c: u8) -> bool {return (mc_case >> c) & 1 == 1}
		next: [12]i8
		for &x in next do x = -1
		segment :: proc(edges: [12][2]u8, mc_case: int, next: ^[12]i8, e1, e2: int, normal: [3]f32) {
			c_in := edges[e1][0] if inside(mc_case, edges[e1][0]) else edges[e1][1]
			m1 := (corner_pos(edges[e1][0]) + corner_pos(edges[e1][1])) * 0.5
			m2 := (corner_pos(edges[e2][0]) + corner_pos(edges[e2][1])) * 0.5
			p := corner_pos(c_in)
			from, to := e1, e2
			if linalg.dot(linalg.cross(m1 - p, m2 - p), normal) > 0 do from, to = e2, e1
			assert(next[from] < 0, "two segments leave one edge")
			next[from] = i8(to)
		}
		for a in 0 ..< 3 do for side in 0 ..< 2 {
			normal: [3]f32
			normal[a] = 1 if side == 1 else -1
			on_face :: proc(c: u8, a, side: int) -> bool {return int(c >> uint(a) & 1) == side}
			crossing: [dynamic; 4]int
			for e in 0 ..< 12 {
				c0, c1 := edges[e][0], edges[e][1]
				if !on_face(c0, a, side) || !on_face(c1, a, side) do continue
				if inside(mc_case, c0) != inside(mc_case, c1) do append(&crossing, e)
			}
			switch len(crossing) {
			case 2:
				segment(edges, mc_case, &next, crossing[0], crossing[1], normal)
			case 4:
				// Diagonal inside corners: pair the two edges at each inside corner.
				for c in 0 ..< u8(8) {
					if !on_face(c, a, side) || !inside(mc_case, c) do continue
					pair: [dynamic; 2]int
					for e in crossing do if edges[e][0] == c || edges[e][1] == c do append(&pair, e)
					segment(edges, mc_case, &next, pair[0], pair[1], normal)
				}
			}
		}
		seen: [12]bool
		count := 0
		for start in 0 ..< 12 {
			if next[start] < 0 || seen[start] do continue
			loop: [dynamic; 12]int
			for e := start; !seen[e]; e = int(next[e]) {
				seen[e] = true
				append(&loop, e)
				assert(next[e] >= 0, "open marching cubes loop")
			}
			for t in 1 ..< len(loop) - 1 {
				mc_tris[mc_case][3 * count + 0] = u8(loop[0])
				mc_tris[mc_case][3 * count + 1] = u8(loop[t])
				mc_tris[mc_case][3 * count + 2] = u8(loop[t + 1])
				count += 1
			}
		}
		mc_tri_count[mc_case] = u8(count)
	}
}

// Evens out the triangles over `rounds`: each round moves every vertex part of the way toward the
// middle of its triangles, along the surface only (the normal there taken from the
// same triangles), so the shape stays. Rounds read one buffer and write the other; a
// last pass with no movement leaves the positions in place and the normals current.
@(private = "file")
relax :: proc(m: ^Mesh, pool: ^jobs.Pool, rounds: int) {
	Relax :: struct {
		m:        ^Mesh,
		faces:    Vertex_Faces,
		from, to: []Vec3,
		rate:     f32,
	}
	x := Relax{m = m, faces = vertex_faces_build(m^, pool, context.temp_allocator), from = m.positions[:]}
	x.to = make([]Vec3, len(m.positions), context.temp_allocator)
	for round in 0 ..= rounds {
		x.rate = RELAX_RATE if round < rounds else 0
		jobs.parallel_ranges(pool, len(m.positions), &x, proc(data: rawptr, lo, hi: int) {
			x := cast(^Relax)data
			m := x.m
			for v in lo ..< hi {
				centre, normal: Vec3
				faces := vertex_faces_of(x.faces, u32(v))
				for f in faces {
					p0, p1, p2 := x.from[m.indices[3 * f]], x.from[m.indices[3 * f + 1]], x.from[m.indices[3 * f + 2]]
					centre += p0 + p1 + p2
					normal += linalg.cross(p1 - p0, p2 - p0)
				}
				n := linalg.normalize0(normal)
				p := x.from[v]
				if x.rate == 0 {
					m.normals[v] = n
					x.to[v] = p
					continue
				}
				step := centre / f32(3 * max(len(faces), 1)) - p
				step -= n * linalg.dot(step, n)
				x.to[v] = p + step * x.rate
			}
		}, RANGE_GRAIN)
		x.from, x.to = x.to, x.from
	}
}
