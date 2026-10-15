package geom

import "core:math"
import "base:intrinsics"
import "core:math/linalg"

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
bvh_build :: proc(m: Mesh, allocator := context.allocator) -> Bvh {
	tcount := len(m.indices) / 3
	b := Bvh {
		nodes     = make([dynamic]Bvh_Node, 0, max(2 * tcount / BVH_LEAF_SIZE, 1), allocator),
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
	if count <= BVH_LEAF_SIZE {
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
	lo_word, hi_word := len(b.dirty), 0
	for t in tris {
		// Walk up until reaching a node another triangle already marked.
		for n := b.tri_leaf[t]; n != BVH_NONE; n = b.nodes[n].parent {
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
				node.bounds = AABB_EMPTY
				for i in node.first ..< node.first + node.count {
					node.bounds = aabb_union(node.bounds, tri_bounds(m, b.tri_order[i]))
				}
			} else {
				node.bounds = aabb_union(b.nodes[node.first].bounds, b.nodes[node.first + 1].bounds)
			}
		}
		b.dirty[w] = 0
	}
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
