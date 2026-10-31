package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"

// Snapshot of everything undo must restore.
@(private = "file")
State :: struct {
	positions, normals: []Vec3,
	chunks:             []geom.Chunk,
	bounds:             []geom.Aabb,
}

@(private = "file")
snapshot :: proc(s: ^Sculptor) -> State {
	// Normal cones held back after a stroke, an undo or a redo come over later flushes.
	_ = sculptor_flush(s)
	for len(s.waiting_cones) > 0 do _ = sculptor_flush(s)
	bounds := make([]geom.Aabb, len(s.bvh.nodes), context.temp_allocator)
	for n, i in s.bvh.nodes do bounds[i] = n.bounds
	return {
		positions = slice.clone(s.mesh.positions[:], context.temp_allocator),
		normals   = slice.clone(s.mesh.normals[:], context.temp_allocator),
		chunks    = slice.clone(s.chunks, context.temp_allocator),
		bounds    = bounds,
	}
}

@(private = "file")
expect_state :: proc(t: ^testing.T, s: ^Sculptor, want: State, what: string) {
	got := snapshot(s)
	testing.expectf(t, slice.equal(got.positions, want.positions), "%s: positions differ", what)
	testing.expectf(t, slice.equal(got.normals, want.normals), "%s: normals differ", what)
	testing.expectf(t, slice.equal(got.chunks, want.chunks), "%s: chunks differ", what)
	testing.expectf(t, slice.equal(got.bounds, want.bounds), "%s: BVH bounds differ", what)
}

@(private = "file")
stroke :: proc(s: ^Sculptor, kind: Brush_Kind, phase: f32) {
	sculptor_stroke_begin(s)
	for k in 0 ..< 12 {
		a := phase + f32(k) * 0.08
		_ = apply_dab(s, {kind = kind, radius = 0.3, strength = 0.8}, linalg.normalize(Vec3{math.cos(a), 0.3, math.sin(a)}))
	}
	_ = sculptor_stroke_end(s)
}

@(test)
undo_and_redo_restore_exact_state :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	// The sphere comes with analytic normals; undo restores face-weighted ones, so
	// start from those.
	for id in 0 ..< len(s.nodes) do mark_stale(&s, u32(id), .Shape)

	start := snapshot(&s)
	stroke(&s, .Draw, 0)
	after_one := snapshot(&s)
	stroke(&s, .Smooth, 0.4)
	stroke(&s, .Draw, 2)
	after_three := snapshot(&s)
	testing.expect(t, !slice.equal(after_three.positions, start.positions), "strokes moved nothing")

	testing.expect(t, sculptor_undo(&s), "undo 3")
	// The flush after an undo works out the normals but holds the cones back, as a
	// stroke's flushes do, so the frame that undoes a large stroke stays short.
	_ = sculptor_flush(&s)
	testing.expect(t, len(s.waiting_cones) > 0, "the undo's cones wait for later flushes")
	testing.expect(t, sculptor_undo(&s), "undo 2")
	expect_state(t, &s, after_one, "after two undos")
	testing.expect(t, sculptor_undo(&s), "undo 1")
	expect_state(t, &s, start, "after undoing everything")
	testing.expect(t, !sculptor_undo(&s), "undo with nothing left")

	for _ in 0 ..< 3 do testing.expect(t, sculptor_redo(&s), "redo")
	expect_state(t, &s, after_three, "after redoing everything")
	testing.expect(t, !sculptor_redo(&s), "redo with nothing left")

	// The BVH still finds the surface the brute-force raycast finds.
	for k in 0 ..< 32 {
		a := f32(k) * 0.2
		origin := Vec3{3 * math.cos(a), 0.5, 3 * math.sin(a)}
		want, want_ok := raycast(m, origin, linalg.normalize(-origin))
		got, got_ok := sculptor_raycast(&s, origin, linalg.normalize(-origin))
		testing.expect_value(t, got_ok, want_ok)
		if want_ok && got_ok do testing.expect(t, linalg.length(got - want) < 1e-4, "BVH hit differs after undo/redo")
	}
}

@(test)
new_stroke_clears_redo_and_limit_drops_oldest :: proc(t: ^testing.T) {
	m := geom.icosphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)

	stroke(&s, .Draw, 0)
	stroke(&s, .Draw, 1)
	testing.expect(t, sculptor_undo(&s), "undo")
	testing.expect(t, sculptor_can_redo(&s), "nothing to redo")
	stroke(&s, .Draw, 2)
	testing.expect(t, !sculptor_can_redo(&s), "a new stroke should discard redo")
	testing.expect_value(t, len(s.history.done), 2)

	// An empty stroke (no dabs) is not a step.
	sculptor_stroke_begin(&s)
	testing.expect(t, !sculptor_stroke_end(&s), "empty stroke recorded")
	testing.expect_value(t, len(s.history.done), 2)

	// With a limit smaller than one step, only the newest step is kept.
	s.history.limit = 1
	stroke(&s, .Draw, 3)
	testing.expect_value(t, len(s.history.done), 1)
	testing.expect(t, s.history.bytes > 0, "byte count lost")
	testing.expect(t, sculptor_undo(&s), "undo the kept step")
	testing.expect_value(t, s.history.bytes > 0, true)
	_ = sculptor_redo(&s)
	stroke(&s, .Draw, 4)
	testing.expect_value(t, len(s.history.done), 1)
}
