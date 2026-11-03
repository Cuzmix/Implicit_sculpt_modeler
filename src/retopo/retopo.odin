package retopo

import "core:fmt"
import "core:log"
import "core:math"
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
	adaptivity:  f32, // Adaptive size: 0 quads of one size, 1 smaller ones where the surface bends and larger where it is flat, at the same count (AutoRemesher)
	// Keep symmetry: the planes the result is its own mirror image across (the brush's
	// symmetry, through the centre its dabs mirror about), none for a whole remesh. The
	// part on the + side of every plane is remeshed alone and mirrored, so the halves
	// match quad for quad along the seam, with either engine.
	mirror:      geom.Remesh_Mirror,
	close_first: bool, // an open or unsound mesh is voxel remeshed first, whichever engine runs
	// AutoRemesher's feature edges, as ZRemesher's KeepGroups and KeepCreases: the
	// borders between the polygroups and the creased edges of `Source` are kept as quad
	// edges, so the loops run along them; and an edge whose faces meet sharper than
	// `edge_degrees` is kept too (90, or 0 for it, keeps right angles and sharper, as
	// before; lower keeps softer edges). The built-in engine knows none of the three.
	keep_groups:  bool,
	keep_creases: bool,
	edge_degrees: f32,
	// AutoRemesher's density, as ZRemesher's Use PolyPaint: `Source.paint` red asks up to
	// four times the quads per area, blue a quarter, white, grey and green leave it be;
	// `Source.mask` asks up to twice as many where masked. The count stays what was asked
	// (vertex_density).
	use_paint: bool,
	use_mask:  bool,
	// AutoRemesher's guides, as ZRemesher's Curves Strength: how hard `Source.guides` pull
	// the quads' edges to run along them, 0 not at all to 1 as closely as the field can
	// follow (GUIDE_STRENGTH_DEFAULT, half, as ZRemesher's).
	guide_strength: f32,
}

GUIDE_STRENGTH_DEFAULT :: f32(0.5)

// What the input carries that the options may keep: per triangle its polygroup, the
// creased edges as sculpt.sharp_key keys of the input's vertices, per vertex its paint
// and its mask, and the guide curves drawn on it as polylines in its own space (a closed
// curve ending where it starts). Any nil for none. The caller owns them; compute reads
// them only.
Source :: struct {
	groups:  []u16,
	creases: []u64,
	paint:   []sculpt.Color,
	mask:    []u8,
	guides:  [][]geom.Vec3,
}

// The density per vertex of `n` that Use paint and Use mask ask for (quads per area
// relative to the rest, quadmesh.Params.density), or nil when neither gives anything:
// paint 4^(coverage × (redness − blueness)), redness the red past the larger of green and
// blue (blueness likewise), so pure red is 4, pure blue a quarter and white, grey or green
// 1, as ZBrush reads polypaint; times 2^mask.
vertex_density :: proc(n: int, paint: []sculpt.Color, mask: []u8, allocator := context.allocator) -> []f32 {
	paint := paint if len(paint) == n else nil
	mask := mask if len(mask) == n else nil
	if paint == nil && mask == nil do return nil
	density := make([]f32, n, allocator)
	for &d, v in density {
		exponent: f32
		if paint != nil {
			c := paint[v]
			r, g, b := f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255
			redness, blueness := max(r - max(g, b), 0), max(b - max(r, g), 0)
			exponent = 2 * f32(c.a) / 255 * (redness - blueness)
		}
		if mask != nil do exponent += f32(mask[v]) / 255
		d = math.pow(2, exponent)
	}
	return density
}

// The density of `from` (per vertex) at each vertex of `to`, read off the nearest point of
// `from`'s surface: for a surface rebuilt where the old one lay (Close first). Parallel
// over `to`'s vertices; the same result for any thread count.
@(private = "file")
density_resample :: proc(from: geom.Mesh, density: []f32, to: geom.Mesh, pool: ^jobs.Pool) -> []f32 {
	out := make([]f32, len(to.positions))
	bvh := geom.bvh_build_morton(from, geom.BVH_LEAF_SIZE, pool)
	defer geom.bvh_destroy(&bvh)
	Job :: struct {
		from:    geom.Mesh,
		bvh:     ^geom.Bvh,
		density: []f32,
		to:      geom.Mesh,
		out:     []f32,
	}
	job := Job{from, &bvh, density, to, out}
	jobs.parallel_ranges(pool, len(to.positions), &job, proc(data: rawptr, lo, hi: int) {
		j := (^Job)(data)
		hint := geom.BVH_NONE
		for v in lo ..< hi {
			tri, bary, _, ok := geom.bvh_closest(j.bvh^, j.from, j.to.positions[v], max(f32), hint)
			if !ok {
				j.out[v] = 1
				continue
			}
			hint = tri
			i := j.from.indices[3 * tri:][:3]
			j.out[v] = bary[0] * j.density[i[0]] + bary[1] * j.density[i[1]] + bary[2] * j.density[i[2]]
		}
	}, 4096)
	return out
}

// The edge angle `Options.edge_degrees` 0 stands for.
EDGE_DEGREES_DEFAULT :: f32(90)

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
	features:  int, // AutoRemesher: polygroup borders and creased edges handed to it as feature edges
	guides:    int, // AutoRemesher: guide curves that came within a quad's width of the surface
	mirrored:  bool, // one part remeshed and mirrored, as the symmetry asked...
	mirror:    geom.Remesh_Mirror, // ...across these planes
	unmirrored: string, // symmetry asked but not kept: why (a literal, not owned)
	unkept:    string, // feature edges handed over but remeshed without them in the end: why (a literal, not owned)
	reason:    string, // owned: why AutoRemesher was not used, "" when it was
	built:     bool,
	retopo_ms: f64,
	uv_ms:     f64,
}

// The quads of about `quads` on `view` (with normals) by the engine and options, their
// UVs and triangles; touches no object or interface, so a long job runs it on its own
// thread with its own pool, and with `progress` it stops after a cancel, built false with
// nothing to free. AutoRemesher gives way to the own engine when it is not built or
// refuses the mesh, and `reason` then says why; the own engine knows no adaptivity and
// no feature edges (`source`, per triangle and vertex of `view`), but Close first and
// symmetry serve it too.
compute :: proc(view: geom.Mesh, quads: int, options: Options, pool: ^jobs.Pool, progress: ^jobs.Progress = nil, source := Source{}) -> (r: Result) {
	start := time.tick_now()
	from: f32 = 0
	closed: geom.Mesh
	defer geom.mesh_destroy(&closed)
	input := view
	if options.engine == .Auto {
		outcome: Quad_Outcome
		r, outcome = quad_remesh_compute(view, quads, options, pool, progress, source)
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

// The density of each vertex of the half (vertex_density) from the vertex it came from;
// a cap's vertices, which come from none, take the half's lowest. The cap's polygons are
// dropped, and a cap denser than the surface along its rim starves the dense parts: on a
// sphere painted four times as dense above, cut in half, the upper part got 1.8 times
// the quads of the lower with a cap at the mean density and 2.9 times with it at the
// lowest; lower still, the parts below the rim gain instead. Nil for no density.
@(private = "file")
half_densities :: proc(half: geom.Mesh, origins: geom.Slice_From, density: []f32) -> []f32 {
	if density == nil || len(origins.vertex) != len(half.positions) do return nil
	out := make([]f32, len(half.positions))
	lowest := max(f32)
	for o, v in origins.vertex do if o != geom.SLICE_NONE {
		out[v] = density[o]
		lowest = min(lowest, out[v])
	}
	if lowest == max(f32) do lowest = 1
	for o, v in origins.vertex do if o == geom.SLICE_NONE do out[v] = lowest
	return out
}

// The guide curves as AutoRemesher takes them (quadmesh.Params.guides): the segments of
// each polyline whose two ends lie within `reach` of `m`, both ends moved onto its
// surface, two points a segment; and how many of the curves gave one. Under `mirror` each
// segment is first cut at every plane and its parts on the - side reflected to the +
// side, so a guide drawn on either side of a symmetric sculpt guides the part remeshed.
@(private = "file")
guide_segments :: proc(m: geom.Mesh, guides: [][]geom.Vec3, mirror: geom.Remesh_Mirror, reach: f32, pool: ^jobs.Pool) -> (segments: []geom.Vec3, curves: int) {
	if len(guides) == 0 || !(reach > 0) || len(m.indices) == 0 do return
	bvh := geom.bvh_build_morton(m, geom.BVH_LEAF_SIZE, pool)
	defer geom.bvh_destroy(&bvh)
	onto :: proc(bvh: ^geom.Bvh, m: geom.Mesh, p: geom.Vec3, reach: f32) -> (geom.Vec3, bool) {
		tri, bary, _, ok := geom.bvh_closest(bvh^, m, p, reach)
		if !ok do return {}, false
		i := m.indices[3 * tri:][:3]
		return bary[0] * m.positions[i[0]] + bary[1] * m.positions[i[1]] + bary[2] * m.positions[i[2]], true
	}
	out := make([dynamic]geom.Vec3)
	pieces := make([dynamic][2]geom.Vec3)
	defer delete(pieces)
	cut := make([dynamic][2]geom.Vec3)
	defer delete(cut)
	for line in guides {
		kept := false
		for k in 1 ..< len(line) {
			clear(&pieces)
			append(&pieces, [2]geom.Vec3{line[k - 1], line[k]})
			for a in 0 ..< 3 {
				if !mirror.axes[a] do continue
				c := mirror.center[a]
				clear(&cut)
				for piece in pieces {
					da, db := piece[0][a] - c, piece[1][a] - c
					if da * db < 0 {
						mid := piece[0] + (piece[1] - piece[0]) * (da / (da - db))
						mid[a] = c
						append(&cut, [2]geom.Vec3{piece[0], mid}, [2]geom.Vec3{mid, piece[1]})
					} else do append(&cut, piece)
				}
				for &piece in cut do for &p in piece do if p[a] < c do p[a] = 2 * c - p[a]
				pieces, cut = cut, pieces
			}
			for piece in pieces {
				a, a_ok := onto(&bvh, m, piece[0], reach)
				b, b_ok := onto(&bvh, m, piece[1], reach)
				if !a_ok || !b_ok || a == b do continue
				append(&out, a, b)
				kept = true
			}
		}
		if kept do curves += 1
	}
	return out[:], curves
}

// The feature edges of `m` for AutoRemesher, two vertex indices each, each edge once:
// every edge between two triangles of different groups (`groups` per triangle, nil for
// none) and every edge whose key is in `creases` (nil for none). An edge on the mesh's
// border is none of AutoRemesher's concern here (it keeps a border as it is).
@(private = "file")
feature_edges :: proc(m: geom.Mesh, groups: []u16, creases: []u64) -> []u32 {
	if groups == nil && creases == nil do return nil
	triangles := len(m.indices) / 3
	crease_set := make(map[u64]bool, len(creases), context.temp_allocator)
	for key in creases do crease_set[key] = true
	// The first triangle seen on each edge; an edge is listed when its second triangle
	// comes with another group, or when it is creased (then at its first sight).
	first := make(map[u64]u32, 3 * triangles, context.temp_allocator)
	out := make([dynamic]u32)
	for t in 0 ..< triangles {
		for k in 0 ..< 3 {
			a, b := m.indices[3 * t + k], m.indices[3 * t + (k + 1) % 3]
			key := sculpt.sharp_key(a, b)
			if other, seen := first[key]; seen {
				if groups != nil && groups[other] != groups[t] && !crease_set[key] do append(&out, a, b)
			} else {
				first[key] = u32(t)
				if crease_set[key] do append(&out, a, b)
			}
		}
	}
	return out[:]
}

// The groups and creases of a mirror cut's half, from the whole's through the cut's
// origins: a cap's triangles form a group of their own (its rim is the seam, which is
// kept sharp in any case), and a crease is kept where both ends came from the whole.
@(private = "file")
half_features :: proc(half: geom.Mesh, origins: geom.Slice_From, groups: []u16, creases: []u64) -> (half_groups: []u16, half_creases: []u64) {
	if groups != nil && len(origins.triangle) == len(half.indices) / 3 {
		half_groups = make([]u16, len(origins.triangle))
		for t, i in origins.triangle do half_groups[i] = groups[t] if t != geom.SLICE_NONE else max(u16)
	}
	if creases != nil && len(origins.vertex) == len(half.positions) {
		crease_set := make(map[u64]bool, len(creases), context.temp_allocator)
		for key in creases do crease_set[key] = true
		kept := make([dynamic]u64)
		seen := make(map[u64]bool, len(creases), context.temp_allocator)
		for t in 0 ..< len(half.indices) / 3 do for k in 0 ..< 3 {
			a, b := half.indices[3 * t + k], half.indices[3 * t + (k + 1) % 3]
			oa, ob := origins.vertex[a], origins.vertex[b]
			if oa == geom.SLICE_NONE || ob == geom.SLICE_NONE || oa == ob do continue
			key := sculpt.sharp_key(a, b)
			if key in seen do continue
			if crease_set[sculpt.sharp_key(oa, ob)] {
				seen[key] = true
				append(&kept, key)
			}
		}
		half_creases = kept[:]
	}
	return
}

// AutoRemesher's half of compute: refuses what it cannot take (or runs forever
// on) before it starts, decimates past the cap, remeshes, and turns the polygons into the
// triangles the object is built of, with the quads and UVs when every polygon is a quad.
@(private = "file")
quad_remesh_compute :: proc(view: geom.Mesh, quads: int, options: Options, pool: ^jobs.Pool, progress: ^jobs.Progress, source: Source) -> (r: Result, outcome: Quad_Outcome) {
	start := time.tick_now()
	outcome = .Fallback
	// The features kept follow the input through each step below: the groups per
	// triangle and the creases as edge keys of the mesh in hand.
	groups := source.groups if options.keep_groups && len(source.groups) == len(view.indices) / 3 else nil
	creases := source.creases if options.keep_creases else nil
	// The density per vertex follows the input the same way, through each step's vertex
	// origins or, for Close first's new surface, by the nearest point of the one before.
	density := vertex_density(len(view.positions), source.paint if options.use_paint else nil, source.mask if options.use_mask else nil)
	defer delete(density)
	// Fewer triangles first past the cap: more make AutoRemesher slower, not better, and
	// the check below has no cancel and a serial pass or two, so it runs on the smaller mesh.
	input := view
	capped: geom.Mesh
	defer geom.mesh_destroy(&capped)
	capped_groups: [dynamic]u16
	defer delete(capped_groups)
	capped_from: [dynamic]u32
	defer delete(capped_from)
	if len(view.indices) / 3 > QUAD_REMESH_MAX_TRIANGLES {
		ok: bool
		// The group borders hold their shape through the decimation, as Decimate's Keep
		// groups holds them; the creases do not survive it (a decimation moves the
		// vertices they ran between), so a sculpt past the cap loses them.
		capped, _, ok = geom.mesh_decimate(view, QUAD_REMESH_MAX_TRIANGLES, pool, progress = progress, share = {0, QUAD_SHARE_CAPPED}, from = &capped_from if density != nil else nil, guide = {labels = groups}, out_labels = &capped_groups if groups != nil else nil)
		if jobs.progress_cancelled(progress) do return {}, .Cancelled
		if ok {
			input = capped
			r.capped = len(capped.indices) / 3
			groups = capped_groups[:] if groups != nil && len(capped_groups) == len(capped.indices) / 3 else nil
			if creases != nil do log.infof("quad remesh: the creases are not kept through the decimation to %d triangles", r.capped)
			creases = nil
			if density != nil && len(capped_from) == len(capped.positions) {
				kept := make([]f32, len(capped.positions))
				for o, v in capped_from do kept[v] = density[o]
				delete(density)
				density = kept
			}
		}
	}
	// Close first: an open or unsound mesh becomes a closed one before anything judges it.
	closed: geom.Mesh
	defer geom.mesh_destroy(&closed)
	if options.close_first {
		closed, r.closed = quad_close_first(input, quads, pool, progress, {QUAD_SHARE_CAPPED, QUAD_SHARE_CHECKED})
		if jobs.progress_cancelled(progress) do return {}, .Cancelled
		if r.closed > 0 {
			if density != nil {
				resampled := density_resample(input, density, closed, pool)
				delete(density)
				density = resampled
			}
			input = closed
			// A new surface: nothing of the groups or creases lies on it.
			if groups != nil || creases != nil do log.infof("quad remesh: the groups and creases are not kept through Close first")
			groups, creases = nil, nil
		}
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
	half_groups: []u16
	defer delete(half_groups)
	half_creases: []u64
	defer delete(half_creases)
	half_density: []f32
	defer delete(half_density)
	mirror := options.mirror
	snap: f32
	asked := quads
	if mirror.axes != {} {
		ok: bool
		origins: geom.Slice_From
		defer geom.slice_from_destroy(&origins)
		half, ok = geom.mirror_cut(input, mirror, true, pool, from = &origins if groups != nil || creases != nil || density != nil else nil)
		if ok {
			half_groups, half_creases = half_features(half, origins, groups, creases)
			half_density = half_densities(half, origins, density)
			extent := c.bounds.hi - c.bounds.lo
			snap = max(extent.x, extent.y, extent.z) * QUAD_SEAM_SNAP
			total, cap := quad_cap_share(half, mirror, snap, half_density)
			parts := 0
			for a in mirror.axes do if a do parts += 1
			asked = int(f64(quads >> uint(parts)) * total / max(total - cap, total * 0.01))
			r.mirrored = true
		} else {
			r.unmirrored = "the mesh does not cross the plane"
		}
	}
	whole_input := input
	whole_groups, whole_creases := groups, creases
	input_density := density
	if r.mirrored do input, groups, creases, input_density = half, half_groups, half_creases, half_density
	params := quadmesh.DEFAULT_PARAMS
	params.adaptivity = clamp(options.adaptivity, 0, 1)
	params.threads = clamp(jobs.pool_size(pool) if pool != nil else 1, 1, quadmesh.MAX_THREADS)
	edge_degrees := options.edge_degrees if options.edge_degrees > 0 else EDGE_DEGREES_DEFAULT
	features: []u32
	defer delete(features)
	guides: []geom.Vec3
	defer delete(guides)
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
		params.sharp_degrees = min(QUAD_SEAM_SHARP_DEGREES, edge_degrees) if r.mirrored else edge_degrees
		delete(features)
		features = feature_edges(input, groups, creases)
		params.features = features
		r.features = len(features) / 2
		params.density = input_density
		// The guides within a quad's width of what goes in, onto its surface; again after
		// a fallback to the whole mesh.
		delete(guides)
		guides, r.guides = nil, 0
		if len(source.guides) > 0 && options.guide_strength > 0 {
			area, _ := geom.mesh_area_bounds(input, pool)
			guides, r.guides = guide_segments(input, source.guides, mirror if r.mirrored else {}, f32(math.sqrt(area / f64(max(asked, 1)))), pool)
		}
		params.guides = guides
		params.guide_strength = clamp(options.guide_strength, 0, 1)
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
		// Feature edges the field could not follow (many small groups, borders crossing at
		// odd angles) can leave the quads torn or doubled up; then the mesh is remeshed
		// without them, so the result is at least sound.
		if r.features > 0 && (check.non_manifold_edges > 0 || (c.closed && !check.closed)) {
			log.warnf("quad remesh: with %d feature edges the result had %d non-manifold and %d boundary edges, so the mesh is remeshed without them", r.features, check.non_manifold_edges, check.boundary_edges)
			geom.mesh_destroy(&mesh)
			sculpt.polys_destroy(&polys)
			quadmesh.polygon_mesh_destroy(&out)
			delete(seam)
			seam = nil
			delete(planes)
			planes = nil
			groups, creases, whole_groups, whole_creases = nil, nil, nil, nil
			r.unkept = "the group and crease edges could not be followed"
			if jobs.progress_cancelled(progress) do return {}, .Cancelled
			continue
		}
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
		groups, creases, input_density = whole_groups, whole_creases, density
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
	log.infof("quad remesh: AutoRemesher gave %d polygons (%d quads, %d triangles, %d larger) over %d vertices from %d triangles%s with %d feature edges and %d guide segments in %.0f ms; %s, %d boundary and %d non-manifold edges",
		r.faces, r.quads, r.triangles, r.ngons, len(mesh.positions), c.triangles, fmt.tprintf(" decimated to %d", r.capped) if r.capped > 0 else "", r.features, len(guides) / 2, report.ms,
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
// `snap`): a capped half's caps. With a density per vertex (nil for none) each triangle's
// area counts times its corners' mean, as the quads are shared out by it.
@(private = "file")
quad_cap_share :: proc(m: geom.Mesh, mirror: geom.Remesh_Mirror, snap: f32, density: []f32) -> (total, cap: f64) {
	for k := 0; k < len(m.indices); k += 3 {
		a, b, c := m.positions[m.indices[k]], m.positions[m.indices[k + 1]], m.positions[m.indices[k + 2]]
		area := f64(linalg.length(linalg.cross(b - a, c - a))) / 2
		if density != nil do area *= f64(density[m.indices[k]] + density[m.indices[k + 1]] + density[m.indices[k + 2]]) / 3
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

