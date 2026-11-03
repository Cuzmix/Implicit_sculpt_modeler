package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

// Settle (skin_settle.odin): the smooth part of the skin moves into the vertices while
// the surface stays where the stroke left it, inside the stroke's undo step.

// Every sample's point on the surface the viewport shows: the mesh's rounded triangles
// raised by the heights, in skin_sample order.
@(private = "file")
settle_points :: proc(s: ^Sculptor) -> []Vec3 {
	sk := s.skin
	points := make([]Vec3, len(sk.heights), context.temp_allocator)
	I := s.mesh.indices[:]
	S := sk.segments
	for t in u32(0) ..< sk.tri_count do for j in u32(0) ..= S do for i in u32(0) ..= S - j {
		x := skin_sample(sk, I, t, i, j)
		base, normal := skin_base(s, sk, t, i, j)
		n := linalg.normalize0(normal)
		points[x] = base + n * settle_rounding(s, t, i, j, S, base, n) + skin_lift(s, sk, x, t, i, j, n, f32(sk.heights[x]))
	}
	return points
}

// The largest height a vertex sample holds.
@(private = "file")
settle_vertex_height :: proc(sk: ^Skin) -> f32 {
	most: f32
	for v in 0 ..< sk.vert_count do most = max(most, abs(f32(sk.heights[v])))
	return most
}

@(private = "file")
settle_stroke :: proc(s: ^Sculptor, edge: f32) {
	sculptor_stroke_begin(s)
	at := linalg.normalize(Vec3{0.1, 0.2, 1})
	// A broad skin-only rise, several edges wide, as a stroke under Detail goes to Skin
	// before a switch to Auto would leave it.
	for _ in 0 ..< 4 do _ = apply_dab(s, {kind = .Draw, radius = 3 * edge, strength = 1, skin = true}, at)
}

@(test)
skin_settle_keeps_the_surface_and_shrinks_heights :: proc(t: ^testing.T) {
	sp := skin_sphere_with(3, 8)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	sum: f32
	for e in s.skin.node_edge do sum += e
	edge := sum / f32(len(s.skin.node_edge))
	settle_stroke(s, edge)
	_ = sculptor_flush(s)
	before := settle_points(s)
	tall := settle_vertex_height(s.skin)
	moved := sculptor_skin_settle(s)
	_ = sculptor_flush(s)
	testing.expect(t, moved > 0, "a broad rise moved no vertex")
	after := settle_points(s)
	worst: f32
	for p, i in before do worst = max(worst, linalg.length(after[i] - p))
	// The surface stays put, within the sideways slip of measuring along the new normals
	// and f16's rounding.
	testing.expectf(t, worst < 0.1 * edge, "a sample moved %v, more than a tenth of an edge (%v)", worst, edge)
	testing.expectf(t, settle_vertex_height(s.skin) < 0.5 * tall, "vertex heights went from %v only to %v", tall, settle_vertex_height(s.skin))
	testing.expect(t, sculptor_stroke_end(s), "the stroke was not recorded")
}

@(test)
skin_settle_undoes_with_its_stroke :: proc(t: ^testing.T) {
	sp := skin_sphere_with(3, 8)
	defer skin_sphere_free(sp)
	s := &sp.sculptor
	sum: f32
	for e in s.skin.node_edge do sum += e
	edge := sum / f32(len(s.skin.node_edge))
	positions := slice.clone(sp.mesh.positions[:], context.temp_allocator)
	heights := slice.clone(s.skin.heights, context.temp_allocator)
	settle_stroke(s, edge)
	moved := sculptor_skin_settle(s)
	testing.expect(t, moved > 0, "a broad rise moved no vertex")
	testing.expect(t, sculptor_stroke_end(s), "the stroke was not recorded")
	testing.expect(t, sculptor_undo(s), "nothing to undo")
	_ = sculptor_flush(s)
	testing.expect(t, slice.equal(sp.mesh.positions[:], positions), "undo left vertices moved")
	testing.expect(t, slice.equal(s.skin.heights, heights), "undo left heights changed")
	testing.expect(t, sculptor_redo(s), "nothing to redo")
	_ = sculptor_flush(s)
	testing.expect(t, sculptor_undo(s), "nothing to undo after the redo")
	testing.expect(t, slice.equal(sp.mesh.positions[:], positions), "undo after redo left vertices moved")
}

@(test)
skin_settle_matches_serial_and_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a := skin_sphere_with(4, 8)
	b := skin_sphere_with(4, 8, &pool)
	defer skin_sphere_free(a)
	defer skin_sphere_free(b)
	sum: f32
	for e in a.sculptor.skin.node_edge do sum += e
	edge := sum / f32(len(a.sculptor.skin.node_edge))
	for sp in ([2]^Skin_Sphere{a, b}) {
		settle_stroke(&sp.sculptor, edge)
		testing.expect(t, sculptor_skin_settle(&sp.sculptor) > 0, "a broad rise moved no vertex")
		_ = sculptor_stroke_end(&sp.sculptor)
		_ = sculptor_flush(&sp.sculptor)
	}
	testing.expect(t, slice.equal(a.mesh.positions[:], b.mesh.positions[:]), "the parallel Settle moved vertices elsewhere")
	testing.expect(t, slice.equal(a.sculptor.skin.heights, b.sculptor.skin.heights), "the parallel Settle left other heights")
	testing.expect(t, slice.equal(a.sculptor.skin.normals, b.sculptor.skin.normals), "the parallel Settle left other normals")
}
