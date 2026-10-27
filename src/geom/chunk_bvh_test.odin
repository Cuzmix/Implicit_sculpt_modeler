package geom

import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "core:testing"

import "../jobs"

// An icosphere cut into runs of `per` triangles, as a sculptor's chunks are.
@(private = "file")
chunk_ranges :: proc(m: Mesh, per: u32, allocator := context.allocator) -> []Index_Range {
	tris := u32(len(m.indices) / 3)
	out := make([dynamic]Index_Range, allocator)
	for first := u32(0); first < tris; first += per {
		append(&out, Index_Range{3 * first, 3 * min(per, tris - first)})
	}
	return out[:]
}

@(private = "file")
build_all :: proc(pool: ^jobs.Pool, m: Mesh, ranges: []Index_Range) -> []Chunk_Bvh {
	trees := make([]Chunk_Bvh, len(ranges))
	which := make([]u32, len(ranges), context.temp_allocator)
	for &w, i in which do w = u32(i)
	chunk_bvh_build_many(pool, m.positions[:], m.indices[:], ranges, which, trees)
	return trees
}

@(private = "file")
destroy_all :: proc(trees: []Chunk_Bvh) {
	for &tree in trees do chunk_bvh_destroy(&tree)
	delete(trees)
}

// Children come after their parent, side by side; every triangle is in exactly one leaf;
// no leaf holds more than CHUNK_BVH_LEAF; every leaf's box holds its triangles.
@(test)
chunk_bvh_layout_holds :: proc(t: ^testing.T) {
	m := icosphere(5) // 20,480 triangles
	defer mesh_destroy(&m)
	ranges := chunk_ranges(m, 1024)
	defer delete(ranges)
	trees := build_all(nil, m, ranges)
	defer destroy_all(trees)
	nodes_total := 0
	for tree, c in trees {
		r := ranges[c]
		count := int(r.index_count / 3)
		testing.expect_value(t, len(tree.order), count)
		seen := make([]bool, count, context.temp_allocator)
		for node, i in tree.nodes {
			if node.count == 0 {
				testing.expect(t, int(node.first) > i && int(node.first) + 1 < len(tree.nodes))
				continue
			}
			testing.expect(t, node.count <= CHUNK_BVH_LEAF)
			for k in node.first ..< node.first + node.count {
				o := tree.order[k]
				testing.expect(t, !seen[o])
				seen[o] = true
				tri := r.first_index / 3 + u32(o)
				for corner in 0 ..< u32(3) {
					p := m.positions[m.indices[3 * tri + corner]]
					testing.expect(t, p.x >= node.lo.x && p.y >= node.lo.y && p.z >= node.lo.z && p.x <= node.hi.x && p.y <= node.hi.y && p.z <= node.hi.z)
				}
			}
		}
		for s in seen do testing.expect(t, s)
		testing.expect(t, gpu_bvh_depth(tree.nodes[:]) + 1 < CHUNK_BVH_STACK)
		nodes_total += len(tree.nodes)
	}
	// The GPU memory per triangle the traced studio budgets: nodes and 2-byte offsets.
	bytes_per_tri := f32(nodes_total * size_of(Gpu_Bvh_Node)) / f32(len(m.indices) / 3) + 2
	testing.expectf(t, bytes_per_tri <= 12, "%.1f bytes a triangle", bytes_per_tri)
}

// The tree's any-hit agrees with testing every triangle of the chunk, for rays aimed at
// the sphere from all round it and rays that start inside it.
@(test)
chunk_bvh_any_hit_matches_brute_force :: proc(t: ^testing.T) {
	m := icosphere(4)
	defer mesh_destroy(&m)
	ranges := chunk_ranges(m, 700)
	defer delete(ranges)
	trees := build_all(nil, m, ranges)
	defer destroy_all(trees)
	rng := rand.create(7)
	context.random_generator = rand.default_random_generator(&rng)
	hits := 0
	for _ in 0 ..< 400 {
		dir := linalg.normalize(Vec3{rand.float32_range(-1, 1), rand.float32_range(-1, 1), rand.float32_range(-1, 1)})
		origin := Vec3{rand.float32_range(-2, 2), rand.float32_range(-2, 2), rand.float32_range(-2, 2)}
		limit := rand.float32_range(0.1, 5)
		for tree, c in trees {
			r := ranges[c]
			want := false
			for tri in r.first_index / 3 ..< (r.first_index + r.index_count) / 3 {
				if d, ok := ray_triangle(m, tri, origin, dir); ok && d < limit do want = true
			}
			got := chunk_bvh_any_hit(tree, m.positions[:], m.indices[:], r.first_index / 3, origin, dir, limit)
			testing.expect_value(t, got, want)
			hits += int(got)
		}
	}
	testing.expect(t, hits > 50)
}

// Hidden triangles (drawn with all three corners on one vertex) are never hit, whatever
// tree they were built into.
@(test)
chunk_bvh_skips_degenerate_triangles :: proc(t: ^testing.T) {
	m := icosphere(3)
	defer mesh_destroy(&m)
	ranges := chunk_ranges(m, 1280)
	defer delete(ranges)
	trees := build_all(nil, m, ranges)
	defer destroy_all(trees)
	hidden := slice.clone(m.indices[:])
	defer delete(hidden)
	slice.zero(hidden)
	r := ranges[0]
	testing.expect(t, chunk_bvh_any_hit(trees[0], m.positions[:], m.indices[:], 0, {0.1, 0.13, 3}, {0, 0, -1}, 10))
	testing.expect(t, !chunk_bvh_any_hit(trees[0], m.positions[:], hidden, r.first_index / 3, {0.1, 0.13, 3}, {0, 0, -1}, 10))
}

// Built on the pool and on one thread, the trees are the same to the bit.
@(test)
chunk_bvh_parallel_matches_serial :: proc(t: ^testing.T) {
	m := icosphere(5)
	defer mesh_destroy(&m)
	ranges := chunk_ranges(m, 1024)
	defer delete(ranges)
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	serial := build_all(nil, m, ranges)
	defer destroy_all(serial)
	parallel := build_all(&pool, m, ranges)
	defer destroy_all(parallel)
	for c in 0 ..< len(ranges) {
		testing.expect(t, slice.equal(slice.to_bytes(serial[c].nodes[:]), slice.to_bytes(parallel[c].nodes[:])))
		testing.expect(t, slice.equal(serial[c].order[:], parallel[c].order[:]))
	}
}

// A chunk's key follows its triangles and where they are, not its vertices' positions.
@(test)
chunk_bvh_key_follows_triangles :: proc(t: ^testing.T) {
	m := icosphere(2)
	defer mesh_destroy(&m)
	a := chunk_bvh_key(m.indices[:], 0, 300)
	m.positions[m.indices[0]] += {0.1, 0, 0}
	testing.expect_value(t, chunk_bvh_key(m.indices[:], 0, 300), a)
	testing.expect(t, chunk_bvh_key(m.indices[:], 3, 300) != a)
	m.indices[5] = m.indices[4]
	testing.expect(t, chunk_bvh_key(m.indices[:], 0, 300) != a)
}

// Boxes that all coincide, and a long thin run, still give bounded trees.
@(test)
gpu_bvh_depth_is_bounded :: proc(t: ^testing.T) {
	n := 5000
	bounds := make([]Aabb, n)
	defer delete(bounds)
	order := make([]u32, n)
	defer delete(order)
	nodes: [dynamic]Gpu_Bvh_Node
	defer delete(nodes)
	for &b in bounds do b = {{0, 0, 0}, {1, 1, 1}}
	gpu_bvh_build(bounds, 1, &nodes, order)
	testing.expect(t, gpu_bvh_depth(nodes[:]) + 1 < CHUNK_BVH_STACK)
	// Exponentially spaced boxes: area splits peel one off at a time.
	for &b, i in bounds {
		x := math.pow(1.01, f32(i))
		b = {{x, 0, 0}, {x + 0.001, 0.001, 0.001}}
	}
	gpu_bvh_build(bounds, 1, &nodes, order)
	testing.expect(t, gpu_bvh_depth(nodes[:]) + 1 < CHUNK_BVH_STACK)
}
