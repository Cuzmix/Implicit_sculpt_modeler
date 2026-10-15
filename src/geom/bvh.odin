package geom

import "base:intrinsics"
import "core:math"
import "core:math/linalg"

import "../jobs"

Aabb :: struct {
	lo, hi: Vec3,
}

AABB_EMPTY :: Aabb{{max(f32), max(f32), max(f32)}, {min(f32), min(f32), min(f32)}}

aabb_grow :: #force_inline proc(b: ^Aabb, p: Vec3) {
	b.lo = linalg.min(b.lo, p)
	b.hi = linalg.max(b.hi, p)
}

aabb_union :: #force_inline proc(a, b: Aabb) -> Aabb {
	return {linalg.min(a.lo, b.lo), linalg.max(a.hi, b.hi)}
}

aabb_area :: #force_inline proc(b: Aabb) -> f32 {
	e := b.hi - b.lo
	return e.x * e.y + e.y * e.z + e.z * e.x
}

// Internal nodes store their children as a pair at `first` and `first + 1`.
// Leaves store `count` triangles at tri_order[first:first+count].
Bvh_Node :: struct {
	bounds: Aabb,
	first:  u32,
	count:  u32, // 0 for internal nodes
	parent: u32, // BVH_NONE for the root
}

BVH_NONE :: max(u32)
BVH_LEAF_SIZE :: 4

// Bounding volume hierarchy over a mesh's triangles. Topology is fixed after the
// build; when vertices move, bvh_refit_triangles updates only the affected branches.
Bvh :: struct {
	nodes:     [dynamic]Bvh_Node,
	tri_order: []u32, // triangle ids grouped by leaf
	tri_leaf:  []u32, // triangle id -> leaf node index
	stack:     [dynamic]u32, // traversal scratch, reused
	dirty:     []u64,        // refit scratch: one bit per node, all zero between refits
	leaf_size: u32,          // max triangles per leaf
}

bvh_destroy :: proc(b: ^Bvh) {
	delete(b.nodes)
	delete(b.tri_order)
	delete(b.tri_leaf)
	delete(b.stack)
	delete(b.dirty)
	b^ = {}
}

tri_bounds :: #force_inline proc(m: Mesh, tri: u32) -> Aabb {
	b := AABB_EMPTY
	aabb_grow(&b, m.positions[m.indices[3 * tri]])
	aabb_grow(&b, m.positions[m.indices[3 * tri + 1]])
	aabb_grow(&b, m.positions[m.indices[3 * tri + 2]])
	return b
}

// Builds with binned surface area heuristic splits on the widest centroid axis.
bvh_build :: proc(m: Mesh, leaf_size: u32 = BVH_LEAF_SIZE, allocator := context.allocator) -> Bvh {
	tcount := len(m.indices) / 3
	b := Bvh {
		leaf_size = max(leaf_size, 1),
		nodes     = make([dynamic]Bvh_Node, 0, max(2 * tcount / int(max(leaf_size, 1)), 1), allocator),
		tri_order = make([]u32, tcount, allocator),
		tri_leaf  = make([]u32, tcount, allocator),
		stack     = make([dynamic]u32, 0, 64, allocator),
	}
	centroids := make([]Vec3, tcount, context.temp_allocator)
	bounds := make([]Aabb, tcount, context.temp_allocator)
	for t in 0 ..< tcount {
		b.tri_order[t] = u32(t)
		bounds[t] = tri_bounds(m, u32(t))
		centroids[t] = (bounds[t].lo + bounds[t].hi) * 0.5
	}
	append(&b.nodes, Bvh_Node{first = 0, count = u32(tcount), parent = BVH_NONE})
	if tcount > 0 {
		subdivide(&b, 0, centroids, bounds)
	}
	b.dirty = make([]u64, (len(b.nodes) + 63) / 64, allocator)
	return b
}

@(private)
BINS :: 12

@(private)
subdivide :: proc(b: ^Bvh, node_index: u32, centroids: []Vec3, bounds: []Aabb) {
	node := &b.nodes[node_index]
	first, count := node.first, node.count
	node.bounds = AABB_EMPTY
	cbounds := AABB_EMPTY
	for i in first ..< first + count {
		t := b.tri_order[i]
		node.bounds = aabb_union(node.bounds, bounds[t])
		aabb_grow(&cbounds, centroids[t])
	}

	make_leaf :: proc(b: ^Bvh, node_index, first, count: u32) {
		for i in first ..< first + count {
			b.tri_leaf[b.tri_order[i]] = node_index
		}
	}
	if count <= b.leaf_size {
		make_leaf(b, node_index, first, count)
		return
	}

	extent := cbounds.hi - cbounds.lo
	axis := 0
	if extent.y > extent[axis] do axis = 1
	if extent.z > extent[axis] do axis = 2
	if extent[axis] <= 0 { 	// all centroids coincide: cannot split
		make_leaf(b, node_index, first, count)
		return
	}

	// Bin centroids along the axis and pick the cheapest split plane.
	Bin :: struct {
		bounds: Aabb,
		count:  u32,
	}
	bins: [BINS]Bin
	for &bin in bins do bin.bounds = AABB_EMPTY
	scale := f32(BINS) / extent[axis]
	bin_of :: #force_inline proc(c, lo, scale: f32) -> int {
		return min(int((c - lo) * scale), BINS - 1)
	}
	for i in first ..< first + count {
		t := b.tri_order[i]
		k := bin_of(centroids[t][axis], cbounds.lo[axis], scale)
		bins[k].bounds = aabb_union(bins[k].bounds, bounds[t])
		bins[k].count += 1
	}
	left_area, right_area: [BINS - 1]f32
	left_count, right_count: [BINS - 1]u32
	lb, rb := AABB_EMPTY, AABB_EMPTY
	lc, rc: u32
	for k in 0 ..< BINS - 1 {
		lc += bins[k].count
		lb = aabb_union(lb, bins[k].bounds)
		left_count[k], left_area[k] = lc, aabb_area(lb) if lc > 0 else 0
		j := BINS - 1 - k
		rc += bins[j].count
		rb = aabb_union(rb, bins[j].bounds)
		right_count[j - 1], right_area[j - 1] = rc, aabb_area(rb) if rc > 0 else 0
	}
	best_cost := max(f32)
	best_split := 0
	for k in 0 ..< BINS - 1 {
		cost := left_area[k] * f32(left_count[k]) + right_area[k] * f32(right_count[k])
		if left_count[k] > 0 && right_count[k] > 0 && cost < best_cost {
			best_cost, best_split = cost, k
		}
	}
	if best_cost == max(f32) {
		make_leaf(b, node_index, first, count)
		return
	}

	// Partition triangles: bins 0..best_split go left.
	i, j := first, first + count - 1
	for i <= j {
		if bin_of(centroids[b.tri_order[i]][axis], cbounds.lo[axis], scale) <= best_split {
			i += 1
		} else {
			b.tri_order[i], b.tri_order[j] = b.tri_order[j], b.tri_order[i]
			if j == 0 do break
			j -= 1
		}
	}
	left_n := i - first

	children := u32(len(b.nodes))
	append(&b.nodes, Bvh_Node{first = first, count = left_n, parent = node_index})
	append(&b.nodes, Bvh_Node{first = first + left_n, count = count - left_n, parent = node_index})
	node = &b.nodes[node_index] // append may have moved the array
	node.first, node.count = children, 0
	subdivide(b, children, centroids, bounds)
	subdivide(b, children + 1, centroids, bounds)
}

// Recomputes the bounds of every leaf holding one of `tris`, then of their ancestors,
// each node once. Cost scales with the triangles changed, not with the mesh.
bvh_refit_triangles :: proc(b: ^Bvh, m: Mesh, tris: []u32) {
	leaves := make([dynamic]u32, 0, len(tris), context.temp_allocator)
	for t in tris do append(&leaves, b.tri_leaf[t])
	bvh_refit_leaves(b, m, leaves[:])
}

// Recomputes the bounds of the given leaves (duplicates allowed) from their triangles,
// then of every ancestor, each node once.
bvh_refit_leaves :: proc(b: ^Bvh, m: Mesh, leaves: []u32, recompute_leaves := true) {
	lo_word, hi_word := len(b.dirty), 0
	for leaf in leaves {
		// Walk up until reaching a node another leaf already marked.
		for n := leaf; n != BVH_NONE; n = b.nodes[n].parent {
			word, bit := n >> 6, u64(1) << (n & 63)
			if b.dirty[word] & bit != 0 do break
			b.dirty[word] |= bit
			lo_word, hi_word = min(lo_word, int(word)), max(hi_word, int(word))
		}
	}
	// Children always have larger indices than their parent, so visiting marked nodes
	// from the highest index down reads final child bounds at every internal node.
	for w := hi_word; w >= lo_word; w -= 1 {
		for bits := b.dirty[w]; bits != 0; {
			top := 63 - intrinsics.count_leading_zeros(bits)
			bits &~= u64(1) << top
			node := &b.nodes[w * 64 + int(top)]
			if node.count > 0 {
				if recompute_leaves do node.bounds = leaf_bounds(b^, m, node^)
			} else {
				node.bounds = aabb_union(b.nodes[node.first].bounds, b.nodes[node.first + 1].bounds)
			}
		}
		b.dirty[w] = 0
	}
}

leaf_bounds :: proc(b: Bvh, m: Mesh, node: Bvh_Node) -> Aabb {
	bounds := AABB_EMPTY
	for i in node.first ..< node.first + node.count {
		bounds = aabb_union(bounds, tri_bounds(m, b.tri_order[i]))
	}
	return bounds
}

@(private)
ray_aabb :: #force_inline proc(bounds: Aabb, origin, inv_dir: Vec3, t_max: f32) -> (t_enter: f32, ok: bool) {
	t0 := (bounds.lo - origin) * inv_dir
	t1 := (bounds.hi - origin) * inv_dir
	tmin := linalg.min(t0, t1)
	tmax := linalg.max(t0, t1)
	enter := max(tmin.x, tmin.y, tmin.z, 0)
	exit := min(tmax.x, tmax.y, tmax.z, t_max)
	return enter, enter <= exit
}

// Nearest hit along the ray (both triangle faces), visiting the closer child first.
bvh_raycast :: proc(b: ^Bvh, m: Mesh, origin, dir: Vec3) -> (t: f32, tri: u32, ok: bool) {
	if len(b.nodes) == 0 || b.nodes[0].bounds.lo.x > b.nodes[0].bounds.hi.x do return
	inv_dir := Vec3{1 / dir.x, 1 / dir.y, 1 / dir.z}
	best := max(f32)
	clear(&b.stack)
	append(&b.stack, 0)
	for len(b.stack) > 0 {
		node := b.nodes[pop(&b.stack)]
		if _, hit := ray_aabb(node.bounds, origin, inv_dir, best); !hit do continue
		if node.count > 0 {
			for i in node.first ..< node.first + node.count {
				id := b.tri_order[i]
				if d, hit := ray_triangle(m, id, origin, dir); hit && d < best {
					best, tri, ok = d, id, true
				}
			}
			continue
		}
		l, r := node.first, node.first + 1
		tl, hl := ray_aabb(b.nodes[l].bounds, origin, inv_dir, best)
		tr, hr := ray_aabb(b.nodes[r].bounds, origin, inv_dir, best)
		// Push the far child first so the near one is popped next.
		if hl && hr {
			if tl <= tr {
				append(&b.stack, r, l)
			} else {
				append(&b.stack, l, r)
			}
		} else if hl {
			append(&b.stack, l)
		} else if hr {
			append(&b.stack, r)
		}
	}
	t = best
	return
}

// Moller-Trumbore; returns the distance along `dir` for a hit in front of the origin.
ray_triangle :: #force_inline proc(m: Mesh, tri: u32, origin, dir: Vec3) -> (t: f32, ok: bool) {
	p0 := m.positions[m.indices[3 * tri]]
	e1 := m.positions[m.indices[3 * tri + 1]] - p0
	e2 := m.positions[m.indices[3 * tri + 2]] - p0
	pv := linalg.cross(dir, e2)
	det := linalg.dot(e1, pv)
	if math.abs(det) < 1e-12 do return
	inv := 1 / det
	tv := origin - p0
	u := linalg.dot(tv, pv) * inv
	if u < 0 || u > 1 do return
	qv := linalg.cross(tv, e1)
	v := linalg.dot(dir, qv) * inv
	if v < 0 || u + v > 1 do return
	t = linalg.dot(e2, qv) * inv
	return t, t > 0
}

// Appends every triangle whose leaf bounds overlap the sphere (a superset of the
// triangles that actually touch it).
bvh_query_sphere :: proc(b: ^Bvh, center: Vec3, radius: f32, out: ^[dynamic]u32) {
	if len(b.nodes) == 0 do return
	r2 := radius * radius
	clear(&b.stack)
	append(&b.stack, 0)
	for len(b.stack) > 0 {
		node := b.nodes[pop(&b.stack)]
		closest := linalg.clamp(center, node.bounds.lo, node.bounds.hi)
		d := closest - center
		if linalg.dot(d, d) > r2 do continue
		if node.count > 0 {
			append(out, ..b.tri_order[node.first:node.first + node.count])
		} else {
			append(&b.stack, node.first, node.first + 1)
		}
	}
}

// Appends the index of every leaf whose bounds overlap the sphere.
bvh_query_leaves :: proc(b: ^Bvh, center: Vec3, radius: f32, out: ^[dynamic]u32) {
	if len(b.nodes) == 0 do return
	r2 := radius * radius
	clear(&b.stack)
	append(&b.stack, 0)
	for len(b.stack) > 0 {
		n := pop(&b.stack)
		node := b.nodes[n]
		closest := linalg.clamp(center, node.bounds.lo, node.bounds.hi)
		d := closest - center
		if linalg.dot(d, d) > r2 do continue
		if node.count > 0 {
			append(out, n)
		} else {
			append(&b.stack, node.first, node.first + 1)
		}
	}
}

// Linear BVH build: sorts triangles along a Morton curve with a radix sort and splits
// ranges at the highest differing code bit. Linear time apart from the sort, so it
// builds 20M triangles in well under a second; split quality is lower than SAH, which
// matters little with large leaves that are scanned linearly anyway.
bvh_build_morton :: proc(m: Mesh, leaf_size: u32 = BVH_LEAF_SIZE, pool: ^jobs.Pool = nil, allocator := context.allocator) -> Bvh {
	tcount := len(m.indices) / 3
	leaf := max(leaf_size, 1)
	b := Bvh {
		leaf_size = leaf,
		nodes     = make([dynamic]Bvh_Node, 0, max(4 * tcount / int(leaf), 1), allocator),
		tri_order = make([]u32, tcount, allocator),
		tri_leaf  = make([]u32, tcount, allocator),
		stack     = make([dynamic]u32, 0, 64, allocator),
	}
	if tcount == 0 {
		b.dirty = make([]u64, 1, allocator)
		return b
	}

	Codes :: struct {
		m:      Mesh,
		b:      ^Bvh,
		codes:  []u32,
		lo:     Vec3,
		scale:  f32,
		bounds: []Aabb, // per chunk of positions
	}
	c := Codes{m = m, b = &b, codes = make([]u32, tcount, context.temp_allocator)}
	c.bounds = make([]Aabb, (len(m.positions) + RANGE_GRAIN - 1) / RANGE_GRAIN, context.temp_allocator)
	jobs.parallel_ranges(pool, len(m.positions), &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Codes)data
		bounds := AABB_EMPTY
		for p in c.m.positions[lo:hi] do aabb_grow(&bounds, p)
		c.bounds[lo / RANGE_GRAIN] = bounds
	}, RANGE_GRAIN)
	scene := AABB_EMPTY
	for bounds in c.bounds do scene = aabb_union(scene, bounds)
	extent := scene.hi - scene.lo
	c.lo, c.scale = scene.lo, 1023 / max(extent.x, extent.y, extent.z, 1e-12)
	jobs.parallel_ranges(pool, tcount, &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Codes)data
		m := c.m
		for t in lo ..< hi {
			p0, p1, p2 := m.positions[m.indices[3 * t]], m.positions[m.indices[3 * t + 1]], m.positions[m.indices[3 * t + 2]]
			q := ((p0 + p1 + p2) * (1.0 / 3) - c.lo) * c.scale
			c.codes[t] = morton3(u32(q.x), u32(q.y), u32(q.z))
			c.b.tri_order[t] = u32(t)
		}
	}, RANGE_GRAIN)
	radix_sort_pairs(c.codes, b.tri_order, 30, pool)

	append(&b.nodes, Bvh_Node{first = 0, count = u32(tcount), parent = BVH_NONE})
	build_morton_node(&b, m, c.codes, 0)
	b.dirty = make([]u64, (len(b.nodes) + 63) / 64, allocator)
	return b
}

// Chunk size for flat parallel loops over vertices or triangles.
RANGE_GRAIN :: 1 << 16

@(private)
build_morton_node :: proc(b: ^Bvh, m: Mesh, codes: []u32, node_index: u32) {
	node := b.nodes[node_index]
	first, count := node.first, node.count
	if count <= b.leaf_size {
		bounds := AABB_EMPTY
		for i in first ..< first + count {
			bounds = aabb_union(bounds, tri_bounds(m, b.tri_order[i]))
			b.tri_leaf[b.tri_order[i]] = node_index
		}
		b.nodes[node_index].bounds = bounds
		return
	}
	last := first + count - 1
	split := first + count / 2 // identical codes: split in the middle
	if diff := codes[first] ~ codes[last]; diff != 0 {
		bit := u32(1) << (31 - intrinsics.count_leading_zeros(diff))
		// First index whose code has `bit` set; codes are sorted, so binary search.
		lo, hi := first, last
		for lo < hi {
			mid := (lo + hi) / 2
			if codes[mid] & bit != 0 {
				hi = mid
			} else {
				lo = mid + 1
			}
		}
		split = lo
	}
	children := u32(len(b.nodes))
	append(&b.nodes, Bvh_Node{first = first, count = split - first, parent = node_index})
	append(&b.nodes, Bvh_Node{first = split, count = first + count - split, parent = node_index})
	b.nodes[node_index].first, b.nodes[node_index].count = children, 0
	build_morton_node(b, m, codes, children)
	build_morton_node(b, m, codes, children + 1)
	b.nodes[node_index].bounds = aabb_union(b.nodes[children].bounds, b.nodes[children + 1].bounds)
}

// Stable LSD radix sort of (key, value) pairs by the low `key_bits` bits of key, 10
// bits per pass. Each pass splits the input into chunks: chunks count their buckets in
// parallel, then scatter in parallel to offsets that keep the order stable.
@(private)
radix_sort_pairs :: proc(keys: []u32, values: []u32, key_bits: u32, pool: ^jobs.Pool) {
	RADIX :: 10
	BUCKETS :: 1 << RADIX
	Pass :: struct {
		src_k, src_v, dst_k, dst_v: []u32,
		shift:                      u32,
		chunk:                      int,
		counts:                     [][BUCKETS]u32, // per chunk; turned into write offsets
	}
	n := len(keys)
	chunks := max(1, min(n / 4096, 4 * (jobs.pool_size(pool) if pool != nil else 1)))
	ps := Pass {
		src_k  = keys,
		src_v  = values,
		dst_k  = make([]u32, n, context.temp_allocator),
		dst_v  = make([]u32, n, context.temp_allocator),
		chunk  = (n + chunks - 1) / chunks,
		counts = make([][BUCKETS]u32, chunks, context.temp_allocator),
	}
	passes := 0
	for ps.shift = 0; ps.shift < key_bits; ps.shift += RADIX {
		jobs.parallel_for(pool, chunks, &ps, proc(data: rawptr, c: int) {
			ps := cast(^Pass)data
			counts := &ps.counts[c]
			counts^ = {}
			lo := min(c * ps.chunk, len(ps.src_k))
			for k in ps.src_k[lo:min(lo + ps.chunk, len(ps.src_k))] do counts[(k >> ps.shift) & (BUCKETS - 1)] += 1
		})
		sum: u32
		for bucket in 0 ..< BUCKETS {
			for c in 0 ..< chunks {
				count := ps.counts[c][bucket]
				ps.counts[c][bucket] = sum
				sum += count
			}
		}
		jobs.parallel_for(pool, chunks, &ps, proc(data: rawptr, c: int) {
			ps := cast(^Pass)data
			offsets := &ps.counts[c]
			lo := min(c * ps.chunk, len(ps.src_k))
			for i in lo ..< min(lo + ps.chunk, len(ps.src_k)) {
				k := ps.src_k[i]
				bucket := (k >> ps.shift) & (BUCKETS - 1)
				ps.dst_k[offsets[bucket]] = k
				ps.dst_v[offsets[bucket]] = ps.src_v[i]
				offsets[bucket] += 1
			}
		})
		ps.src_k, ps.dst_k = ps.dst_k, ps.src_k
		ps.src_v, ps.dst_v = ps.dst_v, ps.src_v
		passes += 1
	}
	if passes % 2 == 1 {
		copy(keys, ps.src_k)
		copy(values, ps.src_v)
	}
}
