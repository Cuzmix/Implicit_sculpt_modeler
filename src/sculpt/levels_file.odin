package sculpt

import "base:intrinsics"
import "base:runtime"
import "core:slice"

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
// The current level's colours and groups follow its mask (files from before polypaint
// have neither).
@(private = "file")
LEVELS_PAINT :: u32(2)
// After them, each level's sculpt layers (files from before layers have none).
@(private = "file")
LEVELS_LAYERS :: u32(4)
// After them, the base level's quads and UVs (levels_quads.odin).
@(private = "file")
LEVELS_QUADS :: u32(8)
// Right after the base mesh, its node layout (sculptor_layout), so that opening it skips
// partitioning and renumbering it, the bulk of opening a big mesh. Files from before it,
// or with a layout that does not fit, get the full build.
@(private = "file")
LEVELS_LAYOUT :: u32(16)

// Appends the levels to `out`: every level in sync with the current one, its mask, and
// whether dynamic topology is on (a dynamic mesh is stored packed). Leave any HD window
// first.
levels_write :: proc(l: ^Levels, out: ^[dynamic]u8) {
	assert(l.hd.window == nil, "leave the HD window first")
	levels_sync(l)
	paged := levels_dynamic(l)
	geom.byte_put(out, LEVELS_TAG)
	geom.byte_put(out, LEVELS_DYNAMIC if paged else LEVELS_PAINT | LEVELS_LAYERS | LEVELS_QUADS | LEVELS_LAYOUT)
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
	layout := sculptor_layout(&base.sculptor, context.temp_allocator)
	geom.byte_put(out, u32(len(layout)))
	geom.byte_put_slice(out, layout)
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
	s := &levels_current(l).sculptor
	write_mask(out, s.mask, canon[l.current])
	geom.byte_put(out, u8(s.color != nil))
	if s.color != nil {
		saved := slice.reinterpret([]Color, geom.byte_put_bytes(out, len(s.color) * size_of(Color)))
		for c, u in s.color do saved[place(canon[l.current], u32(u))] = c
	}
	geom.byte_put(out, u8(s.groups.tris != nil))
	if s.groups.tris != nil {
		order := tri_canon(s, canon[l.current])
		saved := slice.reinterpret([]u16, geom.byte_put_bytes(out, len(s.groups.tris) * size_of(u16)))
		for g, t in s.groups.tris do saved[order[t]] = g
	}
	for lv, j in l.levels do write_layers(out, &lv.sculptor, canon[j], l.pool)
	// The base level's vertices are in the file in their own order.
	f := l.faces
	geom.byte_put(out, u32(len(f.quads)))
	geom.byte_put_slice(out, f.quads)
	geom.byte_put(out, u8(f.uv.uvs != nil))
	if f.uv.uvs != nil {
		geom.byte_put_slice(out, f.uv.uvs)
		geom.byte_put_slice(out, f.uv.chart)
		geom.byte_put(out, u32(f.uv.charts))
		geom.byte_put(out, f.uv.filled)
	}
}

// A sculptor's layers: how many, which records (0 for none, else its index + 1), then
// per layer its name, strength, visibility and every vertex's displacement in file
// order (zero where the layer moved nothing).
@(private = "file")
write_layers :: proc(out: ^[dynamic]u8, s: ^Sculptor, canon: []u32, pool: ^jobs.Pool) {
	geom.byte_put(out, u32(len(s.layers.list)))
	geom.byte_put(out, u32(s.layers.recording))
	for l in s.layers.list {
		name := l.name
		geom.byte_put_slice(out, name[:])
		geom.byte_put(out, l.strength)
		geom.byte_put(out, u8(l.visible))
		Scatter :: struct {
			s:     ^Sculptor,
			delta: [][]Vec3,
			to:    []u8,
			canon: []u32,
		}
		sc := Scatter{s, l.delta, geom.byte_put_bytes(out, len(s.mesh.positions) * size_of(Vec3)), canon}
		jobs.parallel_ranges(pool, len(s.nodes), &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for id in lo ..< hi {
				n := sc.s.nodes[id]
				d := sc.delta[id]
				for v in n.vert_first ..< n.vert_first + n.vert_count {
					at := cast(^Vec3)&sc.to[size_of(Vec3) * int(place(sc.canon, v))]
					intrinsics.unaligned_store(at, d[v - n.vert_first] if d != nil else Vec3{})
				}
			}
		}, NODE_GRAIN)
	}
}

// Reads what write_layers wrote into a sculptor without layers. False on a damaged file.
@(private = "file")
read_layers :: proc(r: ^geom.Byte_Reader, s: ^Sculptor, canon: []u32) -> bool {
	count := int(geom.byte_get(r, u32))
	recording := int(geom.byte_get(r, u32))
	if !r.ok || count > MAX_SCULPT_LAYERS || recording > count do return false
	n := len(s.mesh.positions)
	for _ in 0 ..< count {
		l := Sculpt_Layer{delta = make([][]Vec3, len(s.nodes), s.history.allocator)}
		append(&s.layers.list, l)
		name := geom.byte_get_bytes(r, len(l.name))
		strength := geom.byte_get(r, f32)
		visible := geom.byte_get(r, u8)
		saved := geom.byte_get_bytes(r, n * size_of(Vec3))
		if !r.ok || visible > 1 do return false
		last := &s.layers.list[len(s.layers.list) - 1]
		copy(last.name[:len(last.name) - 1], name)
		last.strength, last.visible = strength, visible == 1
		for node, id in s.nodes {
			d: []Vec3
			for v in node.vert_first ..< node.vert_first + node.vert_count {
				x := intrinsics.unaligned_load(cast(^Vec3)&saved[size_of(Vec3) * int(canon[v])])
				if x == {} && d == nil do continue
				if d == nil do d = make([]Vec3, node.vert_count, s.history.allocator)
				d[v - node.vert_first] = x
			}
			last.delta[id] = d
		}
	}
	s.layers.recording = recording
	s.layers.named = count
	return true
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

	layout: []Node_Sizes
	if flags & LEVELS_LAYOUT != 0 {
		nodes := int(geom.byte_get(r, u32))
		if !r.ok || nodes < 1 || (len(r.data) - r.at) / size_of(Node_Sizes) < nodes {
			geom.mesh_destroy(&mesh)
			return false
		}
		layout = make([]Node_Sizes, nodes, context.temp_allocator)
		geom.byte_get_slice(r, layout)
	}
	file_order := make([]u32, len(mesh.positions), context.temp_allocator)
	levels_init(l, mesh, pool, node_triangles, file_order, allocator, layout)
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
	if flags & LEVELS_PAINT != 0 {
		s := &levels_current(l).sculptor
		has_color := geom.byte_get(r, u8)
		if !r.ok || has_color > 1 do return false
		if has_color == 1 {
			n := len(s.mesh.positions)
			saved := geom.byte_get_bytes(r, n * size_of(Color))
			if !r.ok do return false
			color_ensure(s)
			for u in 0 ..< n do s.color[u] = intrinsics.unaligned_load(cast(^Color)&saved[size_of(Color) * int(canon[current][u])])
		}
		has_groups := geom.byte_get(r, u8)
		if !r.ok || has_groups > 1 do return false
		if has_groups == 1 {
			tcount := len(s.mesh.indices) / 3
			saved := geom.byte_get_bytes(r, tcount * size_of(u16))
			if !r.ok do return false
			order := tri_canon(s, canon[current])
			s.groups.tris = make([]u16, tcount, s.history.allocator)
			for t in 0 ..< tcount do s.groups.tris[t] = intrinsics.unaligned_load(cast(^u16)&saved[size_of(u16) * int(order[t])])
			groups_refresh(s)
		}
		// The other levels take them at the first level change.
		s.color_edited, s.groups.edited = s.color != nil, s.groups.tris != nil
	}
	if flags & LEVELS_LAYERS != 0 {
		for lv, j in l.levels do if !read_layers(r, &lv.sculptor, canon[j]) do return false
	}
	if flags & LEVELS_QUADS != 0 && !read_quads(r, l, file_order) do return false
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

// Per triangle, its place in the file: triangles in order of their corner placed first
// (`canon` gives places, or the vertices' own numbers when nil), and of those sharing
// it, of the corner after it. On a mesh whose edges each have one triangle running
// them either way, no two triangles share both, so only the topology decides this.
// Temporary.
@(private = "file")
tri_canon :: proc(s: ^Sculptor, canon: []u32) -> []u32 {
	indices := s.mesh.indices[:]
	tcount, vcount := len(indices) / 3, len(s.mesh.positions)
	Key :: struct {
		first, next: u32,
	}
	key := make([]Key, tcount, context.temp_allocator)
	start := make([]u32, vcount + 1, context.temp_allocator)
	for t in 0 ..< tcount {
		c := [3]u32{place(canon, indices[3 * t]), place(canon, indices[3 * t + 1]), place(canon, indices[3 * t + 2])}
		k := 0
		if c[1] < c[k] do k = 1
		if c[2] < c[k] do k = 2
		key[t] = {c[k], c[(k + 1) % 3]}
		start[c[k] + 1] += 1
	}
	for v in 0 ..< vcount do start[v + 1] += start[v]
	// A counting sort by the first corner, then the few triangles of each first corner by
	// the next.
	sorted := make([]u32, tcount, context.temp_allocator)
	fill := slice.clone(start, context.temp_allocator)
	for k, t in key {
		sorted[fill[k.first]] = u32(t)
		fill[k.first] += 1
	}
	for v in 0 ..< vcount {
		run := sorted[start[v]:start[v + 1]]
		for i in 1 ..< len(run) {
			for j := i; j > 0 && key[run[j]].next < key[run[j - 1]].next; j -= 1 do run[j], run[j - 1] = run[j - 1], run[j]
		}
	}
	order := make([]u32, tcount, context.temp_allocator)
	for t, i in sorted do order[t] = u32(i)
	return order
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

// Reads the quads and UVs levels_write put after the layers, with the base level's
// vertices renumbered by `file_order` (file place -> vertex). False on a damaged file.
@(private = "file")
read_quads :: proc(r: ^geom.Byte_Reader, l: ^Levels, file_order: []u32) -> bool {
	count := int(geom.byte_get(r, u32))
	if !r.ok || count > (len(r.data) - r.at) / size_of([4]u32) do return false
	if count == 0 {
		has_uv := geom.byte_get(r, u8)
		return r.ok && has_uv == 0
	}
	vertices := u32(len(file_order))
	quads := make([][4]u32, count, l.allocator)
	ok := false
	defer if !ok do delete(quads, l.allocator)
	saved := geom.byte_get_bytes(r, count * size_of([4]u32))
	if !r.ok do return false
	for &q, i in quads {
		for k in 0 ..< 4 {
			v := intrinsics.unaligned_load(cast(^u32)&saved[size_of([4]u32) * i + size_of(u32) * k])
			if v >= vertices do return false
			q[k] = file_order[v]
		}
	}
	has_uv := geom.byte_get(r, u8)
	if !r.ok || has_uv > 1 do return false
	levels_set_quads(l, quads)
	ok = true
	if has_uv == 0 do return true
	uv: geom.Uv_Layout
	uv_bytes := geom.byte_get_bytes(r, count * size_of([4][2]f32))
	chart_bytes := geom.byte_get_bytes(r, count * size_of(u32))
	charts := int(geom.byte_get(r, u32))
	filled := geom.byte_get(r, f32)
	if !r.ok do return false
	uv.uvs = make([][4][2]f32, count, l.allocator)
	uv.chart = make([]u32, count, l.allocator)
	for i in 0 ..< count {
		uv.uvs[i] = intrinsics.unaligned_load(cast(^[4][2]f32)&uv_bytes[size_of([4][2]f32) * i])
		uv.chart[i] = intrinsics.unaligned_load(cast(^u32)&chart_bytes[size_of(u32) * i])
		if int(uv.chart[i]) >= charts {
			geom.uv_layout_destroy(&uv, l.allocator)
			return false
		}
	}
	uv.charts, uv.filled = charts, filled
	levels_set_uvs(l, uv)
	return true
}
