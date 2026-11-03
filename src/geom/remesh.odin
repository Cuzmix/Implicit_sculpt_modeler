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
	quads:       bool, // the dual of the marching cubes: a closed mesh of quads only (Remesh_Report.quads)
	mirror:      Remesh_Mirror,
	// The lattice spacing to use, in the mesh's units, instead of the one `target` gives
	// (0): Blender's voxel size, and what remeshing again at the object's own cell keeps,
	// so the density stays as the sculpt grows, as DynaMesh keeps its resolution.
	cell:        f32,
	// Parts thinner than a cell (a fin, an ear's rim, a sheet) kept about a cell thick
	// rather than lost between the lattice's points (keep_thin_parts).
	keep_thin:   bool,
}

// Planes a remesh keeps its lattice the same on both sides of, as the brush's symmetry
// mirrors its dabs across them: each axis set is the plane through `center` square to it.
// A lattice placed from the mesh's box alone has its points where they fall, which on a
// symmetric sculpt are seldom each other's mirror images, so the two halves are sampled
// differently and come out different by up to a cell; with the planes given, a mirrored
// point is a lattice point too, and a symmetric mesh remeshes to a symmetric one.
Remesh_Mirror :: struct {
	axes:   [3]bool,
	center: Vec3,
}

REMESH_OPTIONS_DEFAULT :: Remesh_Options{smooth = REMESH_SMOOTH_DEFAULT, keep_thin = true}

// What a remesh did that its caller reports: the triangles mended and the holes capped
// before the rays, the group
// pieces made and those that gave nothing (thinner than a cell), each output triangle's
// group (with `groups` asked, else nil) and each output vertex's old triangle (with Keep
// detail, else nil; max(u32) where the projection found nothing within a cell). The two
// slices are the caller's to free (remesh_report_destroy).
Remesh_Report :: struct {
	mended:       int, // triangles dropped (doubled or degenerate) or turned back before the rays (mesh_fix)
	holes_closed: int,
	turned:       bool, // the mesh was inside out (its volume negative) and was turned outward first
	pieces:       int,
	dropped:      int,
	groups:       []u16,
	source_tris:  []u32,
	// With `quads` asked: the output's quads in its vertex numbers, each facing outward,
	// output triangles 2q and 2q + 1 being quad q's two halves (quad_split's shorter
	// diagonal), so a polygon table over the triangles is q = t / 2. Nil with quads_thin:
	// the dual was refused because two patches across a cell face would share an edge
	// four quads at a time, which the turned face rule (cell_flips) leaves only where
	// several of one cell's faces turn at once (rare), so the result is the triangles it
	// always was; a higher density gives quads.
	quads:        [][4]u32,
	quads_thin:   bool,
	cell:         f32, // the lattice spacing used, in the mesh's units
	thickened:    int, // lattice points Keep thin parts put inside
}

remesh_report_destroy :: proc(r: ^Remesh_Report, allocator := context.allocator) {
	delete(r.groups, allocator)
	delete(r.source_tris, allocator)
	delete(r.quads, allocator)
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
	// The lattice's box: the mesh's own, or grown even about the mirror's planes.
	h := remesh_cell(area, bounds, target, options.cell) or_return
	box := bounds
	own: Remesh_Report
	r := report if report != nil else &own
	r^ = {}
	// With no report asked for, what a report would hold (the source triangles of Keep
	// detail, the groups) is the remesh's own to free.
	defer if report == nil do remesh_report_destroy(&own, allocator)
	r.cell = h
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
	quads: ^[][4]u32 = &r.quads if options.quads else nil
	thin := make([dynamic]Vec3, 0, 0, runtime.heap_allocator())
	defer delete(thin)
	kept: ^[dynamic]Vec3 = &thin if options.keep_thin else nil
	if options.groups != nil {
		out = remesh_groups(input, options.groups, h, box, smooth, pool, allocator, progress, rays_share, r, quads, options.mirror, kept) or_return
	} else {
		out = remesh_closed_first(input, h, box, smooth, pool, allocator, progress, rays_share, r, quads, options.mirror, kept) or_return
	}
	r.thickened = len(thin)
	// Keep detail puts every vertex back; without it, the kept thin parts' own go back,
	// which a lattice steps across in terraces a cell high.
	if len(thin) > 0 && !options.keep_detail do project_thin(&out, m, thin[:], h, lattice_origin(box.lo, h, options.mirror), pool)
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

// Puts the vertices of `out` near a kept thin part (a corner of the cell they are in is one
// of the points `thin`, as the pieces' lattices, all one lattice from `origin`, put
// inside) back onto `m` along their normals within a cell, as Keep detail does for all of
// them: a thin part the lattice holds a cell thick then lies on the part's two sides.
// The rest stay where they are, so the cost follows the thin parts, not the mesh.
@(private = "file")
project_thin :: proc(out: ^Mesh, m: Mesh, thin: []Vec3, h: f32, origin: Vec3, pool: ^jobs.Pool) {
	heap := runtime.heap_allocator()
	key :: proc(g: [3]int) -> u64 {return u64(g[0]) | u64(g[1]) << 21 | u64(g[2]) << 42}
	keys := make([]u64, len(thin), heap)
	defer delete(keys, heap)
	for p, i in thin {
		g := linalg.round((p - origin) / h)
		keys[i] = key({int(g.x), int(g.y), int(g.z)})
	}
	slice.sort(keys)
	Near :: struct {
		out:    ^Mesh,
		keys:   []u64,
		h:      f32,
		origin: Vec3,
		near:   []bool,
	}
	job := Near{out, keys, h, origin, make([]bool, len(out.positions), heap)}
	defer delete(job.near, heap)
	jobs.parallel_ranges(pool, len(out.positions), &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Near)data
		for v in lo ..< hi {
			c := linalg.floor((job.out.positions[v] - job.origin) / job.h)
			if c.x < 0 || c.y < 0 || c.z < 0 do continue
			for corner in 0 ..< 8 {
				g := [3]int{int(c.x) + corner & 1, int(c.y) + corner >> 1 & 1, int(c.z) + corner >> 2 & 1}
				if _, found := slice.binary_search(job.keys, key(g)); found {
					job.near[v] = true
					break
				}
			}
		}
	}, RANGE_GRAIN)
	which := make([dynamic]u32, 0, len(thin) * 4, heap)
	defer delete(which)
	for near, v in job.near do if near do append(&which, u32(v))
	if len(which) == 0 do return
	at := make([]Vec3, 3 * len(which), heap)
	defer delete(at, heap)
	positions, normals, next := at[:len(which)], at[len(which):][:len(which)], at[2 * len(which):]
	for v, i in which do positions[i], normals[i] = out.positions[v], out.normals[v]
	bvh := bvh_build_morton(m, pool = pool)
	defer bvh_destroy(&bvh)
	_ = project_along_normals(positions, normals, m, &bvh, h, pool, next, nil)
	for v, i in which do out.positions[v] = next[i]
	mesh_recompute_normals(out)
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

// The remesh of `m` on the lattice, mended and its holes capped first when its edges do
// not pair off: a doubled triangle or one turned against its neighbours puts the winding
// behind it out by two, and a ray's winding behind a sheet it crosses once never comes
// back, so such a part would be filled, dropped or left open at the lattice's edge by the
// luck of which way the rays meet it. Mended (mesh_fix: duplicates dropped, turned
// triangles turned back, nothing moved) and capped, a bowl becomes a solid whichever way
// it opens, as DynaMesh makes it.
@(private = "file")
remesh_closed_first :: proc(source: Mesh, h: f32, bounds: Aabb, smooth: int, pool: ^jobs.Pool, allocator: runtime.Allocator, progress: ^jobs.Progress, share: [2]f32, r: ^Remesh_Report, quads: ^[][4]u32 = nil, mirror := Remesh_Mirror{}, kept: ^[dynamic]Vec3 = nil) -> (out: Mesh, ok: bool) {
	// A run asked for quads that leaves none refused them (remesh_run).
	defer if ok && quads != nil && quads^ == nil do r.quads_thin = true
	if mesh_edges_paired(source, pool) do return remesh_run(source, h, bounds, len(source.indices) / 3, .Merge, pool, allocator, progress, share, smooth, quads, mirror, kept)
	heap := runtime.heap_allocator()
	m := source
	fixed, fixed_from, fix, mended := mesh_fix(source, pool, heap)
	defer if mended {
		mesh_destroy(&fixed)
		repair_map_destroy(&fixed_from, heap)
	}
	if mended {
		r.mended += fix.dropped_triangles + fix.duplicate_triangles + fix.flipped_triangles
		m = fixed
		if mesh_edges_paired(m, pool) do return remesh_run(m, h, bounds, len(m.indices) / 3, .Merge, pool, allocator, progress, share, smooth, quads, mirror, kept)
	}
	capped, from, closed, did := mesh_close_holes(m, false, pool, heap)
	if !did do return remesh_run(m, h, bounds, len(m.indices) / 3, .Merge, pool, allocator, progress, share, smooth, quads, mirror, kept)
	defer mesh_destroy(&capped)
	defer repair_map_destroy(&from, heap)
	// A cap's vertices are raised to a membrane over the border's heights, which can
	// leave the box the lattice was placed from; the lattice needs every vertex inside
	// it (a step and a half from its outer points), so they are held within the box.
	for &p in capped.positions do for a in 0 ..< 3 do p[a] = clamp(p[a], bounds.lo[a], bounds.hi[a])
	r.holes_closed += closed.closed
	return remesh_run(capped, h, bounds, len(capped.indices) / 3, .Merge, pool, allocator, progress, share, smooth, quads, mirror, kept)
}

// Each group of `m` remeshed on the same lattice as a closed piece of its own, then all
// in one mesh with r.groups saying each triangle's group. Groups are taken in ascending
// order of their number, so the pieces' order, and the result, follow from the mesh alone.
@(private = "file")
remesh_groups :: proc(m: Mesh, groups: []u16, h: f32, bounds: Aabb, smooth: int, pool: ^jobs.Pool, allocator: runtime.Allocator, progress: ^jobs.Progress, share: [2]f32, r: ^Remesh_Report, quads: ^[][4]u32 = nil, mirror := Remesh_Mirror{}, kept: ^[dynamic]Vec3 = nil) -> (out: Mesh, ok: bool) {
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
	made_quads := make([dynamic][][4]u32, 0, len(pieces), heap)
	defer {
		for q in made_quads do delete(q, heap)
		delete(made_quads)
	}
	span := (share[1] - share[0]) / f32(max(len(pieces), 1))
	for &piece, i in pieces {
		r.pieces += 1
		piece_share := [2]f32{share[0] + f32(i) * span, share[0] + f32(i + 1) * span}
		// The piece's own box: the lattice is anchored (lattice_origin), so its points are
		// the whole's (neighbouring pieces meet on them) while its rays cover only the
		// piece, not the whole box over again. The seams it is capped along are not holes
		// the mesh had, so they go uncounted.
		_, box := mesh_area_bounds(piece.mesh, pool)
		seams: Remesh_Report
		piece_quads: [][4]u32
		one, built := remesh_closed_first(piece.mesh, h, box, smooth, pool, heap, progress, piece_share, &seams, &piece_quads if quads != nil && !r.quads_thin else nil, mirror, kept)
		if progress != nil && jobs.progress_cancelled(progress) do return {}, false
		if !built {
			r.dropped += 1
			continue
		}
		append(&made, one)
		append(&made_ids, ids[i])
		// A piece that refused its quads (seams.quads_thin) makes the whole triangles:
		// the pieces after it skip the dual and the ones before drop theirs.
		if seams.quads_thin do r.quads_thin = true
		r.mended += seams.mended
		if quads != nil && !r.quads_thin do append(&made_quads, piece_quads)
	}
	if len(made) == 0 do return {}, false
	out = mesh_join(made[:], allocator)
	if quads != nil && !r.quads_thin {
		// The pieces' quads over the joined mesh, each piece's corners moved up by the
		// vertices of the pieces before it, as mesh_join laid them.
		total := 0
		for q in made_quads do total += len(q)
		quads^ = make([][4]u32, total, allocator)
		at, base := 0, u32(0)
		for q, i in made_quads {
			for f in q {
				quads^[at] = f + base
				at += 1
			}
			base += u32(len(made[i].positions))
		}
	}
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
// (or at spacing `cell`, when it is not 0) uses: its spacing, and where its first point is
// (as remesh_run places it). The density preview draws these very cells, so what it shows
// is what the remesh will build.
remesh_lattice :: proc(area: f64, bounds: Aabb, target: int, mirror := Remesh_Mirror{}, cell := f32(0)) -> (h: f32, origin: Vec3, ok: bool) {
	h = remesh_cell(area, bounds, target, cell) or_return
	return h, lattice_origin(bounds.lo, h, mirror), true
}

// The spacing of a remesh of a surface of `area` to about `target` vertices, or `cell`
// when it is not 0, made no finer than REMESH_MAX_LATTICE points along the box's longest
// side allow.
remesh_cell :: proc(area: f64, bounds: Aabb, target: int, cell := f32(0)) -> (h: f32, ok: bool) {
	if bounds.lo.x > bounds.hi.x do return
	extent := bounds.hi - bounds.lo
	h = cell if cell > 0 else remesh_spacing_of(area, target)
	h = max(h, max(extent.x, extent.y, extent.z) / (REMESH_MAX_LATTICE - 4))
	return h, h > 0
}

// The lattice's first point for a box starting at `lo`: between one and a half and two
// and a half steps below it, and on the one lattice of spacing `h` whose points lie at a
// whole number of steps and a half from the origin of the mesh's space, or from the
// mirror's centre along a mirrored axis. A lattice placed from the box alone moved with
// every change of the box, so a remesh of a remesh sampled every part of it anew and
// softened what nobody touched, a little more each time; on the anchored lattice the
// untouched surface lands on the very points it came from (as Blender's voxel grid sits
// on the world's), and a mirrored point is a lattice point, half way across the plane.
lattice_origin :: proc(lo: Vec3, h: f32, mirror := Remesh_Mirror{}) -> (origin: Vec3) {
	for a in 0 ..< 3 {
		c := mirror.center[a] if mirror.axes[a] else 0
		origin[a] = c + (math.floor((lo[a] - c) / h) - 1.5) * h
	}
	return
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
remesh_run :: proc(m: Mesh, h: f32, bounds: Aabb, split: int, op: Remesh_Op, pool: ^jobs.Pool, allocator: runtime.Allocator, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}, smooth := REMESH_SMOOTH_DEFAULT, quads: ^[][4]u32 = nil, mirror := Remesh_Mirror{}, thin: ^[dynamic]Vec3 = nil) -> (out: Mesh, ok: bool) {
	if bounds.lo.x > bounds.hi.x do return {}, false
	r := Remesher{m = m, pool = pool, h = h, origin = lattice_origin(bounds.lo, h, mirror), split = split, op = op}
	for a in 0 ..< 3 {
		// The mesh starts at least 1.5 steps in and ends more than a step before the last
		// point, so the lattice's outer points are all outside.
		r.n[a] = int((bounds.hi[a] - r.origin[a]) / h) + 3
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
	if thin != nil do keep_thin_parts(&r, thin)
	defer {
		delete(r.flip_e, runtime.heap_allocator())
		delete(r.flip_w, runtime.heap_allocator())
		delete(r.flip_count, runtime.heap_allocator())
		if r.flip_owned do delete(r.flip_first, runtime.heap_allocator())
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
	if quads == nil {
		// Which lattice edge each vertex is on, taken before the relax moves them.
		edges := mirror_edges(&r, mirror)
		defer delete(edges, runtime.heap_allocator())
		if next(progress, &stage, share) do march_cells(&r, allocator)
		if next(progress, &stage, share) {
			relax(&out, pool, smooth)
			mirror_settle(&r, mirror, edges)
		}
	} else {
		// The dual: a vertex per surface patch through a cell, a quad per crossing, the
		// crossings' positions (the means the patches' vertices start from) then let go.
		if next(progress, &stage, share) {
			duals, built := dual_cells(&r, quads, allocator)
			if !built {
				// Refused (a gap thinner than a cell, Remesh_Report.quads_thin): the
				// triangles instead, which the caller sees from the quads left nil.
				march_cells(&r, allocator)
				relax(&out, pool, smooth)
			} else {
				delete(out.positions)
				out.positions = duals
				resize(&out.normals, len(duals))
			}
		}
		if quads^ != nil && next(progress, &stage, share) {
			relax_quads(&out, quads^, pool, smooth)
			out.indices = make([dynamic]u32, 6 * len(quads^), allocator)
			Split :: struct {
				out:   ^Mesh,
				quads: [][4]u32,
			}
			split := Split{&out, quads^}
			jobs.parallel_ranges(pool, len(quads^), &split, proc(data: rawptr, lo, hi: int) {
				s := cast(^Split)data
				for q in lo ..< hi {
					t := quad_split(s.out.positions[:], s.quads[q])
					copy(s.out.indices[6 * q:][:6], t[:])
				}
			}, RANGE_GRAIN)
		}
	}
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
	// Where each x ray's flips start in flip_e and flip_w: the ray's hits' first (borrowed)
	// until thin parts are kept, which lays the flips out anew (flip_owned).
	flip_first:   []u32,
	flip_owned:   bool,
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
	// The dual (dual_cells): per crossing, the four patch vertices around its lattice
	// edge by slot (the cell's side in the edge's two other axes), as slab-local numbers
	// until the slabs are laid end to end; and whether the edge's low end is inside,
	// which way the quad faces.
	corner:       []u32,
	low_in:       []bool,
}

// One slab's dual vertices (the mean of each patch's crossings) in cell order.
@(private = "file")
Dual_Slab :: struct {
	verts: [dynamic]Vec3,
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
	r.flip_first = rays.first
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

// Keeps parts thinner than a cell: a ray along any axis that goes in and out again
// between two lattice points, both outside, crosses something the lattice would lose (a
// fin, a sheet, the rim of an ear), since a point is inside only by the rays through it.
// The lattice point nearer the middle of what it crossed is put inside, joined to its
// neighbours face to face (bridge_kept) and kept unless it is a speck (drop_specks), so
// the part comes out whole and closed instead of in shreds, a cell thick on the lattice;
// its vertices then go back onto its two sides (project_thin). A ray grazing a thick part near its
// silhouette, or the edge of a box, finds such a span too; those points are left out
// (the graze test below). Blender's narrow band keeps thin parts; DynaMesh loses them.
// Appends the points it put inside to kept_at, where they are in the mesh's space (for
// project_thin); the x rays' flips are laid out anew with them
// (the new x crossings in the middles of their edges, the y and z ones beside the point:
// crossing_beside). The points are found per ray range in any order and then sorted, so
// the result does not depend on the pool.
@(private = "file")
keep_thin_parts :: proc(r: ^Remesher, kept_at: ^[dynamic]Vec3) {
	heap := runtime.heap_allocator()
	Thin :: struct {
		r:     ^Remesher,
		axis:  int,
		lock:  sync.Mutex,
		found: [dynamic]u64, // axis << 62 | x ray << 32 | x
	}
	t := Thin{r = r, found = make([dynamic]u64, 0, 256, heap)}
	defer delete(t.found)
	for axis in 0 ..< 3 {
		t.axis = axis
		rays := &r.rays[axis]
		jobs.parallel_ranges(r.pool, rays.nu * rays.nv, &t, proc(data: rawptr, lo, hi: int) {
			t := cast(^Thin)data
			r := t.r
			rays := &r.rays[t.axis]
			local := make([dynamic]u64, 0, 16, runtime.heap_allocator())
			defer delete(local)
			for ray in lo ..< hi {
				hs := rays.hits[rays.first[ray]:rays.first[ray + 1]]
				for i := 0; i < len(hs); {
					e := i32(hs[i].w)
					before: i32 = hs[i - 1].wind if i > 0 else 0
					was_in := false
					enter, leave := f32(-1), f32(-1)
					for i < len(hs) && i32(hs[i].w) == e {
						prev: i32 = hs[i - 1].wind if i > 0 else 0
						now := inside(r.op, hs[i].wind)
						if now && !inside(r.op, prev) && enter < 0 do enter = hs[i].w
						if !now && inside(r.op, prev) do leave = hs[i].w
						was_in |= now
						i += 1
					}
					if !was_in || inside(r.op, before) || inside(r.op, hs[i - 1].wind) || enter < 0 || leave < 0 do continue
					w := int(e) if 0.5 * (enter + leave) - f32(e) < 0.5 else int(e) + 1
					// The point in lattice coordinates: the ray's u and v are the next two
					// axes after its own (lattice_rays.odin).
					p: [3]int
					p[t.axis], p[(t.axis + 1) % 3], p[(t.axis + 2) % 3] = w, ray % rays.nu, ray / rays.nu
					append(&local, u64(t.axis) << 62 | u64(p[1] + r.n[1] * p[2]) << 32 | u64(p[0]))
				}
			}
			if len(local) == 0 do return
			sync.mutex_lock(&t.lock)
			append(&t.found, ..local[:])
			sync.mutex_unlock(&t.lock)
		}, 1 << 12)
	}
	if len(t.found) == 0 do return
	slice.sort(t.found[:])
	// Every point some ray found, whichever ray, to look up.
	found := make([]u64, len(t.found), heap)
	defer delete(found, heap)
	for key, i in t.found do found[i] = key & (1 << 62 - 1)
	slice.sort(found)
	found = slice.unique(found)
	// Judged on the lattice as the rays left it; a point found by several rays counts once.
	keep := make([dynamic]u64, 0, len(t.found), heap)
	defer delete(keep)
	ny := r.n[1]
	for key in t.found {
		axis := int(key >> 62)
		ray := int(key >> 32 & (1 << 30 - 1))
		p := [3]int{int(key & (1 << 32 - 1)), ray % ny, ray / ny}
		if point_inside(r, p[0], p[1], p[2]) do continue
		// A graze: a point near it across the ray (two steps either way, diagonals too,
		// for the edge of a box) is deep in something, inside with both its neighbours
		// along the ray, and the other way across is open: nothing inside and nothing
		// another ray found as thin. A fin where it meets a body has the deep body on
		// one side and more fin on the other, so it is kept.
		GRAZE_REACH :: 2
		graze := false
		b, c := (axis + 1) % 3, (axis + 2) % 3
		for db in -GRAZE_REACH ..= GRAZE_REACH {
			for dc in -GRAZE_REACH ..= GRAZE_REACH {
				if db == 0 && dc == 0 do continue
				q := p
				q[b] += db
				q[c] += dc
				front, back := q, q
				front[axis] += 1
				back[axis] -= 1
				if !point_inside(r, q[0], q[1], q[2]) || !point_inside(r, front[0], front[1], front[2]) || !point_inside(r, back[0], back[1], back[2]) do continue
				open := true
				for da in -2 ..= 2 {
					o := p
					o[b] -= db
					o[c] -= dc
					o[axis] += da
					if o[0] < 0 || o[1] < 0 || o[2] < 0 || o[0] >= r.n[0] || o[1] >= r.n[1] || o[2] >= r.n[2] do continue
					_, thin := slice.binary_search(found, u64(o[1] + ny * o[2]) << 32 | u64(o[0]))
					if thin || point_inside(r, o[0], o[1], o[2]) do open = false
				}
				if open do graze = true
			}
		}
		if !graze do append(&keep, key & (1 << 62 - 1))
	}
	if len(keep) == 0 do return
	kept := drop_specks(r, bridge_kept(r, &keep))
	if len(kept) == 0 do return
	// Each kept point x on a ray toggles insideness at x and x + 1; a flip on edge e is a
	// toggle at e + 1. Toggles that meet cancel (two kept points side by side, or a point
	// beside the part the ray already had).
	rays := &r.rays[0]
	count := rays.nu * rays.nv
	first := make([]u32, count + 1, heap)
	Toggle :: struct {
		at: i32,
		w:  f32, // where the crossing is, along the ray
	}
	toggles :: proc(r: ^Remesher, ray: int, kept: []u64, out: ^[dynamic]Toggle) {
		clear(out)
		for e, f in flips_of(r, ray) do append(out, Toggle{e + 1, r.flip_w[int(r.flip_first[ray]) + f]})
		lo, _ := slice.binary_search(kept, u64(ray) << 32)
		for k := lo; k < len(kept) && int(kept[k] >> 32) == ray; k += 1 {
			x := i32(kept[k] & (1 << 32 - 1))
			append(out, Toggle{x, f32(x) - 0.5}, Toggle{x + 1, f32(x) + 0.5})
		}
		slice.sort_by(out[:], proc(a, b: Toggle) -> bool {return a.at < b.at})
		n := 0
		for i := 0; i < len(out); {
			j := i
			for j < len(out) && out[j].at == out[i].at do j += 1
			if (j - i) & 1 == 1 {
				out[n] = out[i]
				n += 1
			}
			i = j
		}
		resize(out, n)
	}
	// Only the rays with kept points change; the rest keep their flips.
	scratch := make([dynamic]Toggle, 0, 64, heap)
	defer delete(scratch)
	changed := make([]bool, count, heap)
	defer delete(changed, heap)
	for key in kept do changed[int(key >> 32)] = true
	new_count := make([]u32, count, heap)
	for ray in 0 ..< count {
		c := r.flip_count[ray]
		if changed[ray] {
			toggles(r, ray, kept, &scratch)
			c = u32(len(scratch))
		}
		new_count[ray] = c
		first[ray + 1] = first[ray] + c
	}
	flip_e := make([]i32, first[count], heap)
	flip_w := make([]f32, first[count], heap)
	for ray in 0 ..< count {
		at := int(first[ray])
		if changed[ray] {
			toggles(r, ray, kept, &scratch)
			for g, f in scratch {
				flip_e[at + f] = g.at - 1
				flip_w[at + f] = g.w
			}
		} else {
			old := int(r.flip_first[ray])
			copy(flip_e[at:][:r.flip_count[ray]], r.flip_e[old:][:r.flip_count[ray]])
			copy(flip_w[at:][:r.flip_count[ray]], r.flip_w[old:][:r.flip_count[ray]])
		}
	}
	delete(r.flip_e, heap)
	delete(r.flip_w, heap)
	delete(r.flip_count, heap)
	if r.flip_owned do delete(r.flip_first, heap)
	r.flip_e, r.flip_w, r.flip_count, r.flip_first, r.flip_owned = flip_e, flip_w, new_count, first, true
	for key in kept {
		ray := int(key >> 32)
		append(kept_at, r.origin + r.h * Vec3{f32(key & (1 << 32 - 1)), f32(ray % ny), f32(ray / ny)})
	}
}

// A thin part kept one point thick steps from point to point diagonally where it is
// turned off the axes, and points that touch only along an edge or at a corner come out
// as separate pieces. Where a kept point and an inside or kept one are diagonal with
// neither of the points between them inside, the first of those (by axis) is put inside
// too, so the part is joined face to face. Sorts and dedupes keep; returns the points.
@(private = "file")
bridge_kept :: proc(r: ^Remesher, keep: ^[dynamic]u64) -> []u64 {
	ny := r.n[1]
	at :: proc(r: ^Remesher, p: [3]int) -> u64 {return u64(p[1] + r.n[1] * p[2]) << 32 | u64(p[0])}
	occupied :: proc(r: ^Remesher, kept: []u64, p: [3]int) -> bool {
		if p[0] < 0 || p[1] < 0 || p[2] < 0 || p[0] >= r.n[0] || p[1] >= r.n[1] || p[2] >= r.n[2] do return false
		if point_inside(r, p[0], p[1], p[2]) do return true
		_, found := slice.binary_search(kept, at(r, p))
		return found
	}
	for _ in 0 ..< 2 {
		slice.sort(keep[:])
		kept := slice.unique(keep[:])
		resize(keep, len(kept))
		added := 0
		for key in kept {
			ray := int(key >> 32)
			p := [3]int{int(key & (1 << 32 - 1)), ray % ny, ray / ny}
			for u in 0 ..< 3 {
				for su in ([2]int{1, -1}) {
					pu := p
					pu[u] += su
					if occupied(r, kept, pu) do continue
					for v in 0 ..< 3 {
						if v == u do continue
						for sv in ([2]int{1, -1}) {
							pv, puv := p, pu
							pv[v] += sv
							puv[v] += sv
							if !occupied(r, kept, puv) || occupied(r, kept, pv) do continue
							// Both ways round find this pair; the lower axis puts the point in.
							if u > v do continue
							if pu[0] < 0 || pu[1] < 0 || pu[2] < 0 || pu[0] >= r.n[0] || pu[1] >= r.n[1] || pu[2] >= r.n[2] do continue
							append(keep, at(r, pu))
							added += 1
						}
					}
				}
			}
		}
		if added == 0 do break
	}
	slice.sort(keep[:])
	return slice.unique(keep[:])
}

// Kept points that only touch each other in a handful, not the lattice's inside, are the
// tip of a cone or a spike sliced thinner than a cell: kept, they would float beside it as
// specks. A group of kept points joined face to face survives when it touches the
// lattice's inside or is big enough to be a part of its own (a leaf, a sheet).
@(private = "file")
drop_specks :: proc(r: ^Remesher, kept: []u64) -> []u64 {
	SPECK :: 8 // a group this many points or more is a part of its own
	heap := runtime.heap_allocator()
	parent := make([]int, len(kept), heap)
	defer delete(parent, heap)
	size := make([]int, len(kept), heap)
	defer delete(size, heap)
	touches := make([]bool, len(kept), heap)
	defer delete(touches, heap)
	for i in 0 ..< len(kept) do parent[i], size[i] = i, 1
	root :: proc(parent: []int, i: int) -> int {
		i := i
		for parent[i] != i {
			parent[i] = parent[parent[i]]
			i = parent[i]
		}
		return i
	}
	ny := r.n[1]
	for key, i in kept {
		ray := int(key >> 32)
		p := [3]int{int(key & (1 << 32 - 1)), ray % ny, ray / ny}
		for axis in 0 ..< 3 {
			for d in ([2]int{1, -1}) {
				q := p
				q[axis] += d
				if q[axis] < 0 || q[axis] >= r.n[axis] do continue
				if point_inside(r, q[0], q[1], q[2]) {
					touches[i] = true
					continue
				}
				j, found := slice.binary_search(kept, u64(q[1] + ny * q[2]) << 32 | u64(q[0]))
				if !found do continue
				a, b := root(parent, i), root(parent, j)
				if a == b do continue
				// The lower index becomes the root, so the groups do not depend on order.
				if b < a do a, b = b, a
				parent[b] = a
				size[a] += size[b]
			}
		}
	}
	for i in 0 ..< len(kept) {
		a := root(parent, i)
		if touches[i] do touches[a] = true
	}
	n := 0
	for key, i in kept {
		a := root(parent, i)
		if touches[a] || size[a] >= SPECK {
			kept[n] = key
			n += 1
		}
	}
	return kept[:n]
}

@(private = "file")
flips_of :: #force_inline proc(r: ^Remesher, ray: int) -> []i32 {
	first := r.flip_first[ray]
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
crossing_on :: proc(rays: ^Lattice_Rays, op: Remesh_Op, ray: int, lo: int) -> (w: f32, found: bool) {
	hs := rays.hits[rays.first[ray]:rays.first[ray + 1]]
	at := f32(lo) + 0.5
	i, _ := slice.binary_search_by(hs, f32(lo), proc(h: Lattice_Hit, w: f32) -> slice.Ordering {return .Less if h.w < w else .Greater})
	for ; i < len(hs) && hs[i].w < f32(lo + 1); i += 1 {
		prev: i32 = hs[i - 1].wind if i > 0 else 0
		if inside(op, prev) != inside(op, hs[i].wind) {
			at = hs[i].w
			found = true
		}
	}
	return clamp(at, f32(lo) + EDGE_MARGIN, f32(lo) + 1 - EDGE_MARGIN), found
}

// Where a strip's crossing goes when its own ray saw none on that edge (the x rays and
// it disagree, or a thin part was kept there): beside the inside end, which lies near the
// surface the x rays saw, rather than in the middle of the edge where nothing is.
@(private = "file")
crossing_beside :: #force_inline proc(lo_inside: bool, lo: int) -> f32 {
	return f32(lo) + (THIN_HUG if lo_inside else 1 - THIN_HUG)
}

// How near its inside end such a crossing goes, in lattice steps: near, since the
// surface the x rays saw passes near that point, so a kept thin part starts within a
// cell of its two sides, where project_thin reaches, and not on it, so relaxing has room.
THIN_HUG :: 0.1

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

// Each vertex's lattice edge as a key, for mirror_settle: the axis it runs along and its
// lower lattice point, read from where place_vertices put the vertex (on the edge, its
// other two coordinates whole). Vertices are laid out x edges, then y, then z
// (count_vertices). Nil without a mirror; heap memory.
@(private = "file")
mirror_edges :: proc(r: ^Remesher, mirror: Remesh_Mirror) -> []u64 {
	if mirror.axes == {} do return nil
	keys := make([]u64, r.vertex_count, runtime.heap_allocator())
	for &key, v in keys {
		along := 0 if u32(v) < r.y_base[0] else 1 if u32(v) < r.z_base[0] else 2
		u := (r.out.positions[v] - r.origin) / r.h
		lower: [3]i64
		for a in 0 ..< 3 do lower[a] = i64(math.floor(u[a])) if a == along else i64(math.round(u[a]))
		key = mirror_key(along, lower)
	}
	return keys
}

// An edge's key: its axis in the top bits, then its lower point's coordinates, each well
// under 2^20 (REMESH_MAX_LATTICE); max(u64) for a point off the lattice.
@(private = "file")
mirror_key :: proc(along: int, lower: [3]i64) -> u64 {
	for c in lower do if c < 0 || c >= 1 << 20 do return max(u64)
	return u64(along) << 60 | u64(lower[0]) << 40 | u64(lower[1]) << 20 | u64(lower[2])
}

// Makes the relaxed triangles exactly as symmetric as the lattice: marching cubes cuts a
// cell and its mirror image along diagonals that need not mirror each other, so the relax
// moves the two halves a little differently. Each vertex becomes the mean of itself and
// the mirror images of the vertices on its edge's mirror images (the plane's own edges
// mirror onto themselves), which a symmetric mesh has; a vertex whose image edge has none
// (the sculpt not symmetric there) keeps the images it has. Normals likewise.
@(private = "file")
mirror_settle :: proc(r: ^Remesher, mirror: Remesh_Mirror, keys: []u64) {
	if keys == nil do return
	Settle :: struct {
		r:        ^Remesher,
		mirror:   Remesh_Mirror,
		keys:     []u64,
		at:       map[u64]u32,
		twice:    [3]i64, // twice the plane's place in lattice steps, a whole (odd) number
		pos, nrm: []Vec3,
	}
	heap := runtime.heap_allocator()
	s := Settle{r = r, mirror = mirror, keys = keys}
	s.at = make(map[u64]u32, len(keys), heap)
	defer delete(s.at)
	for key, v in keys do if key != max(u64) do s.at[key] = u32(v)
	for a in 0 ..< 3 do s.twice[a] = i64(math.round(2 * (mirror.center[a] - r.origin[a]) / r.h))
	s.pos = make([]Vec3, len(keys), heap)
	s.nrm = make([]Vec3, len(keys), heap)
	defer delete(s.pos, heap)
	defer delete(s.nrm, heap)
	jobs.parallel_ranges(r.pool, len(keys), &s, proc(data: rawptr, lo, hi: int) {
		s := cast(^Settle)data
		out := s.r.out
		for v in lo ..< hi {
			key := s.keys[v]
			p, n := out.positions[v], out.normals[v]
			count: f32 = 1
			if key != max(u64) {
				along := int(key >> 60)
				lower := [3]i64{i64(key >> 40 & (1 << 20 - 1)), i64(key >> 20 & (1 << 20 - 1)), i64(key & (1 << 20 - 1))}
				// Every non-empty set of the mirror's planes, as bits over x, y and z.
				for set in 1 ..< 8 {
					image := lower
					usable := true
					for a in 0 ..< 3 do if set & (1 << uint(a)) != 0 {
						if !s.mirror.axes[a] do usable = false
						image[a] = s.twice[a] - lower[a] - (1 if a == along else 0)
					}
					if !usable do continue
					w, found := s.at[mirror_key(along, image)]
					if !found do continue
					q, m := out.positions[w], out.normals[w]
					for a in 0 ..< 3 do if set & (1 << uint(a)) != 0 {
						q[a] = 2 * s.mirror.center[a] - q[a]
						m[a] = -m[a]
					}
					p += q
					n += m
					count += 1
				}
			}
			s.pos[v] = p / count
			s.nrm[v] = linalg.normalize0(n)
		}
	}, RANGE_GRAIN)
	copy(r.out.positions[:], s.pos)
	copy(r.out.normals[:], s.nrm)
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
				first := r.flip_first[ray]
				for f in 0 ..< int(r.flip_count[ray]) {
					r.out.positions[int(r.x_base[ray]) + f] = r.origin + r.h * Vec3{r.flip_w[int(first) + f], f32(j), f32(k)}
				}
				if j + 1 < ny {
					s := Strip{r, j, k, r.y_base[j + (ny - 1) * k]}
					each_disagreement(flips_of(r, ray), flips_of(r, ray + 1), &s, proc(data: rawptr, i, rank: int) {
						s := cast(^Strip)data
						r := s.r
						// The y ray through x = i, z = k.
						w, found := crossing_on(&r.rays[1], r.op, s.k + r.n[2] * i, s.j)
						if !found do w = crossing_beside(point_inside(r, i, s.j, s.k), s.j)
						r.out.positions[int(s.base) + rank] = r.origin + r.h * Vec3{f32(i), w, f32(s.k)}
					})
				}
				if k + 1 < nz {
					s := Strip{r, j, k, r.z_base[ray]}
					each_disagreement(flips_of(r, ray), flips_of(r, ray + ny), &s, proc(data: rawptr, i, rank: int) {
						s := cast(^Strip)data
						r := s.r
						// The z ray through x = i, y = j.
						w, found := crossing_on(&r.rays[2], r.op, i + r.n[0] * s.j, s.k)
						if !found do w = crossing_beside(point_inside(r, i, s.j, s.k), s.k)
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
march_column :: proc(r: ^Remesher, j, k: int, out: ^[dynamic]u32, dual: ^Dual_Slab = nil) {
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
	cell :: proc(r: ^Remesher, i: i32, j, k: int, flips: ^[4][]i32, ptr: ^[4]int, rays: [4]int, strip_base: [4]u32, strip_rank: ^[4]u32, last_point: ^i32, ids_next: ^[4]i32, out: ^[dynamic]u32, dual: ^Dual_Slab) {
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
		// The case's loops from the table, or traced here where a face pairs the other
		// way round (cell_flips, seldom).
		cl := &mc_cells[mc_case]
		turned: Cell_Loops
		if cl.faces != 0 {
			if flips := cell_flips(r, mc_case, int(i), j, k); flips != 0 {
				turned = mc_case_loops(int(mc_case), flips)
				cl = &turned
			}
		}
		if dual != nil {
			// A vertex per loop of the case (a patch through the cell), at the mean of its
			// crossings, and that vertex as the corner each of those crossings' quads
			// takes from this cell.
			for l in 0 ..< int(cl.count) {
				loop := cl.edges[cl.first[l]:cl.first[l + 1]]
				double := cl.double[l]
				mean: Vec3
				for e in loop {
					assert(edge[e] >= 0, "marching cubes edge without a vertex")
					mean += r.out.positions[edge[e]]
				}
				local := u32(len(dual.verts))
				assert(local < DUAL_FLAGS, "more patches in a slab than the corner word holds")
				append(&dual.verts, mean / f32(len(loop)))
				for e in loop {
					// The cell is on the high side of the edge's other axes where the
					// edge runs along its low faces (idx bits clear).
					idx := e & 3
					hi1, hi2 := idx & 1 == 0, idx >> 1 == 0
					slot := 0 if !hi1 && !hi2 else (1 if hi1 && !hi2 else (2 if hi1 && hi2 else 3))
					// Above the vertex number, whether this patch crosses twice the face
					// along the edge's first other axis (bit 0) and its second (bit 1),
					// the faces the cell shares with the slots beside this one.
					axis := e >> 2
					o1, o2 := (axis + 1) % 3, (axis + 2) % 3
					if o1 > o2 do o1, o2 = o2, o1
					flags := u32(double >> uint(2 * o1 + (idx & 1)) & 1) | u32(double >> uint(2 * o2 + (idx >> 1)) & 1) << 1
					q := int(edge[e])
					r.corner[4 * q + slot] = local | flags * DUAL_FLAGS
					if slot == 0 do r.low_in[q] = (mc_case >> mc_edge_corner0[e]) & 1 == 1
				}
			}
			return
		}
		tris := cl.tris[:3 * int(cl.tri_count)]
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
			for i in start ..< end - 1 do cell(r, i, j, k, &flips, &ptr, rays, strip_base, &strip_rank, &last_point, &ids_next, out, dual)
		}
		if end < n0 && end - 1 >= 0 do cell(r, end - 1, j, k, &flips, &ptr, rays, strip_base, &strip_rank, &last_point, &ids_next, out, dual)
		start = end
	}
}

// Marching cubes for one cell: the loops its crossing edges form (each a patch of the
// surface through the cell, for the dual) and the triangles those loops fan into. Cell
// edges are numbered a * 4 + idx: along axis a from the corner whose other two coordinates
// are the bits of idx (lower axis first); corner c sits at (c & 1, c >> 1 & 1, c >> 2 & 1)
// and is inside when bit c of the case is set. Loop l is the edges
// edges[first[l]:first[l + 1]], in the fan's order; double[l] has a bit per cell face
// (axis * 2 + side) the loop crosses twice, taking both of the face's segments; tris are
// three edge numbers a triangle, facing outward.
@(private)
Cell_Loops :: struct {
	count:     u8,
	first:     [5]u8,
	edges:     [12]u8,
	double:    [4]u8,
	tri_count: u8,
	tris:      [30]u8,
	// Every face some loop crosses twice (the loops' double together): where the cell
	// across such a face has one too, the face's pairing is turned (cell_flips).
	faces:     u8,
}

// The 256 cases under the plain rule (no face turned), built once.
@(private)
mc_cells: [256]Cell_Loops
// Each cell edge's low corner, whose insideness says which way its crossing's quad faces.
@(private = "file")
mc_edge_corner0: [12]u8

// The dual's corner words hold the slab-local vertex number below this and the two
// double-face flags above it.
@(private = "file")
DUAL_FLAGS :: u32(1) << 30

@(private)
mc_once: sync.Once

@(private)
mc_build_table :: proc() {
	for e in 0 ..< 12 do mc_edge_corner0[e] = mc_edge_corners(e)[0]
	for mc_case in 0 ..< 256 do mc_cells[mc_case] = mc_case_loops(mc_case, 0)
}

// The two corners of cell edge e, the low one first.
@(private = "file")
mc_edge_corners :: proc(e: int) -> [2]u8 {
	a, idx := e >> 2, e & 3
	o1, o2 := (a + 1) % 3, (a + 2) % 3
	if o1 > o2 do o1, o2 = o2, o1
	c0 := u8((idx & 1) << uint(o1) | (idx >> 1) << uint(o2))
	return {c0, c0 | 1 << uint(a)}
}

// One cell's loops and triangles from one rule rather than a table by hand: on each cube
// face, the surface joins the face's crossing edges in pairs, and runs clockwise around
// the inside seen from outside the cube. A face with four crossings (its inside corners
// on one diagonal, its outside ones on the other) is paired at each inside corner,
// keeping the inside corners apart and joining the outside ones across the face; with the
// face's bit set in `flips` the other way round, pairing at each outside corner. Both
// cells on a face pair it the same way (cell_flips decides from both), so the surface is
// closed and manifold. Each cell's crossing edges then form loops, each fanned into
// triangles from a crossing off the faces the loop crosses twice when it has one (so the
// fans of the two cells on such a face never share a diagonal).
@(private)
mc_case_loops :: proc(mc_case: int, flips: u8) -> (cl: Cell_Loops) {
	edges: [12][2]u8
	for e in 0 ..< 12 do edges[e] = mc_edge_corners(e)
	corner_pos :: proc(c: u8) -> [3]f32 {return {f32(c & 1), f32(c >> 1 & 1), f32(c >> 2 & 1)}}
	inside :: proc(mc_case: int, c: u8) -> bool {return (mc_case >> c) & 1 == 1}
	next: [12]i8
	for &x in next do x = -1
	// The segment from e1 to e2 on the face with `normal`, turned so the inside end of e1
	// (which is on the segment's inside side under either pairing) is on its right.
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
			// Pair the two edges at each inside corner, or with the face turned at each
			// outside corner.
			at_inside := flips >> u8(2 * a + side) & 1 == 0
			for c in 0 ..< u8(8) {
				if !on_face(c, a, side) || inside(mc_case, c) != at_inside do continue
				pair: [dynamic; 2]int
				for e in crossing do if edges[e][0] == c || edges[e][1] == c do append(&pair, e)
				segment(edges, mc_case, &next, pair[0], pair[1], normal)
			}
		}
	}
	seen: [12]bool
	loop_edges := 0
	for start in 0 ..< 12 {
		if next[start] < 0 || seen[start] do continue
		loop: [dynamic; 12]int
		for e := start; !seen[e]; e = int(next[e]) {
			seen[e] = true
			append(&loop, e)
			assert(next[e] >= 0, "open marching cubes loop")
		}
		l := int(cl.count)
		// The two faces each edge lies on: along its other axes, on the side its index
		// bits give. Four of the loop's edges on one face is both of its segments.
		on_face: [6]u8
		for e in loop {
			a := e >> 2
			o1, o2 := (a + 1) % 3, (a + 2) % 3
			if o1 > o2 do o1, o2 = o2, o1
			on_face[2 * o1 + (e & 1)] += 1
			on_face[2 * o2 + (e >> 1 & 1)] += 1
		}
		for n, f in on_face do if n == 4 do cl.double[l] |= 1 << u8(f)
		cl.faces |= cl.double[l]
		// The fan's apex: the first edge off every doubled face, else the first.
		apex := 0
		for e, i in loop {
			a := e >> 2
			o1, o2 := (a + 1) % 3, (a + 2) % 3
			if o1 > o2 do o1, o2 = o2, o1
			if cl.double[l] >> u8(2 * o1 + (e & 1)) & 1 == 0 && cl.double[l] >> u8(2 * o2 + (e >> 1 & 1)) & 1 == 0 {
				apex = i
				break
			}
		}
		cl.first[l] = u8(loop_edges)
		for i in 0 ..< len(loop) {
			cl.edges[loop_edges] = u8(loop[(apex + i) % len(loop)])
			loop_edges += 1
		}
		cl.count += 1
		cl.first[cl.count] = u8(loop_edges)
		for t in 1 ..< len(loop) - 1 {
			cl.tris[3 * cl.tri_count + 0] = cl.edges[int(cl.first[l])]
			cl.tris[3 * cl.tri_count + 1] = cl.edges[int(cl.first[l]) + t]
			cl.tris[3 * cl.tri_count + 2] = cl.edges[int(cl.first[l]) + t + 1]
			cl.tri_count += 1
		}
	}
	return
}

// Whether lattice point i on x ray (j, k) is inside: an even number of flips before it;
// outside the lattice, outside.
@(private = "file")
point_inside :: proc(r: ^Remesher, i, j, k: int) -> bool {
	if i < 0 || j < 0 || k < 0 || i >= r.n[0] || j >= r.n[1] || k >= r.n[2] do return false
	flips := flips_of(r, j + r.n[1] * k)
	before, _ := slice.binary_search(flips, i32(i))
	return before & 1 == 1
}

// The marching cubes case of the cell whose low corner is lattice point (i, j, k).
@(private = "file")
cell_case :: proc(r: ^Remesher, i, j, k: int) -> (mc_case: u8) {
	for c in 0 ..< 8 {
		if point_inside(r, i + c & 1, j + c >> 1 & 1, k + c >> 2 & 1) do mc_case |= 1 << u8(c)
	}
	return
}

// The faces of the cell at (i, j, k) with case `mc_case` to pair the other way round
// (mc_case_loops): those one of its loops crosses twice where the cell across the face
// has such a loop too. Under the plain pairing the two loops would share both segments
// of the face, a tube of air (or matter) pinched flat, whose triangles' diagonals and
// whose dual edge would carry four faces: a gap thinner than a cell slipping diagonally
// between lattice points. Turned, each cell keeps two pockets apart instead, which
// closes the gap as a gap narrower than a cell closes anywhere else. Both cells read the
// same two cases, so they agree.
@(private = "file")
cell_flips :: proc(r: ^Remesher, mc_case: u8, i, j, k: int) -> (flips: u8) {
	faces := mc_cells[mc_case].faces
	if faces == 0 do return 0
	for f in 0 ..< 6 {
		if faces >> u8(f) & 1 == 0 do continue
		axis, side := f / 2, f % 2
		at := [3]int{i, j, k}
		at[axis] += 1 if side == 1 else -1
		across := mc_cells[cell_case(r, at[0], at[1], at[2])].faces
		if across >> u8(2 * axis + 1 - side) & 1 == 1 do flips |= 1 << u8(f)
	}
	return
}

// The largest index i with base[i] <= q, in a prefix-sum table: the ray or strip whose
// crossings q is among.
@(private = "file")
upper_index :: proc(base: []u32, q: u32) -> int {
	lo, hi := 0, len(base) - 1
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if base[mid] <= q do lo = mid
		else do hi = mid - 1
	}
	return lo
}

// The dual of the marching cubes over the crossings place_vertices positioned: one
// vertex per patch through a cell (the mean of the patch's crossings) and one quad per
// crossing, over the four patches around its lattice edge, facing outward. Each cell's
// crossings each lie in exactly one of its patches, a patch's crossings run around it in
// one cycle, and a quad edge is a face edge of the marching cubes shared by its two
// cells, so the quads are a closed manifold with four corners each, also across the
// faces whose four crossings plain surface nets would join at one vertex. Slab by slab in
// parallel, in cell order, the slabs then laid end to end, so the result is the same on
// any thread count. False, refusing the dual, where two patches across a face both cross
// it twice (their edge would carry four quads: a gap thinner than a cell, slipping
// diagonally between lattice points, which no vertex per patch can thread), or when a
// quad lacks a corner, which a closed marching cubes never leaves.
@(private = "file")
dual_cells :: proc(r: ^Remesher, quads: ^[][4]u32, allocator: runtime.Allocator) -> (positions: [dynamic]Vec3, ok: bool) {
	heap := runtime.heap_allocator()
	crossings := r.vertex_count
	r.corner = make([]u32, 4 * crossings, heap)
	defer delete(r.corner, heap)
	slice.fill(r.corner, max(u32))
	r.low_in = make([]bool, crossings, heap)
	defer delete(r.low_in, heap)
	slabs := make([]Dual_Slab, r.n[2] - 1, context.temp_allocator)
	defer for &s in slabs do delete(s.verts)
	Walk :: struct {
		r:     ^Remesher,
		slabs: []Dual_Slab,
		base:  []u32, // per slab, its first vertex number in the result
		quads: [][4]u32,
		out:   []Vec3,
		bad:   bool, // a quad without a corner, or an edge four quads share (atomic)
	}
	w := Walk{r = r, slabs = slabs}
	jobs.parallel_for(r.pool, len(slabs), &w, proc(data: rawptr, k: int) {
		w := cast(^Walk)data
		w.slabs[k].verts = make([dynamic]Vec3, 0, 1024, runtime.heap_allocator())
		for j in 0 ..< w.r.n[1] - 1 do march_column(w.r, j, k, nil, &w.slabs[k])
	})
	w.base = make([]u32, len(slabs) + 1, context.temp_allocator)
	for s, k in slabs do w.base[k + 1] = w.base[k] + u32(len(s.verts))
	positions = make([dynamic]Vec3, int(w.base[len(slabs)]), allocator)
	w.out = positions[:]
	jobs.parallel_for(r.pool, len(slabs), &w, proc(data: rawptr, k: int) {
		w := cast(^Walk)data
		copy(w.out[w.base[k]:], w.slabs[k].verts[:])
	})
	quads^ = make([][4]u32, crossings, allocator)
	w.quads = quads^
	jobs.parallel_ranges(r.pool, crossings, &w, proc(data: rawptr, lo, hi: int) {
		w := cast(^Walk)data
		r := w.r
		ny := r.n[1]
		for q in lo ..< hi {
			// The crossing's axis and the slab of the cells on the low side of its edge's
			// last axis (the high side's is the next slab); a z edge's four cells are all
			// in its own slab.
			qu := u32(q)
			axis, slab := 0, 0
			switch {
			case qu < r.y_base[0]:
				axis, slab = 0, upper_index(r.x_base, qu) / ny
			case qu < r.z_base[0]:
				axis, slab = 1, upper_index(r.y_base, qu) / (ny - 1)
			case:
				axis, slab = 2, upper_index(r.z_base, qu) / ny
			}
			c, flags: [4]u32
			for slot in 0 ..< 4 {
				word := r.corner[4 * q + slot]
				in_slab := slab if axis == 2 || slot >= 2 else slab - 1
				if word == max(u32) || in_slab < 0 {
					sync.atomic_store(&w.bad, true)
					return
				}
				c[slot] = w.base[in_slab] + word % DUAL_FLAGS
				flags[slot] = word / DUAL_FLAGS
			}
			// Slots beside each other share the face along the edge's first other axis
			// (0 with 1, 2 with 3) or its second (1 with 2, 3 with 0); both patches
			// crossing it twice is the doubled edge.
			if (flags[0] & flags[1] | flags[2] & flags[3]) & 1 != 0 || (flags[1] & flags[2] | flags[3] & flags[0]) & 2 != 0 {
				sync.atomic_store(&w.bad, true)
				return
			}
			// The slots run around the edge with the right hand along +axis for x and z,
			// against it for y; the quad faces the outside, which is +axis when the
			// edge's low end is inside.
			forward := (axis != 1) == r.low_in[q]
			w.quads[q] = {c[0], c[1], c[2], c[3]} if forward else {c[0], c[3], c[2], c[1]}
		}
	}, RANGE_GRAIN)
	if sync.atomic_load(&w.bad) {
		delete(positions)
		delete(quads^, allocator)
		quads^ = nil
		return {}, false
	}
	return positions, true
}

// relax for a mesh of quads (the dual's), over `rounds`: each vertex moves part of the
// way toward the mean of its neighbours along the quads' edges, along the surface only
// (the normal from its quads' diagonals), reading one buffer and writing the other; the
// last pass moves nothing and leaves the normals current. Each vertex's quads are listed
// in quad order, so the result is the same on any thread count.
@(private = "file")
relax_quads :: proc(m: ^Mesh, quads: [][4]u32, pool: ^jobs.Pool, rounds: int) {
	n := len(m.positions)
	heap := runtime.heap_allocator()
	offsets := make([]u32, n + 1, heap)
	defer delete(offsets, heap)
	for f in quads do for v in f do offsets[v + 1] += 1
	for v in 0 ..< n do offsets[v + 1] += offsets[v]
	list := make([]u32, 4 * len(quads), heap)
	defer delete(list, heap)
	fill := make([]u32, n, heap)
	defer delete(fill, heap)
	for f, q in quads do for v in f {
		list[offsets[v] + fill[v]] = u32(q)
		fill[v] += 1
	}
	Relax :: struct {
		m:        ^Mesh,
		quads:    [][4]u32,
		offsets:  []u32,
		list:     []u32,
		from, to: []Vec3,
		rate:     f32,
	}
	x := Relax{m = m, quads = quads, offsets = offsets, list = list, from = m.positions[:]}
	x.to = make([]Vec3, n, context.temp_allocator)
	for round in 0 ..= rounds {
		x.rate = RELAX_RATE if round < rounds else 0
		jobs.parallel_ranges(pool, n, &x, proc(data: rawptr, lo, hi: int) {
			x := cast(^Relax)data
			m := x.m
			for v in lo ..< hi {
				centre, normal: Vec3
				count := 0
				for q in x.list[x.offsets[v]:x.offsets[v + 1]] {
					f := x.quads[q]
					p0, p1, p2, p3 := x.from[f[0]], x.from[f[1]], x.from[f[2]], x.from[f[3]]
					normal += linalg.cross(p2 - p0, p3 - p1)
					for c in 0 ..< 4 do if int(f[c]) == v {
						centre += x.from[f[(c + 1) % 4]] + x.from[f[(c + 3) % 4]]
						count += 2
						break
					}
				}
				nrm := linalg.normalize0(normal)
				p := x.from[v]
				if x.rate == 0 {
					m.normals[v] = nrm
					x.to[v] = p
					continue
				}
				step := centre / f32(max(count, 1)) - p
				step -= nrm * linalg.dot(step, nrm)
				x.to[v] = p + step * x.rate
			}
		}, RANGE_GRAIN)
		x.from, x.to = x.to, x.from
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

@(private = "file")
GRAZE_REACH := 3
