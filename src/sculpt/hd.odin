package sculpt

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:sync"

import "../geom"
import "../jobs"

// HD detail, as ZBrush's HD geometry: sculpting `steps` Loop subdivisions above the top
// level without ever building that whole level. Each finer vertex's detail is its offset
// from where Loop subdivision of the top level puts it, in a frame that turns with that
// surface (as the levels' detail is), so it rides on later changes to the top level and
// the levels below. Detail is stored per node of the top level, and only for nodes that
// were sculpted: the rest cost nothing.
//
// It is sculpted one region at a time. levels_hd_enter builds a window: the finer
// subdivision of the top-level nodes nearest a point, up to a vertex budget, with their
// stored detail, as a level that sculpts like any other. Its border vertices never move,
// since the top level is drawn around it, and brushes fade out toward them so that a
// stroke across the border leaves a slope rather than a cliff. levels_hd_leave stores
// what changed and frees the window. Outside a window the detail is kept but not shown,
// as in ZBrush.
//
// A node stores the vertices of the finer triangles of its own triangles, each once
// within the node, in the order its triangles list them (its triangles in order, each
// one's grid points row by row: see hd_grid_index). A vertex on the border between two
// nodes is stored by both, always with the same detail.

HD_MAX_STEPS :: 3
// Default size of a window, in vertices.
HD_WINDOW_VERTICES :: 4_000_000
// How far in from a window's border brushes reach full strength, in top-level edges.
HD_FADE_EDGES :: 8

Hd :: struct {
	steps:  int,      // Loop steps above the top level; 0 when there is no HD level
	detail: [][]Vec3, // per node of the top level: its HD vertices' detail; nil while all zero
	window: ^Level,   // the region being sculpted, nil outside HD sculpting
	region: Hd_Region,
}

// What ties the window to the stored detail and to the top level.
@(private)
Hd_Region :: struct {
	nodes:  []u32,      // the top-level nodes the window covers, ascending
	lists:  Node_Lists, // per entry of nodes: its HD vertices (window numbering) in storage order
	home:   []u32,      // per window vertex: its first place in lists.items
	below:  Hd_Patch,   // the subdivision one step below the window, its frames' source
	hidden: []bool,     // per chunk and group of the top level: covered by the window
}

// Part of a Loop subdivision of the top level, built on its own. Its triangles are the
// top-level triangles within a few rings of a region in ascending order, then after
// each step the four children of each triangle in turn (level_above's split order), so
// after j steps a top-level triangle's descendants are a block of 4^j triangles. Every
// vertex's star then lists its triangles in the same order whatever region the patch
// was made for, which makes the points and frames read from it the same bits in every
// window: detail stored from one window decodes exactly in the next.
@(private)
Hd_Patch :: struct {
	positions: [dynamic]Vec3,
	indices:   [dynamic]u32,
	faces:     geom.Vertex_Faces,
}

@(private)
HD_NONE :: max(u32)

// Sets how many Loop steps above the top level HD detail lives; 0 removes the HD level.
// Returns false, changing nothing, while HD detail is stored or a window is open, or
// when the top level is not a closed manifold mesh (which Loop subdivision needs).
levels_hd_set_steps :: proc(l: ^Levels, wanted: int) -> bool {
	hd := &l.hd
	steps := clamp(wanted, 0, HD_MAX_STEPS)
	if steps == hd.steps do return true
	if hd.window != nil || levels_hd_stats(l).stored_nodes > 0 do return false
	top := l.levels[len(l.levels) - 1]
	if steps > 0 && !closed_manifold(&top.sculptor) do return false
	if steps == 0 {
		delete(hd.detail, l.allocator)
		hd.detail = nil
	} else if hd.detail == nil {
		hd.detail = make([][]Vec3, len(top.sculptor.nodes), l.allocator)
	}
	hd.steps = steps
	return true
}

// Removes the HD level with all its detail, and any window without storing it.
levels_hd_delete :: proc(l: ^Levels) {
	hd := &l.hd
	if hd.window != nil do hd_window_free(l)
	for d in hd.detail do delete(d, l.allocator)
	delete(hd.detail, l.allocator)
	hd^ = {}
}

// The level being sculpted and shown: the HD window while one is open, otherwise the
// current level.
levels_active :: proc(l: ^Levels) -> ^Level {
	if l.hd.window != nil do return l.hd.window
	return l.levels[l.current]
}

// Per chunk and simplification group of the top level, whether the open window draws
// it instead (true: leave it out); nil without a window.
levels_hd_hidden :: proc(l: ^Levels) -> []bool {
	return l.hd.region.hidden
}

// Vertices the whole HD level would have if it were built, with `steps` (by default the
// current number) above the top level.
levels_hd_vertices :: proc(l: ^Levels, steps := -1) -> int {
	top := l.levels[len(l.levels) - 1]
	v, t := len(top.mesh.positions), len(top.mesh.indices) / 3
	e := 3 * t / 2 // a closed mesh has 3/2 edges per triangle
	for _ in 0 ..< (steps if steps >= 0 else l.hd.steps) do v, e, t = v + e, 2 * e + 3 * t, 4 * t
	return v
}

Hd_Stats :: struct {
	stored_nodes:    int, // top-level nodes holding detail
	stored_vertices: int, // detail entries they hold
	stored_bytes:    int,
	window_vertices: int,
	window_nodes:    int, // top-level nodes the window covers
	window_bytes:    int, // the window's level and what ties it to the stored detail
}

levels_hd_stats :: proc(l: ^Levels) -> (st: Hd_Stats) {
	hd := &l.hd
	for d in hd.detail {
		if d == nil do continue
		st.stored_nodes += 1
		st.stored_vertices += len(d)
	}
	st.stored_bytes = st.stored_vertices * size_of(Vec3) + len(hd.detail) * size_of([]Vec3)
	if lv := hd.window; lv != nil {
		r := &hd.region
		st.window_vertices = len(lv.mesh.positions)
		st.window_nodes = len(r.nodes)
		st.window_bytes = level_bytes(lv) + len(lv.sculptor.fade) +
			(len(r.nodes) + len(r.lists.offsets) + len(r.lists.items) + len(r.home)) * size_of(u32) +
			len(r.below.positions) * size_of(Vec3) + len(r.below.indices) * size_of(u32) +
			(len(r.below.faces.offsets) + len(r.below.faces.tris)) * size_of(u32) + len(r.hidden)
	}
	return
}

// Opens a window for HD sculpting around `at` (in the mesh's space): the top level
// becomes current, and the window covers its nodes nearest `at` until it holds about
// `budget` vertices. The window is then the active level (levels_active), sculpted and
// shown in place of those nodes. Returns false without an HD level or with a window
// already open.
levels_hd_enter :: proc(l: ^Levels, at: Vec3, budget := HD_WINDOW_VERTICES) -> bool {
	hd := &l.hd
	if hd.steps == 0 || hd.window != nil do return false
	levels_set_current(l, len(l.levels) - 1)
	top := l.levels[len(l.levels) - 1]
	s := &top.sculptor
	m := &top.mesh
	k := hd.steps
	shift := uint(2 * k) // a top-level triangle has 4^k = 1 << shift descendants
	r := &hd.region

	// The region: whole nodes, nearest first, until the budget is reached.
	Near :: struct {
		distance: f32,
		id:       u32,
	}
	near := make([]Near, len(s.nodes), context.temp_allocator)
	for n, id in s.nodes do near[id] = {geom.box_distance(s.bvh.nodes[n.leaf].bounds, at), u32(id)}
	slice.sort_by(near, proc(a, b: Near) -> bool {return a.distance < b.distance || (a.distance == b.distance && a.id < b.id)})
	picked := make([]bool, len(s.nodes), context.temp_allocator)
	count, vertices := 0, 0
	for x in near {
		if vertices >= budget && count > 0 do break
		picked[x.id] = true
		count += 1
		vertices += int(s.nodes[x.id].tri_count) << shift / 2
	}
	r.nodes = make([]u32, count, l.allocator)
	count = 0
	for p, id in picked {
		if !p do continue
		r.nodes[count] = u32(id)
		count += 1
	}

	// The patch: the region's triangles and every triangle within k rings of them, which
	// is what k exact Loop steps over the region read.
	tcount := len(m.indices) / 3
	in_patch := make([]bool, tcount, context.temp_allocator)
	expanded := make([]bool, len(m.positions), context.temp_allocator)
	newest := make([dynamic]u32, 0, vertices >> shift * 2 + 64, context.temp_allocator)
	for id in r.nodes {
		n := s.nodes[id]
		for t in n.tri_first ..< n.tri_first + n.tri_count {
			in_patch[t] = true
			append(&newest, t)
		}
	}
	for _ in 0 ..< k {
		ring := make([dynamic]u32, 0, len(newest) / 4 + 64, context.temp_allocator)
		for t in newest {
			for c in u32(0) ..< 3 {
				v := m.indices[3 * t + c]
				if expanded[v] do continue
				expanded[v] = true
				for f in geom.vertex_faces_of(s.faces, v) {
					if in_patch[f] do continue
					in_patch[f] = true
					append(&ring, f)
				}
			}
		}
		newest = ring
	}
	local_of := make([]u32, len(m.positions), context.temp_allocator)
	slice.fill(local_of, HD_NONE)
	patch := Hd_Patch {
		positions = make([dynamic]Vec3, 0, len(newest) + vertices >> shift, l.allocator),
		indices   = make([dynamic]u32, 0, 3 * (len(newest) + 2 * vertices >> shift), l.allocator),
	}
	rank := make([dynamic]u32, 0, cap(patch.indices) / 3, context.temp_allocator) // per patch triangle: its place among the region's, or HD_NONE
	region_tris := make([dynamic]u32, 0, 2 * vertices >> shift + 64, context.temp_allocator) // the region's triangles, by rank
	for t in 0 ..< u32(tcount) {
		if !in_patch[t] do continue
		for c in u32(0) ..< 3 {
			v := m.indices[3 * t + c]
			if local_of[v] == HD_NONE {
				local_of[v] = u32(len(patch.positions))
				append(&patch.positions, m.positions[v])
			}
			append(&patch.indices, local_of[v])
		}
		if picked[s.node_of[s.bvh.tri_leaf[t]]] {
			append(&rank, u32(len(region_tris)))
			append(&region_tris, t)
		} else {
			append(&rank, HD_NONE)
		}
	}
	hd_patch_faces(&patch, l.pool, l.allocator)
	// Per region triangle: which of its edges (bit c: from corner c to the next) lie on
	// the border, between it and a triangle outside the region.
	Border :: struct {
		patch:  ^Hd_Patch,
		rank:   []u32,
		border: []u8,
	}
	bd := Border{&patch, rank[:], make([]u8, len(region_tris), context.temp_allocator)}
	jobs.parallel_ranges(l.pool, len(rank), &bd, proc(data: rawptr, lo, hi: int) {
		bd := cast(^Border)data
		for i in lo ..< hi {
			q := bd.rank[i]
			if q == HD_NONE do continue
			for c in 0 ..< 3 {
				twin, _ := hd_twin(bd.patch, bd.patch.indices[3 * i + c], bd.patch.indices[3 * i + (c + 1) % 3])
				if bd.rank[twin] == HD_NONE do bd.border[q] |= 1 << uint(c)
			}
		}
	}, 1 << 12)
	border_edges := 0
	for x in bd.border do border_edges += int(intrinsics.count_ones(x))
	for _ in 1 ..< k {
		next := hd_patch_next(&patch, l.pool, l.allocator)
		hd_patch_free(&patch, l.allocator)
		patch = next
	}
	r.below = patch

	// The last step, as topology only: the window keeps the region's descendants, and
	// its vertices also used by descendants of the triangles around it are its border.
	b := Hd_Build{k = k, shift = shift, rank = rank[:]}
	b.children, b.parents = hd_loop_step(&r.below, l.pool, context.temp_allocator)
	b.flags = make([]u8, len(b.parents), context.temp_allocator)
	jobs.parallel_ranges(l.pool, len(rank), &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Hd_Build)data
		for i in lo ..< hi {
			flag: u8 = 1 if b.rank[i] != HD_NONE else 2
			for c in b.children[3 * i << b.shift:][:3 << b.shift] do sync.atomic_or_explicit(&b.flags[c], flag, .Relaxed)
		}
	}, 1 << 12)
	b.window_of = make([]u32, len(b.parents), context.temp_allocator)
	wcount: u32
	for f, v in b.flags {
		b.window_of[v] = HD_NONE
		if f & 1 == 0 do continue
		b.window_of[v] = wcount
		wcount += 1
	}
	lv := new(Level, l.allocator)
	wm := &lv.mesh
	wm.positions = make([dynamic]Vec3, wcount, l.allocator)
	wm.normals = make([dynamic]Vec3, wcount, l.allocator)
	n := u32(1) << uint(k)
	wm.indices = make([dynamic]u32, 3 * (len(region_tris) << shift + border_edges * 2 * int(n - 1)), l.allocator)
	b.mesh = wm
	b.frozen = make([]bool, wcount, context.temp_allocator)
	b.window_parents = make([][4]u32, wcount, context.temp_allocator)
	b.grid_size = int((n + 1) * (n + 2) / 2)
	b.grid = make([]u32, len(region_tris) * b.grid_size, context.temp_allocator)
	// Per region triangle: its descendants' corners, renumbered for the window, and which
	// window vertex is at each of its grid points.
	jobs.parallel_ranges(l.pool, len(rank), &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Hd_Build)data
		mask := u32(1) << b.shift - 1
		for i in lo ..< hi {
			q := b.rank[i]
			if q == HD_NONE do continue
			first := u32(i) << b.shift
			out := b.mesh.indices[3 * (q << b.shift):]
			grid := b.grid[int(q) * b.grid_size:]
			for t in first ..< first + 1 << b.shift {
				corners := hd_grid_corners(t & mask, b.k)
				for c in u32(0) ..< 3 {
					w := b.window_of[b.children[3 * t + c]]
					out[3 * (t - first) + c] = w
					grid[hd_grid_index(corners[c], b.k)] = w
				}
			}
		}
	}, 1 << 10)
	jobs.parallel_ranges(l.pool, len(b.parents), &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Hd_Build)data
		for v in lo ..< hi {
			w := b.window_of[v]
			if w == HD_NONE do continue
			b.window_parents[w] = b.parents[v]
			b.frozen[w] = b.flags[v] & 2 != 0
		}
	}, geom.RANGE_GRAIN)
	// Seals: where the window has 2^k edges along a border edge, the top-level triangle
	// outside has one. However close the points between lie to it, drawing can leave
	// pinholes along such a join (T-junctions), so a fan of flat triangles from the
	// edge's first corner, both ways round for culling, covers the gap exactly.
	seals := wm.indices[3 * len(region_tris) << shift:]
	for edges, q in bd.border {
		grid := b.grid[q * b.grid_size:]
		for c in u32(0) ..< 3 {
			if edges & (1 << c) == 0 do continue
			first := grid[hd_grid_index(hd_edge_point(c, 0, n), k)]
			for i in 1 ..< n {
				p := grid[hd_grid_index(hd_edge_point(c, i, n), k)]
				p2 := grid[hd_grid_index(hd_edge_point(c, i + 1, n), k)]
				seals[0], seals[1], seals[2], seals[3], seals[4], seals[5] = first, p, p2, first, p2, p
				seals = seals[6:]
			}
		}
	}

	// Storage order: per node, the distinct window vertices of its triangles' grids.
	b.node_first = make([]u32, len(r.nodes) + 1, context.temp_allocator) // first rank
	for id, j in r.nodes do b.node_first[j + 1] = b.node_first[j] + s.nodes[id].tri_count
	b.lists = make([][]u32, len(r.nodes), context.temp_allocator)
	b.heap = runtime.heap_allocator()
	jobs.parallel_for(l.pool, len(r.nodes), &b, proc(data: rawptr, j: int) {
		b := cast(^Hd_Build)data
		lo, hi := int(b.node_first[j]) * b.grid_size, int(b.node_first[j + 1]) * b.grid_size
		b.lists[j] = distinct_in_order(b.grid[lo:hi], b.heap)
	})
	r.lists.offsets = make([]u32, len(r.nodes) + 1, l.allocator)
	for list, j in b.lists do r.lists.offsets[j + 1] = r.lists.offsets[j] + u32(len(list))
	r.lists.items = make([]u32, r.lists.offsets[len(r.nodes)], l.allocator)
	for list, j in b.lists {
		copy(r.lists.items[r.lists.offsets[j]:], list)
		delete(list, b.heap)
	}
	b.home = make([]u32, wcount, context.temp_allocator)
	slice.fill(b.home, HD_NONE)
	for w, idx in r.lists.items do if b.home[w] == HD_NONE do b.home[w] = u32(idx)

	// Positions: each vertex decoded once, from its first place in storage. The border,
	// which never moves, sits on the top level's triangles so it meets them exactly.
	b.hd = hd
	b.base = {r.below.positions[:], r.below.indices[:], r.below.faces}
	jobs.parallel_for(l.pool, len(r.nodes), &b, proc(data: rawptr, j: int) {
		b := cast(^Hd_Build)data
		r := &b.hd.region
		lo, hi := r.lists.offsets[j], r.lists.offsets[j + 1]
		store := b.hd.detail[r.nodes[j]]
		assert(store == nil || len(store) == int(hi - lo), "HD detail stored for another numbering")
		for idx in lo ..< hi {
			w := r.lists.items[idx]
			if b.home[w] != idx || b.frozen[w] do continue
			d := store[idx - lo] if store != nil else {}
			b.mesh.positions[w] = frame_point(frame_at(&b.base, b.window_parents[w]), d)
		}
	})
	placed := make([]bool, wcount, context.temp_allocator)
	for t, q in region_tris {
		A, B, C := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
		g := q * b.grid_size
		for v in u32(0) ..= n {
			for u in u32(0) ..= n - v {
				w := b.grid[g]
				g += 1
				if !b.frozen[w] || placed[w] do continue
				placed[w] = true
				// Corners exactly where the top level has them: A + (B - A) need not be B.
				wm.positions[w] = A if u + v == 0 else B if u == n else C if v == n else A + (B - A) * (f32(u) / f32(n)) + (C - A) * (f32(v) / f32(n))
			}
		}
	}
	// The window as a level: sculptor_init renumbers its vertices.
	b.old_to_new = make([]u32, wcount, context.temp_allocator)
	sculptor_init(&lv.sculptor, wm, l.pool, l.node_triangles, b.old_to_new, l.allocator)
	lv.parents = make([][4]u32, wcount, l.allocator)
	lv.sculptor.fade = make([]u8, wcount, l.allocator)
	r.home = make([]u32, wcount, l.allocator)
	b.lv = lv
	jobs.parallel_ranges(l.pool, int(wcount), &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Hd_Build)data
		for w in lo ..< hi {
			x := b.old_to_new[w]
			b.lv.parents[x] = b.window_parents[w]
			b.lv.sculptor.fade[x] = 0 if b.frozen[w] else 255
			b.hd.region.home[x] = b.home[w]
		}
	}, geom.RANGE_GRAIN)
	jobs.parallel_ranges(l.pool, len(r.lists.items), &b, proc(data: rawptr, lo, hi: int) {
		b := cast(^Hd_Build)data
		for &w in b.hd.region.lists.items[lo:hi] do w = b.old_to_new[w]
	}, geom.RANGE_GRAIN)
	lv.node_of_vertex = node_of_vertex_build(&lv.sculptor, l.allocator)
	sculptor_recompute_all(&lv.sculptor)
	// Brushes reach full strength HD_FADE_EDGES of the top level's edges in from the
	// border, or a quarter of the window's radius if that is less, so that a small
	// window keeps most of itself at full strength. Both are measured on a sample of
	// the region's triangles.
	edge, area: f32
	stride := max(len(region_tris) / 4096, 1)
	sampled := 0
	for i := 0; i < len(region_tris); i += stride {
		t := region_tris[i]
		A, B, C := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
		edge += linalg.length(B - A) + linalg.length(C - B) + linalg.length(A - C)
		area += 0.5 * linalg.length(linalg.cross(B - A, C - A))
		sampled += 1
	}
	edge /= f32(3 * sampled)
	area *= f32(len(region_tris)) / f32(sampled)
	// For scratch it takes window_parents, done with and already paged in: new memory
	// would fault a page in for each one the band touches.
	ramp := min(HD_FADE_EDGES * edge, 0.25 * math.sqrt(area / math.PI))
	hd_fade(&lv.sculptor, ramp, 4 << uint(k), slice.reinterpret([]u32, b.window_parents))

	// The top level leaves out what the window covers, and any group of chunks over it.
	units := len(s.nodes) + len(s.lod.tree.groups)
	r.hidden = make([]bool, units, l.allocator)
	for id in r.nodes {
		unit := id
		r.hidden[unit] = true
		for len(s.lod.parent) > 0 && s.lod.parent[unit] != LOD_NO_PARENT {
			unit = u32(len(s.nodes)) + s.lod.parent[unit]
			if r.hidden[unit] do break
			r.hidden[unit] = true
		}
	}
	hd.window = lv
	return true
}

// Shared by the jobs of levels_hd_enter.
@(private)
Hd_Build :: struct {
	hd:             ^Hd,
	k:              int,
	shift:          uint,
	rank:           []u32,      // per triangle of the top-level patch: its place among the region's, or HD_NONE
	base:           Loop_Base,
	children:       [dynamic]u32, // the last step's triangles
	parents:        [][4]u32,     // the last step's vertices' stencils
	flags:          []u8,         // per vertex of the last step: 1 used by the window, 2 used outside it
	window_of:      []u32,        // per vertex of the last step: its window vertex, or HD_NONE
	mesh:           ^geom.Mesh,
	frozen:         []bool,   // per window vertex (before sculptor_init renumbers them)
	window_parents: [][4]u32,
	grid_size:      int,
	grid:           []u32,    // per region triangle and grid point: the window vertex there
	node_first:     []u32,    // per region node: its first triangle's rank
	lists:          [][]u32,
	home:           []u32,
	heap:           runtime.Allocator,
	old_to_new:     []u32, // window vertex numbering before and after sculptor_init
	lv:             ^Level,
}

// Stores what the window changed as HD detail, then frees the window. Only vertices that
// moved are stored, so a node that was not sculpted keeps its detail bit for bit, and
// one that holds none and was not sculpted still holds none.
levels_hd_leave :: proc(l: ^Levels) {
	hd := &l.hd
	lv := hd.window
	if lv == nil do return
	r := &hd.region
	e := Hd_Leave{hd = hd, lv = lv, base = {r.below.positions[:], r.below.indices[:], r.below.faces}}
	e.changed = make([]bool, len(r.nodes), context.temp_allocator)
	jobs.parallel_for(l.pool, len(r.nodes), &e, proc(data: rawptr, j: int) {
		e := cast(^Hd_Leave)data
		r := &e.hd.region
		lo := r.lists.offsets[j]
		store := e.hd.detail[r.nodes[j]]
		for idx in lo ..< r.lists.offsets[j + 1] {
			if _, moved := hd_moved(e, r.lists.items[idx], store, idx - lo); moved {
				e.changed[j] = true
				return
			}
		}
	})
	for changed, j in e.changed {
		if changed && hd.detail[r.nodes[j]] == nil {
			hd.detail[r.nodes[j]] = make([]Vec3, len(node_list(r.lists, u32(j))), l.allocator)
		}
	}
	jobs.parallel_for(l.pool, len(r.nodes), &e, proc(data: rawptr, j: int) {
		e := cast(^Hd_Leave)data
		if !e.changed[j] do return
		r := &e.hd.region
		lo := r.lists.offsets[j]
		store := e.hd.detail[r.nodes[j]]
		for idx in lo ..< r.lists.offsets[j + 1] {
			w := r.lists.items[idx]
			f, moved := hd_moved(e, w, store, idx - lo)
			if !moved do continue
			off := e.lv.mesh.positions[w] - f.origin
			store[idx - lo] = {dot(f.t, off), dot(f.b, off), dot(f.n, off)}
		}
	})
	hd_window_free(l)
}

@(private)
Hd_Leave :: struct {
	hd:      ^Hd,
	lv:      ^Level,
	base:    Loop_Base,
	changed: []bool, // per region node
}

// Whether window vertex w is no longer where its stored detail (store[i], or zero
// without a store) puts it, and its frame. Border vertices never count, nor do
// vertices of nodes no stroke reached.
@(private)
hd_moved :: proc(e: ^Hd_Leave, w: u32, store: []Vec3, i: u32) -> (f: Frame, moved: bool) {
	lv := e.lv
	if lv.sculptor.fade[w] == 0 || !lv.sculptor.edited[lv.node_of_vertex[w]] do return
	f = frame_at(&e.base, lv.parents[w])
	d := store[i] if store != nil else {}
	return f, frame_point(f, d) != lv.mesh.positions[w]
}

@(private)
dot :: #force_inline proc(a, b: Vec3) -> f32 {return a.x * b.x + a.y * b.y + a.z * b.z}

// Ramps s.fade (0 on the border, 255 elsewhere) up from the border to full strength
// `ramp` away from it, along a smoothstep so the rise has no crease at either end. The
// distance is to the nearest border vertex, found by passing nearest vertices on from
// neighbour to neighbour, then smoothed `smoothing` times: the border zig-zags along the
// top level's edges, and unsmoothed distances carry that zig-zag inward as ridges.
// `scratch` holds three values per vertex, and need not be cleared.
//
// A vertex's neighbours are the corners after it in its triangles, each in exactly one
// since every fan in the window is closed and turns one way, except on the border, whose
// open fans leave out a neighbour on the border.
@(private)
hd_fade :: proc(s: ^Sculptor, ramp: f32, smoothing: int, scratch: []u32) {
	fade := s.fade
	positions := s.mesh.positions[:]
	indices := s.mesh.indices[:]
	// Only read where fade marks a vertex as on the border or reached.
	n := len(fade)
	assert(len(scratch) >= 3 * n, "too little scratch")
	distance := slice.reinterpret([]f32, scratch[:n])
	nearest := scratch[n:][:n]
	slot := scratch[2 * n:][:n] // a band vertex's place in the band
	order := make([dynamic]u32, 0, 4096, context.temp_allocator) // the border, then the band as reached
	for f, v in fade {
		if f != 0 do continue
		distance[v] = 0
		nearest[v] = u32(v)
		append(&order, u32(v))
	}
	border := len(order)
	reached := make([dynamic]u32, 0, 32 * border, context.temp_allocator)
	for lo := 0; lo < len(order); {
		hi := len(order)
		for i in lo ..< hi {
			v := order[i]
			from := nearest[v]
			for f in geom.vertex_faces_of(s.faces, v) {
				c, _ := others(indices, f, v)
				if fade[c] == 0 do continue
				d := linalg.length(positions[c] - positions[from])
				if fade[c] == 255 {
					append(&reached, c)
					fade[c] = HD_FADE_REACHED
					if d < ramp {
						fade[c] = HD_FADE_BAND
						slot[c] = u32(len(order) - border)
						append(&order, c)
					}
				} else if d >= distance[c] {
					continue
				}
				distance[c] = d
				nearest[c] = from
			}
		}
		lo = hi
	}

	// Each band vertex moves to the mean of its neighbours. The border and the vertices
	// past the ramp stay put, so they only add a constant.
	band := order[border:]
	sm := Hd_Smooth{s = s, band = band, distance = distance, slot = slot}
	sm.offsets = make([]u32, len(band) + 1, context.temp_allocator)
	for v, i in band do sm.offsets[i + 1] = sm.offsets[i] + s.faces.offsets[v + 1] - s.faces.offsets[v]
	sm.items = make([]u32, sm.offsets[len(band)], context.temp_allocator)
	sm.fixed = make([]f32, len(band), context.temp_allocator)
	sm.from = make([]f32, len(band) + 1, context.temp_allocator)
	sm.to = make([]f32, len(band) + 1, context.temp_allocator)
	jobs.parallel_ranges(s.pool, len(band), &sm, proc(data: rawptr, lo, hi: int) {
		sm := cast(^Hd_Smooth)data
		s := sm.s
		outside := u32(len(sm.band))
		for i in lo ..< hi {
			v := sm.band[i]
			items := sm.items[sm.offsets[i]:]
			sum: f32
			for f, j in geom.vertex_faces_of(s.faces, v) {
				c, _ := others(s.mesh.indices[:], f, v)
				if s.fade[c] == HD_FADE_BAND {
					items[j] = sm.slot[c]
				} else {
					items[j] = outside
					sum += sm.distance[c]
				}
			}
			sm.fixed[i] = sum
			sm.from[i] = sm.distance[v]
		}
	}, 1 << 12)
	for _ in 0 ..< smoothing {
		jobs.parallel_ranges(s.pool, len(band), &sm, proc(data: rawptr, lo, hi: int) {
			sm := cast(^Hd_Smooth)data
			for i in lo ..< hi {
				first, last := sm.offsets[i], sm.offsets[i + 1]
				sum := sm.fixed[i]
				for j in sm.items[first:last] do sum += sm.from[j]
				sm.to[i] = sum / f32(last - first)
			}
		}, 1 << 12)
		sm.from, sm.to = sm.to, sm.from
	}
	for v, i in band do distance[v] = sm.from[i]
	for v in reached {
		t := min(distance[v] / ramp, 1)
		fade[v] = u8(clamp(math.round(255 * t * t * (3 - 2 * t)), 1, 255))
	}
}

// Until hd_fade ends, s.fade also marks the vertices it reached: those under `ramp`
// from the border (the band, whose neighbours it reached in turn) and those further.
@(private)
HD_FADE_BAND :: 253
@(private)
HD_FADE_REACHED :: 254

@(private)
Hd_Smooth :: struct {
	s:              ^Sculptor,
	band:           []u32,
	distance:       []f32,
	slot:           []u32,
	offsets, items: []u32, // per band vertex: its neighbours' places in the band, len(band) for one outside it
	fixed:          []f32, // per band vertex: the sum of its neighbours outside the band
	from, to:       []f32, // per band vertex, then a 0 for the neighbours outside it
}

@(private)
hd_window_free :: proc(l: ^Levels) {
	hd := &l.hd
	r := &hd.region
	lv := hd.window
	sculptor_destroy(&lv.sculptor)
	geom.mesh_destroy(&lv.mesh)
	delete(lv.node_of_vertex, l.allocator)
	delete(lv.parents, l.allocator)
	free(lv, l.allocator)
	delete(r.nodes, l.allocator)
	delete(r.lists.offsets, l.allocator)
	delete(r.lists.items, l.allocator)
	delete(r.home, l.allocator)
	delete(r.hidden, l.allocator)
	hd_patch_free(&r.below, l.allocator)
	r^ = {}
	hd.window = nil
}

// One Loop step of a patch: its triangles' children and the next patch's positions.
@(private)
hd_patch_next :: proc(below: ^Hd_Patch, pool: ^jobs.Pool, allocator: runtime.Allocator) -> (p: Hd_Patch) {
	Next :: struct {
		base:      Loop_Base,
		parents:   [][4]u32,
		positions: []Vec3,
	}
	x := Next{base = {below.positions[:], below.indices[:], below.faces}}
	p.indices, x.parents = hd_loop_step(below, pool, allocator)
	p.positions = make([dynamic]Vec3, len(x.parents), allocator)
	x.positions = p.positions[:]
	jobs.parallel_ranges(pool, len(x.parents), &x, proc(data: rawptr, lo, hi: int) {
		x := cast(^Next)data
		for i in lo ..< hi do x.positions[i] = frame_at(&x.base, x.parents[i]).origin
	}, geom.RANGE_GRAIN)
	delete(x.parents, allocator)
	hd_patch_faces(&p, pool, allocator)
	return
}

@(private)
hd_patch_faces :: proc(p: ^Hd_Patch, pool: ^jobs.Pool, allocator: runtime.Allocator) {
	p.faces = geom.vertex_faces_build(geom.Mesh{positions = p.positions, indices = p.indices}, pool, allocator)
}

@(private)
hd_patch_free :: proc(p: ^Hd_Patch, allocator: runtime.Allocator) {
	delete(p.positions)
	delete(p.indices)
	geom.vertex_faces_destroy(&p.faces, allocator)
	p^ = {}
}

// One step of Loop subdivision of a patch, as topology: four triangles for each of its
// triangles, in level_above's split order, and each new vertex's stencil (as
// Level.parents): the patch's vertices keep their numbers, and its edges follow. An
// edge is numbered by the lower numbered of its two triangles, and its stencil runs the
// edge the way that triangle does, so no stencil depends on how vertices are numbered.
// Stencils of vertices at the patch's border are wrong (an edge there has one triangle,
// a vertex there a partial star): the patch reaches far enough that none of those
// vertices are used.
@(private)
hd_loop_step :: proc(below: ^Hd_Patch, pool: ^jobs.Pool, allocator: runtime.Allocator) -> (indices: [dynamic]u32, parents: [][4]u32) {
	Step :: struct {
		below:       ^Hd_Patch,
		edge_first:  []u32, // per triangle: the first edge it numbers
		corner_edge: []u32, // per corner: the edge from it to the next corner
		parents:     [][4]u32,
		out:         []u32,
	}
	vcount, tcount := len(below.positions), len(below.indices) / 3
	st := Step{below = below}
	st.edge_first = make([]u32, tcount + 1, context.temp_allocator)
	st.corner_edge = make([]u32, 3 * tcount, context.temp_allocator)
	jobs.parallel_ranges(pool, tcount, &st, proc(data: rawptr, lo, hi: int) {
		st := cast(^Step)data
		I := st.below.indices[:]
		for t in u32(lo) ..< u32(hi) {
			count: u32
			for c in u32(0) ..< 3 {
				twin, _ := hd_twin(st.below, I[3 * t + c], I[3 * t + (c + 1) % 3])
				count += u32(twin == HD_NONE || t < twin)
			}
			st.edge_first[t + 1] = count
		}
	}, geom.RANGE_GRAIN)
	for t in 0 ..< tcount do st.edge_first[t + 1] += st.edge_first[t]
	parents = make([][4]u32, vcount + int(st.edge_first[tcount]), allocator)
	st.parents = parents
	jobs.parallel_ranges(pool, tcount, &st, proc(data: rawptr, lo, hi: int) {
		st := cast(^Step)data
		I := st.below.indices[:]
		vcount := u32(len(st.below.positions))
		for t in u32(lo) ..< u32(hi) {
			next := st.edge_first[t]
			for c in u32(0) ..< 3 {
				v, w, x := I[3 * t + c], I[3 * t + (c + 1) % 3], I[3 * t + (c + 2) % 3]
				twin, d := hd_twin(st.below, v, w)
				if twin != HD_NONE && twin < t do continue
				st.corner_edge[3 * t + c] = next
				if twin == HD_NONE {
					st.parents[vcount + next] = {v, w, x, x}
				} else {
					st.parents[vcount + next] = {v, w, x, d}
					st.corner_edge[3 * twin + corner_of(I, twin, w)] = next
				}
				next += 1
			}
		}
	}, geom.RANGE_GRAIN)
	jobs.parallel_ranges(pool, vcount, &st, proc(data: rawptr, lo, hi: int) {
		st := cast(^Step)data
		for v in u32(lo) ..< u32(hi) {
			first, _ := others(st.below.indices[:], geom.vertex_faces_of(st.below.faces, v)[0], v)
			st.parents[v] = {v, first, EVEN, 0}
		}
	}, geom.RANGE_GRAIN)
	indices = make([dynamic]u32, 12 * tcount, allocator)
	st.out = indices[:]
	jobs.parallel_ranges(pool, tcount, &st, proc(data: rawptr, lo, hi: int) {
		st := cast(^Step)data
		I := st.below.indices[:]
		vcount := u32(len(st.below.positions))
		for t in lo ..< hi {
			i0, i1, i2 := I[3 * t], I[3 * t + 1], I[3 * t + 2]
			e01 := vcount + st.corner_edge[3 * t]
			e12 := vcount + st.corner_edge[3 * t + 1]
			e20 := vcount + st.corner_edge[3 * t + 2]
			out := st.out[12 * t:]
			out[0], out[1], out[2] = i0, e01, e20
			out[3], out[4], out[5] = i1, e12, e01
			out[6], out[7], out[8] = i2, e20, e12
			out[9], out[10], out[11] = e01, e12, e20
		}
	}, geom.RANGE_GRAIN)
	return
}

// The triangle of the patch running edge v-w the other way (w, then v) and its third
// corner; HD_NONE when the patch has none.
@(private)
hd_twin :: #force_inline proc(p: ^Hd_Patch, v, w: u32) -> (twin, d: u32) {
	for g in geom.vertex_faces_of(p.faces, w) {
		o1, o2 := others(p.indices[:], g, w)
		if o1 == v do return g, o2
	}
	return HD_NONE, 0
}

// Grid coordinates (u along the triangle's first edge, v along its last, in steps of
// 1/2^k of an edge) of the corners of the descendant of a top-level triangle reached by
// `path`: two bits per step, the first step highest, each the child's place in
// level_above's split order.
@(private)
hd_grid_corners :: proc(path: u32, k: int) -> (c: [3][2]u32) {
	c = {{0, 0}, {1, 0}, {0, 1}}
	for j in 1 ..= k {
		m01, m12, m20 := c[0] + c[1], c[1] + c[2], c[2] + c[0]
		switch (path >> uint(2 * (k - j))) & 3 {
		case 0:
			c = {2 * c[0], m01, m20}
		case 1:
			c = {2 * c[1], m12, m01}
		case 2:
			c = {2 * c[2], m20, m12}
		case:
			c = {m01, m12, m20}
		}
	}
	return
}

// Grid point i steps (of n) along edge c of a triangle: from corner c to the next.
@(private)
hd_edge_point :: #force_inline proc(c, i, n: u32) -> [2]u32 {
	switch c {
	case 0:
		return {i, 0}
	case 1:
		return {n - i, i}
	}
	return {0, n - i}
}

// Place of grid point uv in a triangle's grid of (n+1)(n+2)/2 points, n = 2^k: row by
// row along the triangle's first edge, starting at its first corner.
@(private)
hd_grid_index :: #force_inline proc(uv: [2]u32, k: int) -> u32 {
	n := u32(1) << uint(k)
	u, v := uv[0], uv[1]
	return v * (2 * n + 3 - v) / 2 + u
}

// Whether every edge lies between exactly two triangles that run it in opposite
// directions: a closed, consistently oriented manifold, which Loop subdivision needs.
@(private)
closed_manifold :: proc(s: ^Sculptor) -> bool {
	Check :: struct {
		s:   ^Sculptor,
		bad: bool, // atomic
	}
	c := Check{s = s}
	jobs.parallel_ranges(s.pool, len(s.mesh.positions), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Check)data
		indices := c.s.mesh.indices[:]
		for v in u32(lo) ..< u32(hi) {
			faces := geom.vertex_faces_of(c.s.faces, v)
			if len(faces) < 3 {
				sync.atomic_store(&c.bad, true)
				return
			}
			// As in level_above: one triangle with v followed by w, one with w then v.
			for f in faces {
				w, _ := others(indices, f, v)
				same, twins := 0, 0
				for g in faces {
					g1, g2 := others(indices, g, v)
					same += int(g1 == w)
					twins += int(g2 == w)
				}
				if w == v || same != 1 || twins != 1 {
					sync.atomic_store(&c.bad, true)
					return
				}
			}
		}
	}, geom.RANGE_GRAIN)
	return !c.bad
}
