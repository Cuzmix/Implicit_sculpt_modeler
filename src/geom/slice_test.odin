package geom

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

@(private = "file")
expect_sound :: proc(t: ^testing.T, m: Mesh, what: string, loc := #caller_location) -> Mesh_Report {
	r := mesh_check(m)
	testing.expectf(t, r.closed && r.boundary_edges == 0 && r.inconsistent_edges == 0 && r.non_manifold_edges == 0 &&
		r.degenerate_triangles == 0 && r.nan_count == 0 && !r.inverted, "%s: %v", what, r, loc = loc)
	return r
}

// Slicing a sphere off its middle gives two closed halves whose volumes add up to the
// sphere's, each stopping at the plane.
@(test)
slice_sphere_gives_two_closed_halves :: proc(t: ^testing.T) {
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	whole := mesh_check(sphere)
	normal := linalg.normalize(Vec3{0.2, 0.1, 1})
	point := normal * 0.23
	front, back, ok := mesh_slice(sphere, point, normal, true, nil)
	defer mesh_destroy(&front)
	defer mesh_destroy(&back)
	testing.expect(t, ok)
	rf := expect_sound(t, front, "front")
	rb := expect_sound(t, back, "back")
	testing.expectf(t, abs(rf.volume + rb.volume - whole.volume) < 1e-4 * whole.volume, "%v + %v vs %v", rf.volume, rb.volume, whole.volume)
	testing.expect(t, rf.volume < rb.volume) // the cap side is the smaller one
	far := f32(0)
	for p in front.positions do far = min(far, linalg.dot(p - point, normal))
	testing.expectf(t, far > -1e-5, "the front half reaches %v past the plane", far)
	far = 0
	for p in back.positions do far = max(far, linalg.dot(p - point, normal))
	testing.expectf(t, far < 1e-5, "the back half reaches %v past the plane", far)
	// The cap's edges are about as long as the cut's.
	longest, edge: f32
	edges: int
	for i := 0; i < len(front.indices); i += 3 {
		for c in 0 ..< 3 {
			a, b := front.positions[front.indices[i + c]], front.positions[front.indices[i + (c + 1) % 3]]
			if abs(linalg.dot(a - point, normal)) > 1e-5 || abs(linalg.dot(b - point, normal)) > 1e-5 do continue
			longest = max(longest, linalg.length(a - b))
			edge += linalg.length(a - b)
			edges += 1
		}
	}
	testing.expectf(t, longest < 3 * edge / f32(edges), "cap edge %v against %v on average", longest, edge / f32(edges))
}

// Left open, the halves keep the holes the cut made.
@(test)
slice_without_closing_leaves_the_cut_open :: proc(t: ^testing.T) {
	sphere := icosphere(4)
	defer mesh_destroy(&sphere)
	front, back, ok := mesh_slice(sphere, {0, 0, 0.1}, {0, 0, 1}, false, nil)
	defer mesh_destroy(&front)
	defer mesh_destroy(&back)
	testing.expect(t, ok)
	rf, rb := mesh_check(front), mesh_check(back)
	testing.expect(t, !rf.closed && rf.boundary_edges > 0 && rf.boundary_edges == rb.boundary_edges)
	testing.expect_value(t, rf.non_manifold_edges, 0)
}

// A torus cut across its hole leaves a ring on the plane, a loop with a hole in it; cut
// through its axis, each half has two loops. Both close.
@(test)
slice_torus_fills_rings_and_pairs_of_loops :: proc(t: ^testing.T) {
	torus, made := primitive(.Torus, 20_000, nil)
	defer mesh_destroy(&torus)
	testing.expect(t, made)
	whole := mesh_check(torus)
	for normal in ([?]Vec3{{0, 0, 1}, {1, 0, 0}, linalg.normalize(Vec3{0.3, 0.2, 1})}) {
		front, back, ok := mesh_slice(torus, normal * 0.013, normal, true, nil)
		defer mesh_destroy(&front)
		defer mesh_destroy(&back)
		testing.expect(t, ok)
		rf := expect_sound(t, front, "front")
		rb := expect_sound(t, back, "back")
		testing.expectf(t, abs(rf.volume + rb.volume - whole.volume) < 1e-3 * whole.volume, "%v: %v + %v vs %v", normal, rf.volume, rb.volume, whole.volume)
	}
}

// A plane that misses the mesh, or only touches it, slices nothing.
@(test)
slice_that_misses_does_nothing :: proc(t: ^testing.T) {
	sphere := icosphere(3)
	defer mesh_destroy(&sphere)
	_, _, ok := mesh_slice(sphere, {0, 0, 2}, {0, 0, 1}, true, nil)
	testing.expect(t, !ok)
	_, _, ok = mesh_slice(sphere, {0, 0, -1.5}, {0, 0, 1}, true, nil)
	testing.expect(t, !ok)
}

// Threads (in the clean-up) change nothing.
@(test)
slice_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	normal := linalg.normalize(Vec3{1, -0.4, 0.3})
	f1, b1, ok1 := mesh_slice(sphere, {0.05, 0, 0}, normal, true, nil)
	defer mesh_destroy(&f1)
	defer mesh_destroy(&b1)
	f2, b2, ok2 := mesh_slice(sphere, {0.05, 0, 0}, normal, true, &pool)
	defer mesh_destroy(&f2)
	defer mesh_destroy(&b2)
	testing.expect(t, ok1 && ok2)
	testing.expect(t, slice.equal(f1.positions[:], f2.positions[:]) && slice.equal(f1.indices[:], f2.indices[:]))
	testing.expect(t, slice.equal(b1.positions[:], b2.positions[:]) && slice.equal(b1.indices[:], b2.indices[:]))
}
