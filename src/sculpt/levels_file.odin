package sculpt

import "base:intrinsics"
import "base:runtime"

import "../geom"
import "../jobs"

// Subdivision levels in and out of the native scene file (the app writes the rest of
// it). Every level is stored as positions, so each reads back exactly as it was shown,
// and the detail tying the levels together is encoded again from them, as a sync does.
// Vertex numbers change whenever a sculptor is built (sculptor_init renumbers), so the
// levels above the base store their vertices in an order only the topology decides:
// the vertices continuing the level below first, in that level's order, then the edge
// vertices ordered by their edge's ends (see level_canon). The base level's own order
// is the one it is written in. Positions go straight between the file's bytes and the
// meshes, without a copy in between, since at 10M vertices that copy is 120 MB. HD detail is not stored, since its storage follows node
// numbers, which differ in every build; the number of HD steps is.

@(private = "file")
LEVELS_TAG :: u32(0x5645_4c53) // "SLEV" in the file

@(private = "file")
LEVELS_DYNAMIC :: u32(1)

// Appends the levels to `out`: every level in sync with the current one, its mask, and
// whether dynamic topology is on (a dynamic mesh is stored packed). Leave any HD window
// first.
levels_write :: proc(l: ^Levels, out: ^[dynamic]u8) {
	assert(l.hd.window == nil, "leave the HD window first")
	levels_sync(l)
	paged := levels_dynamic(l)
	geom.byte_put(out, LEVELS_TAG)
	geom.byte_put(out, LEVELS_DYNAMIC if paged else 0)
	geom.byte_put(out, u32(len(l.levels)))
	geom.byte_put(out, u32(l.current))
	geom.byte_put(out, u32(l.hd.steps))
	base := l.levels[0]
	if paged {
		packed, mask := sculptor_compact_mesh(&base.sculptor)
		defer geom.mesh_destroy(&packed)
		defer delete(mask)
		write_mesh(out, packed)
		write_mask(out, mask, nil)
		return
	}
	write_mesh(out, base.mesh)
	canon: [MAX_LEVELS][]u32 // level 0's is its own order
	for j in 1 ..< len(l.levels) {
		lv := l.levels[j]
		canon[j] = level_canon(l, j, canon[j - 1], context.temp_allocator)
		n := len(lv.mesh.positions)
		geom.byte_put(out, u32(n))
		Scatter :: struct {
			from:  []Vec3,
			to:    []u8,
			canon: []u32,
		}
		sc := Scatter{lv.mesh.positions[:], geom.byte_put_bytes(out, n * size_of(Vec3)), canon[j]}
		jobs.parallel_ranges(l.pool, n, &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for u in lo ..< hi do intrinsics.unaligned_store(cast(^Vec3)&sc.to[size_of(Vec3) * int(sc.canon[u])], sc.from[u])
		}, geom.RANGE_GRAIN)
	}
	write_mask(out, levels_current(l).sculptor.mask, canon[l.current])
}

// Reads levels written by levels_write into `l`, which must be empty: the base level,
// then each level above by subdividing and moving its vertices where they were, then
// the detail encoded again, the mask, the HD steps and dynamic topology. Every count is
// checked against the bytes left before anything is built from it, and the base mesh
// is checked sculptable, so a damaged file returns false (leaving `l` empty) rather
// than asserting.
levels_read :: proc(l: ^Levels, r: ^geom.Byte_Reader, pool: ^jobs.Pool, node_triangles: u32 = NODE_TRIANGLES, allocator := context.allocator) -> bool {
	if geom.byte_get(r, u32) != LEVELS_TAG do return false
	flags := geom.byte_get(r, u32)
	count := int(geom.byte_get(r, u32))
	current := int(geom.byte_get(r, u32))
	hd_steps := int(geom.byte_get(r, u32))
	if !r.ok || count < 1 || count > MAX_LEVELS || current >= count || hd_steps > HD_MAX_STEPS do return false
	paged := flags & LEVELS_DYNAMIC != 0
	if paged && (count != 1 || hd_steps > 0) do return false
	mesh, mesh_ok := read_mesh(r, pool, allocator)
	if !mesh_ok do return false

	file_order := make([]u32, len(mesh.positions), context.temp_allocator)
	levels_init(l, mesh, pool, node_triangles, file_order, allocator)
	sculptor_recompute_all(&l.levels[0].sculptor)
	ok := false
	defer if !ok do levels_destroy(l)
	// Per level: each vertex's place in the file. Kept outside the temp scratch of
	// each level, which is given back once the level is read.
	canon: [MAX_LEVELS][]u32
	defer for c in canon do delete(c, allocator)
	canon[0] = make([]u32, len(file_order), allocator)
	for internal, i in file_order do canon[0][internal] = u32(i)
	// Each level's scratch (building it and its sculptor, the saved positions) comes
	// from an arena given back after the level, so reading several levels costs the
	// scratch of the largest rather than of all of them.
	scratch: runtime.Arena
	defer runtime.arena_destroy(&scratch)
	for j in 1 ..< count {
		context.temp_allocator = runtime.arena_allocator(&scratch)
		defer runtime.arena_free_all(&scratch)
		vertices := int(geom.byte_get(r, u32))
		expected, _, _ := levels_subdivide_estimate(l)
		if !r.ok || vertices != expected || (len(r.data) - r.at) / size_of(Vec3) < vertices do return false
		// Its edits are carried by the encoding at the end, not by a sync.
		sculptor_clear_edited(&l.levels[j - 1].sculptor)
		if !levels_subdivide(l) || len(l.levels[j].mesh.positions) != vertices do return false
		lv := l.levels[j]
		canon[j] = level_canon(l, j, canon[j - 1], allocator)
		Gather :: struct {
			from:  []u8,
			to:    []Vec3,
			canon: []u32,
		}
		g := Gather{geom.byte_get_bytes(r, vertices * size_of(Vec3)), lv.mesh.positions[:], canon[j]}
		jobs.parallel_ranges(pool, vertices, &g, proc(data: rawptr, lo, hi: int) {
			g := cast(^Gather)data
			for u in lo ..< hi do g.to[u] = intrinsics.unaligned_load(cast(^Vec3)&g.from[size_of(Vec3) * int(g.canon[u])])
		}, geom.RANGE_GRAIN)
	}
	for j in 1 ..< count {
		lv := l.levels[j]
		all := make([]u32, len(lv.sculptor.nodes), context.temp_allocator)
		for &id, i in all do id = u32(i)
		recode_level(l, j, all, encode = true)
		sculptor_nodes_moved(&lv.sculptor, all)
		_ = sculptor_flush(&lv.sculptor)
	}
	for lv in l.levels do sculptor_clear_edited(&lv.sculptor)
	l.current = current

	has_mask := geom.byte_get(r, u8)
	if !r.ok || has_mask > 1 do return false
	if has_mask == 1 {
		s := &levels_current(l).sculptor
		n := len(s.mesh.positions)
		saved := geom.byte_get_bytes(r, n)
		if !r.ok do return false
		mask_ensure(s)
		for u in 0 ..< n do s.mask[u] = saved[canon[current][u]]
	}
	if hd_steps > 0 && !levels_hd_set_steps(l, hd_steps) do return false
	if paged && !levels_dyn_enable(l) do return false
	ok = r.ok
	return ok
}

// Per vertex of level j, its place in the file: the vertex of the level below that it
// continues comes first, at that vertex's place (`below`, or the level's own order when
// nil); the vertices on edges follow, ordered by the lower place of their edge's ends,
// then the higher. Only the topology decides this, so the same level built from a
// differently numbered level below gets the same order. Rather than sorting the edges,
// each vertex below counts its neighbours placed after it, which by a running sum over
// the places gives where its edges start; an edge is then as far into those as its end
// vertex's neighbours placed between its two ends.
@(private)
level_canon :: proc(l: ^Levels, j: int, below: []u32, allocator := context.allocator) -> []u32 {
	Canon :: struct {
		lv, under: ^Level,
		below:     []u32,
		start:     []u32, // per place below, plus one: where its edges start
		canon:     []u32,
	}
	lv, under := l.levels[j], l.levels[j - 1]
	vb := len(under.mesh.positions)
	k := Canon{lv, under, below, make([]u32, vb + 1, context.temp_allocator), make([]u32, len(lv.mesh.positions), allocator)}
	jobs.parallel_ranges(l.pool, vb, &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Canon)data
		indices := k.under.mesh.indices[:]
		for v in u32(lo) ..< u32(hi) {
			pv := place(k.below, v)
			after: u32
			// Each neighbour comes once as the corner after v, on a closed mesh.
			for f in geom.vertex_faces_of(k.under.sculptor.faces, v) {
				w, _ := others(indices, f, v)
				after += u32(place(k.below, w) > pv)
			}
			k.start[pv + 1] = after
		}
	}, geom.RANGE_GRAIN)
	for p in 0 ..< vb do k.start[p + 1] += k.start[p]
	jobs.parallel_ranges(l.pool, len(k.canon), &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Canon)data
		indices := k.under.mesh.indices[:]
		vb := u32(len(k.under.mesh.positions))
		for u in lo ..< hi {
			par := k.lv.parents[u]
			if par[2] == EVEN {
				k.canon[u] = place(k.below, par[0])
				continue
			}
			a, b := par[0], par[1]
			pa, pb := place(k.below, a), place(k.below, b)
			if pb < pa do a, pa, pb = b, pb, pa
			before: u32
			for f in geom.vertex_faces_of(k.under.sculptor.faces, a) {
				w, _ := others(indices, f, a)
				pw := place(k.below, w)
				before += u32(pw > pa && pw < pb)
			}
			k.canon[u] = vb + k.start[pa] + before
		}
	}, geom.RANGE_GRAIN)
	return k.canon
}

// A vertex's place in the file: `below` gives it, or the vertex's own number when nil.
@(private = "file")
place :: #force_inline proc(below: []u32, v: u32) -> u32 {return below[v] if below != nil else v}

@(private = "file")
write_mesh :: proc(out: ^[dynamic]u8, m: geom.Mesh) {
	geom.byte_put(out, u32(len(m.positions)))
	geom.byte_put(out, u32(len(m.indices) / 3))
	geom.byte_put_slice(out, m.positions[:])
	geom.byte_put_slice(out, m.indices[:])
}

@(private = "file")
read_mesh :: proc(r: ^geom.Byte_Reader, pool: ^jobs.Pool, allocator: runtime.Allocator) -> (m: geom.Mesh, ok: bool) {
	vertices := int(geom.byte_get(r, u32))
	triangles := int(geom.byte_get(r, u32))
	if !r.ok || vertices < 3 || triangles < 1 do return {}, false
	if (len(r.data) - r.at) / size_of(Vec3) < vertices || (len(r.data) - r.at - vertices * size_of(Vec3)) / 12 < triangles do return {}, false
	m.positions = make([dynamic]Vec3, vertices, allocator)
	m.normals = make([dynamic]Vec3, vertices, allocator)
	m.indices = make([dynamic]u32, 3 * triangles, allocator)
	geom.byte_get_slice(r, m.positions[:])
	geom.byte_get_slice(r, m.indices[:])
	if !r.ok || geom.mesh_sculptable(m, pool) != .None {
		geom.mesh_destroy(&m)
		return {}, false
	}
	return m, true
}

// The mask in the file's vertex order (`canon`, or the mesh's own when nil), after a
// byte saying whether there is one.
@(private = "file")
write_mask :: proc(out: ^[dynamic]u8, mask: []u8, canon: []u32) {
	geom.byte_put(out, u8(mask != nil))
	if mask == nil do return
	if canon == nil {
		geom.byte_put_slice(out, mask)
		return
	}
	saved := geom.byte_put_bytes(out, len(mask))
	for k, u in mask do saved[canon[u]] = k
}
