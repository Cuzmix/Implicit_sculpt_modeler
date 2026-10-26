package geom

import "core:log"
import "core:math"
import "core:testing"

import "../jobs"

@(test)
primitives_are_closed_and_outward :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for shape in Primitive {
		// The starters have a test of their own (starters_test.odin).
		if is_starter(shape) do continue
		for want in ([2]int{2_000, 40_000}) {
			m, ok := primitive(shape, want, &pool)
			defer mesh_destroy(&m)
			testing.expectf(t, ok, "%v: not built", shape)
			r := mesh_check(m)
			testing.expectf(t, r.closed && r.degenerate_triangles == 0 && r.nan_count == 0 && !r.inverted, "%v %d: %v", shape, want, r)
			// Euler characteristic: 2 for the sphere's kind, 0 for the torus.
			chi := r.vertices - r.triangles * 3 / 2 + r.triangles
			testing.expectf(t, chi == (0 if shape == .Torus else 2), "%v: V - E + F = %d", shape, chi)
			testing.expectf(t, abs(r.vertices - want) < want / 4, "%v: %d vertices for %d", shape, r.vertices, want)
			testing.expectf(t, len(m.normals) == len(m.positions), "%v: normals", shape)
			// Volumes against the formula, looser for the remeshed and faceted ones.
			exact: f64
			switch shape {
			case .Sphere:   exact = 4.0 / 3 * math.PI
			case .Cube:     exact = 1.6 * 1.6 * 1.6
			case .Cylinder: exact = math.PI * 0.49 * 1.6
			case .Cone:     exact = math.PI * 0.64 * 1.6 / 3
			case .Torus:    exact = 2 * math.PI * math.PI * 0.75 * 0.09
			case .Head, .Bust, .Figure, .Hand, .Creature:
			}
			testing.expectf(t, abs(r.volume - exact) < 0.05 * exact, "%v %d: volume %.4f, want %.4f", shape, want, r.volume, exact)
			log.infof("%v %d: %d vertices, volume %.4f of %.4f", shape, want, r.vertices, r.volume, exact)
		}
	}
}
