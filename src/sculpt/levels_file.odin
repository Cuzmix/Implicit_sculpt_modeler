package sculpt

import "base:intrinsics"
import "base:runtime"
import "core:slice"
import "core:sync"

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
// After the quads, the selection sets (selection_sets.odin), each in its level's file
// order (files from before them have none).
@(private = "file")
LEVELS_SETS :: u32(32)
// Right after the layout, the Catmull-Clark rule and the base level's polygons, their
// triangles' polygons and its creases (levels_cc.odin), all in the base's own order, so
// the levels above are rebuilt by the same rule (files from before them are Loop's).
@(private = "file")
LEVELS_CC :: u32(64)

// How levels_write runs. A save from the frame loop takes the defaults. The autosave
// thread writes serially, since the pool takes jobs from the frame loop alone, and
// stops between pieces once the frame loop needs the scene back.
Write_Options :: struct {
	serial:  bool,  // every loop on the calling thread, never through the levels' pool
	abort:   ^bool, // read atomically between pieces: once set, levels_write stops and returns false
	synced:  bool,  // the caller ran levels_sync and nothing changed since, so the levels are only read
	hd_open: bool,  // an HD window may be open: its detail is never stored, so the bytes are the ones leaving it gives
}

// What the autosave thread copies between two looks at its abort flag: about a
// millisecond on a desktop, longer while fresh pages fault in.
@(private = "file")
PIECE_BYTES :: 1 << 20

@(private = "file")
Writer :: struct {
	out:   ^[dynamic]u8,
	pool:  ^jobs.Pool, // nil: on this thread
	abort: ^bool,
}

@(private = "file")
stopped :: #force_inline proc(abort: ^bool) -> bool {return abort != nil && sync.atomic_load(abort)}

// Appends `bytes`, in pieces when it can be stopped. False once it was.
@(private = "file")
put_checked :: proc(w: ^Writer, bytes: []u8) -> bool {
	if w.abort == nil {
		append(w.out, ..bytes)
		return true
	}
	for at := 0; at < len(bytes); at += PIECE_BYTES {
		if stopped(w.abort) do return false
		append(w.out, ..bytes[at:min(at + PIECE_BYTES, len(bytes))])
	}
	return true
}

// Runs `fn` over 0 ..< count in ranges of `grain`: through `pool`, or on this thread
// looking at `abort` between ranges. False once it was set.
@(private)
ranges :: proc(pool: ^jobs.Pool, abort: ^bool, count: int, data: rawptr, fn: jobs.Range_Proc, grain: int) -> bool {
	if pool != nil {
		jobs.parallel_ranges(pool, count, data, fn, grain)
		return !stopped(abort)
	}
	for lo := 0; lo < count; lo += grain {
		if stopped(abort) do return false
		fn(data, lo, min(lo + grain, count))
	}
	return !stopped(abort)
}

// Appends the levels to `out`: every level in sync with the current one, its mask, and
// whether dynamic topology is on (a dynamic mesh is stored packed). Leave any HD window
// first, unless `opts` says otherwise. False only when `opts.abort` stopped it, with
// `out` then holding part of it.
levels_write :: proc(l: ^Levels, out: ^[dynamic]u8, opts := Write_Options{}) -> bool {
	assert(opts.hd_open || l.hd.window == nil, "leave the HD window first")
	if !opts.synced do levels_sync(l)
	w := Writer{out, nil if opts.serial else l.pool, opts.abort}
	paged := levels_dynamic(l)
	geom.byte_put(out, LEVELS_TAG)
	base := l.levels[0]
	cc := !paged && l.rule != .Loop && base.polys.first != nil
	geom.byte_put(out, LEVELS_DYNAMIC if paged else LEVELS_PAINT | LEVELS_LAYERS | LEVELS_QUADS | LEVELS_LAYOUT | LEVELS_SETS | (LEVELS_CC if cc else 0))
	geom.byte_put(out, u32(len(l.levels)))
	geom.byte_put(out, u32(l.current))
	geom.byte_put(out, u32(l.hd.steps))
	if paged {
		packed, mask := compact_mesh(&base.sculptor, w.pool, false, w.abort)
		defer geom.mesh_destroy(&packed)
		defer delete(mask)
		return !stopped(w.abort) && write_mesh(&w, packed) && write_mask(&w, mask, nil)
	}
	if !write_mesh(&w, base.mesh) do return false
	layout := sculptor_layout(&base.sculptor, context.temp_allocator)
	geom.byte_put(out, u32(len(layout)))
	if !put_checked(&w, slice.to_bytes(layout)) do return false
	if cc {
		p, sh := &base.polys, &base.sharp
		geom.byte_put(out, u8(l.rule))
		geom.byte_put(out, u32(len(p.first) - 1))
		geom.byte_put(out, u32(len(sh.edges)))
		geom.byte_put(out, u32(len(sh.verts)))
		for bytes in ([][]u8{slice.to_bytes(p.first), slice.to_bytes(p.corners), slice.to_bytes(p.tri_poly), slice.to_bytes(sh.edges), slice.to_bytes(sh.edge), slice.to_bytes(sh.verts), slice.to_bytes(sh.vert)}) {
			if !put_checked(&w, bytes) do return false
		}
	}
	canon: [MAX_LEVELS][]u32 // level 0's is its own order
	for j in 1 ..< len(l.levels) {
		lv := l.levels[j]
		canon[j] = level_canon(l, j, canon[j - 1], w.pool, w.abort, context.temp_allocator)
		if canon[j] == nil do return false
		n := len(lv.mesh.positions)
		geom.byte_put(out, u32(n))
		Scatter :: struct {
			from:  []Vec3,
			to:    []u8,
			canon: []u32,
		}
		sc := Scatter{lv.mesh.positions[:], geom.byte_put_bytes(out, n * size_of(Vec3)), canon[j]}
		ranged := ranges(w.pool, w.abort, n, &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for u in lo ..< hi do intrinsics.unaligned_store(cast(^Vec3)&sc.to[size_of(Vec3) * int(sc.canon[u])], sc.from[u])
		}, geom.RANGE_GRAIN)
		if !ranged do return false
	}
	s := &levels_current(l).sculptor
	if !write_mask(&w, s.mask, canon[l.current]) do return false
	geom.byte_put(out, u8(s.color != nil))
	if s.color != nil {
		Colors :: struct {
			from:  []Color,
			to:    []Color,
			canon: []u32,
		}
		c := Colors{s.color, slice.reinterpret([]Color, geom.byte_put_bytes(out, len(s.color) * size_of(Color))), canon[l.current]}
		ranged := ranges(w.pool, w.abort, len(s.color), &c, proc(data: rawptr, lo, hi: int) {
			c := cast(^Colors)data
			for u in lo ..< hi do c.to[place(c.canon, u32(u))] = c.from[u]
		}, geom.RANGE_GRAIN)
		if !ranged do return false
	}
	geom.byte_put(out, u8(s.groups.tris != nil))
	if s.groups.tris != nil {
		order := tri_canon(s, canon[l.current], w.abort)
		if order == nil do return false
		Groups :: struct {
			from:  []u16,
			to:    []u16,
			order: []u32,
		}
		g := Groups{s.groups.tris, slice.reinterpret([]u16, geom.byte_put_bytes(out, len(s.groups.tris) * size_of(u16))), order}
		ranged := ranges(w.pool, w.abort, len(s.groups.tris), &g, proc(data: rawptr, lo, hi: int) {
			g := cast(^Groups)data
			for t in lo ..< hi do g.to[g.order[t]] = g.from[t]
		}, geom.RANGE_GRAIN)
		if !ranged do return false
	}
	for lv, j in l.levels do if !write_layers(&w, &lv.sculptor, canon[j]) do return false
	// The base level's vertices are in the file in their own order.
	f := l.faces
	geom.byte_put(out, u32(len(f.quads)))
	if !put_checked(&w, slice.to_bytes(f.quads)) do return false
	geom.byte_put(out, u8(f.uv.uvs != nil))
	if f.uv.uvs != nil {
		if !put_checked(&w, slice.to_bytes(f.uv.uvs)) || !put_checked(&w, slice.to_bytes(f.uv.chart)) do return false
		geom.byte_put(out, u32(f.uv.charts))
		geom.byte_put(out, f.uv.filled)
	}
	return write_sets(&w, l, canon[:]) && !stopped(w.abort)
}

// The selection sets: how many, then per set its name, level, mean mask and its values
// in that level's file order, packed again (as runs when smaller). Serial, since a set
// is a byte a vertex at most, looking at the abort flag between ranges of the scatter.
// Two buffers of the largest level serve every set, and each packed copy is freed once
// written, so the autosave thread holds about three bytes a vertex for them, not more
// with each set.
@(private = "file")
write_sets :: proc(w: ^Writer, l: ^Levels, canon: []([]u32)) -> bool {
	out := w.out
	geom.byte_put(out, u32(len(l.sets)))
	if len(l.sets) == 0 do return true
	largest := 0
	for set in l.sets do largest = max(largest, set.vertices)
	values := make([]u8, largest, context.temp_allocator)
	ordered := make([]u8, largest, context.temp_allocator)
	for &set in l.sets {
		if stopped(w.abort) do return false
		ok := set_decode(set.data, set.runs, values[:set.vertices])
		assert(ok, "a selection set is damaged")
		Scatter :: struct {
			from, to: []u8,
			canon:    []u32,
		}
		sc := Scatter{values[:set.vertices], ordered[:set.vertices], canon[set.level]}
		ranged := ranges(nil, w.abort, set.vertices, &sc, proc(data: rawptr, lo, hi: int) {
			sc := cast(^Scatter)data
			for u in lo ..< hi do sc.to[place(sc.canon, u32(u))] = sc.from[u]
		}, geom.RANGE_GRAIN)
		if !ranged do return false
		data, runs := set_encode(ordered[:set.vertices], runtime.heap_allocator())
		defer delete(data, runtime.heap_allocator())
		name := set.name
		geom.byte_put_slice(out, name[:])
		geom.byte_put(out, u32(set.level))
		geom.byte_put(out, set.masked)
		geom.byte_put(out, u8(runs))
		geom.byte_put(out, u32(len(data)))
		if !put_checked(w, data) do return false
	}
	return true
}

// Reads what write_sets wrote, once the levels are built and `canon` gives each vertex's
// place in the file. False on a damaged file: too many sets, a level out of range, a
// size past the bytes left, or runs not adding up to the level's vertices.
@(private = "file")
read_sets :: proc(r: ^geom.Byte_Reader, l: ^Levels, canon: []([]u32)) -> bool {
	count := int(geom.byte_get(r, u32))
	if !r.ok || count > MAX_SELECTION_SETS do return false
	// Buffers of the largest level, for every set.
	largest := 0
	for lv in l.levels do largest = max(largest, len(lv.mesh.positions))
	ordered_all := make([]u8, largest if count > 0 else 0, context.temp_allocator)
	values_all := make([]u8, largest if count > 0 else 0, context.temp_allocator)
	for _ in 0 ..< count {
		set: Selection_Set
		name := geom.byte_get_bytes(r, len(set.name))
		level := int(geom.byte_get(r, u32))
		masked := geom.byte_get(r, f32)
		runs := geom.byte_get(r, u8)
		size := int(geom.byte_get(r, u32))
		if !r.ok || level >= len(l.levels) || runs > 1 || size > len(r.data) - r.at do return false
		data := geom.byte_get_bytes(r, size)
		n := len(l.levels[level].mesh.positions)
		ordered := ordered_all[:n]
		if !r.ok || !set_decode(data, runs == 1, ordered) do return false
		values := values_all[:n]
		for u in 0 ..< n do values[u] = ordered[place(canon[level], u32(u))]
		copy(set.name[:len(set.name) - 1], name)
		l.set_serial += 1
		set.id, set.level, set.vertices = l.set_serial, level, n
		set.masked = masked if masked >= 0 && masked <= 1 else 0 // NaN too
		set.data, set.runs = set_encode(values, l.allocator)
		append(&l.sets, set)
	}
	return true
}

// A sculptor's layers: how many, which records (0 for none, else its index + 1), then
// per layer its name, strength, visibility and every vertex's displacement in file
// order (zero where the layer moved nothing).
@(private = "file")
write_layers :: proc(w: ^Writer, s: ^Sculptor, canon: []u32) -> bool {
	out := w.out
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
		ranged := ranges(w.pool, w.abort, len(s.nodes), &sc, proc(data: rawptr, lo, hi: int) {
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
		if !ranged do return false
	}
	return true
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
	tri_from := make([]u32, len(mesh.indices) / 3, context.temp_allocator)
	levels_init(l, mesh, pool, node_triangles, file_order, tri_from, allocator = allocator, layout = layout)
	sculptor_recompute_all(&l.levels[0].sculptor)
	ok := false
	defer if !ok do levels_destroy(l)
	if flags & LEVELS_CC != 0 && !read_cc(r, l, file_order, tri_from) do return false
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
		canon[j] = level_canon(l, j, canon[j - 1], pool, allocator = allocator)
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
	if flags & LEVELS_SETS != 0 && !read_sets(r, l, canon[:count]) do return false
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
level_canon :: proc(l: ^Levels, j: int, below: []u32, pool: ^jobs.Pool, abort: ^bool = nil, allocator := context.allocator) -> []u32 {
	Canon :: struct {
		lv, under: ^Level,
		below:     []u32,
		start:     []u32, // per place below, plus one: where its edges start
		canon:     []u32,
		// Under a Catmull-Clark rule, the polygons below: a vertex's neighbours are the
		// corners after it in its polygons, and the face points come last, in polygon
		// order, which only the topology decides too.
		polys:     ^Polys,
	}
	// Calls `fn` for each neighbour w of v below: the corner after v in each of its
	// triangles, or in each of its polygons. Each comes once on a closed mesh.
	neighbours :: #force_inline proc(k: ^Canon, v: u32, data: ^u32, pv, pb: u32, fn: proc(k: ^Canon, w: u32, data: ^u32, pv, pb: u32)) {
		tris := geom.vertex_faces_of(k.under.sculptor.faces, v)
		indices := k.under.mesh.indices[:]
		if k.polys == nil {
			for f in tris {
				w, _ := others(indices, f, v)
				fn(k, w, data, pv, pb)
			}
			return
		}
		for f, i in tris {
			g := k.polys.tri_poly[f]
			seen := false
			for e in tris[:i] do if k.polys.tri_poly[e] == g do seen = true
			if seen do continue
			corners := poly_corners(k.polys, g)
			at, _ := slice.linear_search(corners, v)
			fn(k, corners[(at + 1) % len(corners)], data, pv, pb)
		}
	}
	lv, under := l.levels[j], l.levels[j - 1]
	vb := len(under.mesh.positions)
	k := Canon{lv, under, below, make([]u32, vb + 1, context.temp_allocator), make([]u32, len(lv.mesh.positions), allocator), nil}
	if l.rule != .Loop && under.polys.first != nil do k.polys = &under.polys
	ranged := ranges(pool, abort, vb, &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Canon)data
		for v in u32(lo) ..< u32(hi) {
			pv := place(k.below, v)
			after: u32
			neighbours(k, v, &after, pv, 0, proc(k: ^Canon, w: u32, after: ^u32, pv, _: u32) {after^ += u32(place(k.below, w) > pv)})
			k.start[pv + 1] = after
		}
	}, geom.RANGE_GRAIN)
	if !ranged {
		delete(k.canon, allocator)
		return nil
	}
	for p in 0 ..< vb do k.start[p + 1] += k.start[p]
	ranged = ranges(pool, abort, len(k.canon), &k, proc(data: rawptr, lo, hi: int) {
		k := cast(^Canon)data
		vb := u32(len(k.under.mesh.positions))
		for u in lo ..< hi {
			par := k.lv.parents[u]
			if par[2] == EVEN {
				k.canon[u] = place(k.below, par[0])
				continue
			}
			if par[2] == FACE && k.polys != nil {
				k.canon[u] = vb + k.start[vb] + par[3]
				continue
			}
			a, b := par[0], par[1]
			pa, pb := place(k.below, a), place(k.below, b)
			if pb < pa do a, pa, pb = b, pb, pa
			before: u32
			neighbours(k, a, &before, pa, pb, proc(k: ^Canon, w: u32, before: ^u32, pa, pb: u32) {
				pw := place(k.below, w)
				before^ += u32(pw > pa && pw < pb)
			})
			k.canon[u] = vb + k.start[pa] + before
		}
	}, geom.RANGE_GRAIN)
	if !ranged {
		delete(k.canon, allocator)
		return nil
	}
	return k.canon
}

// Per triangle, its place in the file: triangles in order of their corner placed first
// (`canon` gives places, or the vertices' own numbers when nil), and of those sharing
// it, of the corner after it. On a mesh whose edges each have one triangle running
// them either way, no two triangles share both, so only the topology decides this.
// Temporary.
@(private = "file")
tri_canon :: proc(s: ^Sculptor, canon: []u32, abort: ^bool = nil) -> []u32 {
	indices := s.mesh.indices[:]
	tcount, vcount := len(indices) / 3, len(s.mesh.positions)
	Key :: struct {
		first, next: u32,
	}
	key := make([]Key, tcount, context.temp_allocator)
	start := make([]u32, vcount + 1, context.temp_allocator)
	for t in 0 ..< tcount {
		if t & 0xffff == 0 && stopped(abort) do return nil
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
		if t & 0xffff == 0 && stopped(abort) do return nil
		sorted[fill[k.first]] = u32(t)
		fill[k.first] += 1
	}
	for v in 0 ..< vcount {
		if v & 0xffff == 0 && stopped(abort) do return nil
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
write_mesh :: proc(w: ^Writer, m: geom.Mesh) -> bool {
	geom.byte_put(w.out, u32(len(m.positions)))
	geom.byte_put(w.out, u32(len(m.indices) / 3))
	return put_checked(w, slice.to_bytes(m.positions[:])) && put_checked(w, slice.to_bytes(m.indices[:]))
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
write_mask :: proc(w: ^Writer, mask: []u8, canon: []u32) -> bool {
	geom.byte_put(w.out, u8(mask != nil))
	if mask == nil do return true
	if canon == nil do return put_checked(w, mask)
	Scatter :: struct {
		from, to: []u8,
		canon:    []u32,
	}
	sc := Scatter{mask, geom.byte_put_bytes(w.out, len(mask)), canon}
	return ranges(w.pool, w.abort, len(mask), &sc, proc(data: rawptr, lo, hi: int) {
		sc := cast(^Scatter)data
		for u in lo ..< hi do sc.to[sc.canon[u]] = sc.from[u]
	}, geom.RANGE_GRAIN)
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

// Reads what levels_write wrote under LEVELS_CC into a single-level `l`: the rule, then
// the base's polygons, triangles' polygons and creases in the file's order, put in the
// level's by `file_order` (per file vertex, the level's) and `tri_from` (per triangle,
// its file number). False on a damaged file: counts past the bytes left, or polygons,
// corners or creases that do not fit the base.
@(private = "file")
read_cc :: proc(r: ^geom.Byte_Reader, l: ^Levels, file_order, tri_from: []u32) -> bool {
	rule := geom.byte_get(r, u8)
	pcount := int(geom.byte_get(r, u32))
	ecount := int(geom.byte_get(r, u32))
	vcount := int(geom.byte_get(r, u32))
	tcount := len(tri_from)
	left := len(r.data) - r.at
	if !r.ok || rule < u8(Subdivision_Rule.Smooth) || rule > u8(Subdivision_Rule.Flat) || pcount < 1 || pcount > tcount do return false
	if ecount > left / 12 || vcount > left / 8 || (pcount + 1 + tcount) > left / 4 do return false
	first := make([]u32, pcount + 1, l.allocator)
	geom.byte_get_slice(r, first)
	corners_count := int(first[pcount]) if r.ok else 0
	if !r.ok || first[0] != 0 || corners_count > (len(r.data) - r.at) / 4 || corners_count < 3 * pcount {
		delete(first, l.allocator)
		return false
	}
	p := Polys{first = first, corners = make([]u32, corners_count, l.allocator), tri_poly = make([]u32, tcount, l.allocator)}
	s := Sharp{make([]u64, ecount, l.allocator), make([]f32, ecount, l.allocator), make([]u32, vcount, l.allocator), make([]f32, vcount, l.allocator)}
	saved := make([]u32, tcount, context.temp_allocator)
	geom.byte_get_slice(r, p.corners)
	geom.byte_get_slice(r, saved)
	geom.byte_get_slice(r, s.edges)
	geom.byte_get_slice(r, s.edge)
	geom.byte_get_slice(r, s.verts)
	geom.byte_get_slice(r, s.vert)
	vertices := u32(len(file_order))
	fits := r.ok
	for i in 0 ..< pcount do fits &&= first[i] < first[i + 1]
	for &c in p.corners {
		fits &&= c < vertices
		if fits do c = file_order[c]
	}
	for &t, i in p.tri_poly {
		t = saved[tri_from[i]]
		fits &&= int(t) < pcount
	}
	// Creases in the level's numbers, sorted again.
	Edge :: struct {
		key: u64,
		c:   f32,
	}
	edges := make([]Edge, ecount, context.temp_allocator)
	for key, i in s.edges {
		a, b := u32(key >> 32), u32(key & 0xffff_ffff)
		fits &&= a < vertices && b < vertices && a != b && s.edge[i] >= 0 && s.edge[i] <= INFINITE_SHARP // NaN too
		if fits do edges[i] = {sharp_key(file_order[a], file_order[b]), s.edge[i]}
	}
	slice.sort_by(edges, proc(x, y: Edge) -> bool {return x.key < y.key})
	for e, i in edges do s.edges[i], s.edge[i] = e.key, e.c
	Vert :: struct {
		v: u32,
		c: f32,
	}
	verts := make([]Vert, vcount, context.temp_allocator)
	for v, i in s.verts {
		fits &&= v < vertices && s.vert[i] >= 0 && s.vert[i] <= INFINITE_SHARP
		if fits do verts[i] = {file_order[v], s.vert[i]}
	}
	slice.sort_by(verts, proc(x, y: Vert) -> bool {return x.v < y.v})
	for v, i in verts do s.verts[i], s.vert[i] = v.v, v.c
	if !fits {
		polys_destroy(&p, l.allocator)
		sharp_destroy(&s, l.allocator)
		return false
	}
	return levels_set_polys(l, p, s, Subdivision_Rule(rule))
}
