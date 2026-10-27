package geom

import "base:runtime"
import "core:hash"
import "core:math/linalg"
import "core:slice"

import "../jobs"

// Bounding volume hierarchies laid out for the GPU (the traced studio render,
// render/trace.odin): one over each chunk's triangles, and one over a mesh's chunks.
// Nodes are 32 bytes, std430-compatible, and stored so that a node's two children sit
// side by side after it: a refit can walk the array from the end to the start and see
// every child before its parent. A chunk's tree names its triangles by their offset from
// the chunk's first triangle, in 16 bits.

// The most triangles a chunk tree's leaf holds.
CHUNK_BVH_LEAF :: 12
// Past this depth a node is split at its median rather than by area, so no tree is
// deeper than about this plus log2(primitives / leaf): what a traversal's stack must hold.
CHUNK_BVH_SAH_DEPTH :: 24
// A traversal stack that deep holds any tree this file builds over at most 2^32 primitives.
CHUNK_BVH_STACK :: CHUNK_BVH_SAH_DEPTH + 33
// The most triangles a chunk may have: offsets are 16 bits.
CHUNK_BVH_MAX_TRIANGLES :: 1 << 16

// `count` 0: an inner node whose children are at `first` and `first + 1`; otherwise a
// leaf of `count` primitives, at `first` in its tree's order.
Gpu_Bvh_Node :: struct {
	lo:    [3]f32,
	first: u32,
	hi:    [3]f32,
	count: u32,
}
#assert(size_of(Gpu_Bvh_Node) == 32)

// One chunk's tree, and its triangles in leaf order as offsets from its first one.
Chunk_Bvh :: struct {
	nodes: [dynamic]Gpu_Bvh_Node,
	order: [dynamic]u16,
}

// Builds the tree over `bounds` (one box per primitive) into `nodes`, with `order`
// receiving the primitives in leaf order (len(bounds) entries). Leaves hold at most
// `leaf` primitives. Deterministic: the same boxes give the same tree. Uses `allocator`
// for its scratch (the heap's, inside jobs).
gpu_bvh_build :: proc(bounds: []Aabb, leaf: int, nodes: ^[dynamic]Gpu_Bvh_Node, order: []u32, allocator := context.allocator) {
	n := len(bounds)
	assert(len(order) == n)
	clear(nodes)
	for i in 0 ..< n do order[i] = u32(i)
	centroids := make([]Vec3, n, allocator)
	defer delete(centroids, allocator)
	for b, i in bounds do centroids[i] = (b.lo + b.hi) * 0.5
	append(nodes, Gpu_Bvh_Node{first = 0, count = u32(n)})
	if n == 0 {
		nodes[0].lo, nodes[0].hi = AABB_EMPTY.lo, AABB_EMPTY.hi
		return
	}
	b := Gpu_Builder{bounds, centroids, order, nodes, max(leaf, 1)}
	gpu_split(&b, 0, 0)
}

@(private = "file")
Gpu_Builder :: struct {
	bounds:    []Aabb,
	centroids: []Vec3,
	order:     []u32,
	nodes:     ^[dynamic]Gpu_Bvh_Node,
	leaf:      int,
}

@(private = "file")
gpu_split :: proc(b: ^Gpu_Builder, at: int, depth: int) {
	first, count := int(b.nodes[at].first), int(b.nodes[at].count)
	box, cbox := AABB_EMPTY, AABB_EMPTY
	for i in first ..< first + count {
		p := b.order[i]
		box = aabb_union(box, b.bounds[p])
		aabb_grow(&cbox, b.centroids[p])
	}
	b.nodes[at].lo, b.nodes[at].hi = box.lo, box.hi
	if count <= b.leaf do return
	extent := cbox.hi - cbox.lo
	axis := 0
	if extent.y > extent[axis] do axis = 1
	if extent.z > extent[axis] do axis = 2

	left := 0
	if extent[axis] > 0 && depth < CHUNK_BVH_SAH_DEPTH {
		left = gpu_sah_partition(b, first, count, axis, cbox.lo[axis], extent[axis])
	}
	if left <= 0 || left >= count {
		// Coinciding centroids, no useful plane, or too deep for area splits: halve the
		// primitives by their order along the axis, which always makes progress.
		run := b.order[first:first + count]
		Ctx :: struct {
			centroids: []Vec3,
			axis:      int,
		}
		ctx := Ctx{b.centroids, axis}
		context.user_ptr = &ctx
		slice.sort_by(run, proc(x, y: u32) -> bool {
			c := (^Ctx)(context.user_ptr)
			a, d := c.centroids[x][c.axis], c.centroids[y][c.axis]
			return a < d || a == d && x < y
		})
		left = count / 2
	}
	children := len(b.nodes)
	append(b.nodes, Gpu_Bvh_Node{first = u32(first), count = u32(left)})
	append(b.nodes, Gpu_Bvh_Node{first = u32(first + left), count = u32(count - left)})
	b.nodes[at].first, b.nodes[at].count = u32(children), 0
	gpu_split(b, children, depth + 1)
	gpu_split(b, children + 1, depth + 1)
}

// Binned surface area split along `axis`: reorders the run so the left side comes first
// and returns its size, 0 when no plane separates it.
@(private = "file")
gpu_sah_partition :: proc(b: ^Gpu_Builder, first, count, axis: int, lo, extent: f32) -> int {
	Bin :: struct {
		box:   Aabb,
		count: int,
	}
	bins: [BINS]Bin
	for &bin in bins do bin.box = AABB_EMPTY
	scale := f32(BINS) / extent
	bin_of :: #force_inline proc(c, lo, scale: f32) -> int {
		return clamp(int((c - lo) * scale), 0, BINS - 1)
	}
	for i in first ..< first + count {
		p := b.order[i]
		k := bin_of(b.centroids[p][axis], lo, scale)
		bins[k].box = aabb_union(bins[k].box, b.bounds[p])
		bins[k].count += 1
	}
	right_area: [BINS]f32
	right_count: [BINS]int
	rb := AABB_EMPTY
	rc := 0
	for k := BINS - 1; k > 0; k -= 1 {
		rc += bins[k].count
		rb = aabb_union(rb, bins[k].box)
		right_count[k], right_area[k] = rc, aabb_area(rb)
	}
	best, best_cost := -1, max(f32)
	lb := AABB_EMPTY
	lc := 0
	for k in 0 ..< BINS - 1 {
		lc += bins[k].count
		lb = aabb_union(lb, bins[k].box)
		if lc == 0 || right_count[k + 1] == 0 do continue
		cost := aabb_area(lb) * f32(lc) + right_area[k + 1] * f32(right_count[k + 1])
		if cost < best_cost do best, best_cost = k, cost
	}
	if best < 0 do return 0
	i, j := first, first + count - 1
	for i <= j {
		if bin_of(b.centroids[b.order[i]][axis], lo, scale) <= best {
			i += 1
		} else {
			b.order[i], b.order[j] = b.order[j], b.order[i]
			j -= 1
		}
	}
	return i - first
}

// Builds `out` over the `count` triangles from `first_tri` of `positions` and `indices`.
// Its scratch comes from `allocator`; `out` keeps its own arrays' allocator.
chunk_bvh_build :: proc(positions: []Vec3, indices: []u32, first_tri, count: u32, out: ^Chunk_Bvh, allocator := context.allocator) {
	assert(count <= CHUNK_BVH_MAX_TRIANGLES)
	bounds := make([]Aabb, count, allocator)
	defer delete(bounds, allocator)
	order := make([]u32, count, allocator)
	defer delete(order, allocator)
	for t in 0 ..< count {
		b := AABB_EMPTY
		at := 3 * (first_tri + t)
		for k in 0 ..< u32(3) do aabb_grow(&b, positions[indices[at + k]])
		bounds[t] = b
	}
	gpu_bvh_build(bounds, CHUNK_BVH_LEAF, &out.nodes, order, allocator)
	resize(&out.order, int(count))
	for o, i in order do out.order[i] = u16(o)
}

chunk_bvh_destroy :: proc(c: ^Chunk_Bvh) {
	delete(c.nodes)
	delete(c.order)
	c^ = {}
}

// What a chunk's tree depends on: where its triangles are and which vertices they use.
// A mesh whose positions moved keeps its keys (the GPU refits the boxes); one whose
// triangles changed gets new ones for the chunks they are in.
chunk_bvh_key :: proc(indices: []u32, first_index, index_count: u32) -> u64 {
	h := hash.fnv64a(slice.to_bytes(indices[first_index:first_index + index_count]))
	head := [2]u32{first_index, index_count}
	return max(hash.fnv64a(slice.to_bytes(head[:]), h), 1)
}

// Rebuilds the trees in `which` (chunk numbers into `ranges` and `trees`) on the pool,
// each into its own `trees` entry, whose arrays use the heap allocator.
chunk_bvh_build_many :: proc(pool: ^jobs.Pool, positions: []Vec3, indices: []u32, ranges: []Index_Range, which: []u32, trees: []Chunk_Bvh) {
	Job :: struct {
		positions: []Vec3,
		indices:   []u32,
		ranges:    []Index_Range,
		which:     []u32,
		trees:     []Chunk_Bvh,
	}
	job := Job{positions, indices, ranges, which, trees}
	jobs.parallel_for(pool, len(which), &job, proc(data: rawptr, i: int) {
		j := (^Job)(data)
		heap := runtime.heap_allocator()
		c := j.which[i]
		r := j.ranges[c]
		tree := &j.trees[c]
		if tree.nodes.allocator.procedure == nil {
			tree.nodes = make([dynamic]Gpu_Bvh_Node, heap)
			tree.order = make([dynamic]u16, heap)
		}
		chunk_bvh_build(j.positions, j.indices, r.first_index / 3, r.index_count / 3, tree, heap)
	})
}

// The first hit along a ray through a chunk tree, as render/shaders/studio_trace.comp walks it:
// for the tests, which check the GPU layout against the plain BVH. `limit` bounds the
// distance; degenerate triangles (all three corners one vertex, as hidden ones are drawn)
// never hit.
chunk_bvh_any_hit :: proc(tree: Chunk_Bvh, positions: []Vec3, indices: []u32, first_tri: u32, origin, dir: Vec3, limit: f32) -> bool {
	if len(tree.nodes) == 0 do return false
	inv := Vec3{1 / dir.x, 1 / dir.y, 1 / dir.z}
	stack: [CHUNK_BVH_STACK]u32 // stack[0] is the root
	top := 1
	for top > 0 {
		top -= 1
		node := tree.nodes[stack[top]]
		if _, ok := ray_aabb({node.lo, node.hi}, origin, inv, limit); !ok do continue
		if node.count == 0 {
			assert(top + 2 <= CHUNK_BVH_STACK)
			stack[top], stack[top + 1] = node.first, node.first + 1
			top += 2
			continue
		}
		for k in node.first ..< node.first + node.count {
			tri := first_tri + u32(tree.order[k])
			a, b, c := indices[3 * tri], indices[3 * tri + 1], indices[3 * tri + 2]
			if a == b || b == c || a == c do continue
			p0 := positions[a]
			e1, e2 := positions[b] - p0, positions[c] - p0
			pv := linalg.cross(dir, e2)
			det := linalg.dot(e1, pv)
			if det == 0 do continue
			f := 1 / det
			tv := origin - p0
			u := linalg.dot(tv, pv) * f
			if u < 0 || u > 1 do continue
			qv := linalg.cross(tv, e1)
			v := linalg.dot(dir, qv) * f
			if v < 0 || u + v > 1 do continue
			t := linalg.dot(e2, qv) * f
			if t > 0 && t < limit do return true
		}
	}
	return false
}

// The depth of the deepest leaf: a traversal needs a stack of about twice this.
gpu_bvh_depth :: proc(nodes: []Gpu_Bvh_Node) -> int {
	if len(nodes) == 0 do return 0
	depth := make([]int, len(nodes), context.temp_allocator)
	deepest := 0
	for node, i in nodes {
		if node.count == 0 {
			depth[node.first] = depth[i] + 1
			depth[node.first + 1] = depth[i] + 1
		}
		deepest = max(deepest, depth[i])
	}
	return deepest
}
