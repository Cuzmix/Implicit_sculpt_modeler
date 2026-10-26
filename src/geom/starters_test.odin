package geom

import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../jobs"

// Each starter is one closed surface with no handles, near the asked size, inside the
// unit sphere and filling it, mirror-symmetric across X where its subject is, and the
// same built serially as in parallel.
@(test)
starters_are_whole_and_symmetric :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for shape in ([?]Primitive{.Head, .Bust, .Figure, .Hand, .Creature}) do for want in ([?]int{STARTER_MIN_VERTICES, 60_000}) {
		m, ok := primitive(shape, want, &pool)
		defer mesh_destroy(&m)
		testing.expectf(t, ok, "%v: not built", shape)
		r := mesh_check(m)
		testing.expectf(t, r.closed && r.degenerate_triangles == 0 && r.nan_count == 0 && !r.inverted, "%v %d: %v", shape, want, r)
		chi := r.vertices - r.triangles * 3 / 2 + r.triangles
		testing.expectf(t, chi == 2, "%v %d: V - E + F = %d", shape, want, chi)
		testing.expectf(t, abs(r.vertices - want) < want / 4, "%v: %d vertices for %d", shape, r.vertices, want)
		reach: f32 = 0
		for p in m.positions do reach = max(reach, linalg.length(p))
		testing.expectf(t, reach <= 1 && reach > 0.9, "%v: reaches %.3f", shape, reach)
		if shape != .Hand {
			// Mirrored, every vertex has one near it: within about an edge.
			sorted := slice.clone(m.positions[:], context.temp_allocator)
			slice.sort_by(sorted, proc(a, b: Vec3) -> bool {return a.x < b.x})
			worst: f32 = 0
			for p in m.positions[:min(len(m.positions), 400)] {
				q := Vec3{-p.x, p.y, p.z}
				best := f32(1e9)
				for s in sorted do best = min(best, linalg.length(s - q))
				worst = max(worst, best)
			}
			testing.expectf(t, worst < 0.03, "%v: a vertex's mirror image is %.4f from the surface's nearest vertex", shape, worst)
		}
		serial, _ := primitive(shape, want, nil)
		defer mesh_destroy(&serial)
		testing.expectf(t, slice.equal(serial.positions[:], m.positions[:]) && slice.equal(serial.indices[:], m.indices[:]), "%v: serial and parallel differ", shape)
		log.infof("%v %d: %d vertices, volume %.3f", shape, want, r.vertices, r.volume)
	}
}
