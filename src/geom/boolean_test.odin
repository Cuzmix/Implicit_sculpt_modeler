package geom

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../jobs"

@(private = "file")
volume :: proc(m: Mesh) -> f32 {
	v: f32
	for i := 0; i < len(m.indices); i += 3 {
		v += linalg.dot(m.positions[m.indices[i]], linalg.cross(m.positions[m.indices[i + 1]], m.positions[m.indices[i + 2]])) / 6
	}
	return v
}

// Two unit spheres a unit apart: each boolean is closed, manifold, and as large as the
// sphere geometry says (the lens they share is 5π/12).
@(test)
boolean_of_two_spheres :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a := icosphere(5)
	defer mesh_destroy(&a)
	b := icosphere(5)
	defer mesh_destroy(&b)
	for &p in b.positions do p.x += 1
	ball := f32(4.0 / 3.0 * math.PI)
	lens := f32(5 * math.PI / 12)
	cases := [?]struct {
		op:   Remesh_Op,
		want: f32,
	}{{.Union, 2 * ball - lens}, {.Subtract, ball - lens}, {.Intersect, lens}}
	for c in cases {
		out, ok := mesh_boolean(a, b, c.op, 60_000, true, &pool)
		defer mesh_destroy(&out)
		testing.expectf(t, ok, "%v failed", c.op)
		if !ok do continue
		_ = expect_closed_manifold(t, out)
		got := volume(out)
		testing.expectf(t, abs(got - c.want) < 0.02 * c.want, "%v: volume %v, want %v", c.op, got, c.want)
		// Put back onto the inputs: every vertex on one sphere or the other, but for the
		// seam where they meet.
		off := 0
		for p in out.positions {
			if min(abs(linalg.length(p) - 1), abs(linalg.length(p - {1, 0, 0}) - 1)) > 0.002 do off += 1
		}
		testing.expectf(t, off < len(out.positions) / 20, "%v: %d of %d vertices off both spheres", c.op, off, len(out.positions))
	}
	// Apart, nothing is in both.
	for &p in b.positions do p.x += 5
	_, ok := mesh_boolean(a, b, .Intersect, 20_000, true, &pool)
	testing.expect(t, !ok, "two spheres apart intersected")
}

// Extract makes a closed shell of the kept cap, as thick as asked.
@(test)
extract_shell_of_a_cap :: proc(t: ^testing.T) {
	m := icosphere(5)
	defer mesh_destroy(&m)
	keep := make([]bool, len(m.positions), context.temp_allocator)
	for p, v in m.positions do keep[v] = p.z > 0.3
	out, ok := mesh_extract_shell(m, keep, 0.05, 3)
	defer mesh_destroy(&out)
	if !testing.expect(t, ok) do return
	_ = expect_closed_manifold(t, out)
	// The cap above z = 0.3 has area 2π(1 - 0.3); the shell grows outward a little.
	want := f32(2 * math.PI * 0.7) * 0.05 * 1.05
	got := volume(out)
	testing.expectf(t, abs(got - want) < 0.1 * want, "volume %v, want about %v", got, want)
	none := make([]bool, len(m.positions), context.temp_allocator)
	_, any := mesh_extract_shell(m, none, 0.05, 3)
	testing.expect(t, !any, "an empty mask extracted something")
}
