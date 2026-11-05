package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:testing"

import "../geom"

// The guides per triangle on a sphere's isotropic mesh: a ring of guide segments round it,
// plain and with a density that doubles the quads' size on one half (which widens the
// reach there), and a guide at full strength off to one side, which only some triangles
// feel. A felt direction lies in its triangle's plane, along its guide (the ring's chords
// run round the z axis), and is no stronger than the strength asks; nil where no guide
// comes near.
@(test)
face_guides_follow_the_nearest_segment :: proc(t: ^testing.T) {
	heap := runtime.heap_allocator()
	source := geom.icosphere(5)
	defer geom.mesh_destroy(&source)
	sphere := island_of(source.positions[:], source.indices[:])
	defer island_destroy(&sphere)
	run := Stage_Run{threads = 4}
	reason: Reason
	checks: Checks
	ring := make([dynamic]geom.Vec3, heap)
	defer delete(ring)
	for k in 0 ..< 48 {
		a, b := 2 * math.PI * f32(k) / 48, 2 * math.PI * f32(k + 1) / 48
		append(&ring, geom.Vec3{math.cos(a), math.sin(a), 0.1}, geom.Vec3{math.cos(b), math.sin(b), 0.1})
	}
	side := []geom.Vec3{{0.93, -0.5, -0.4}, {0.93, 0.5, -0.4}}
	far := []geom.Vec3{{3, 3, 3}, {4, 3, 3}}
	Case :: struct {
		name:     string,
		guides:   []geom.Vec3,
		strength: f32,
		density:  bool,
		felt:     [2]int, // how many triangles feel a guide, at least and at most
	}
	cases := []Case {
		{"ring", ring[:], 0.5, false, {150, 300}},
		{"ring with density", ring[:], 0.5, true, {100, 250}},
		{"side at full strength", side, 1, false, {10, 40}},
		{"far", far, 0.5, false, {0, 0}},
		{"no strength", ring[:], 0, false, {0, 0}},
	}
	for c in cases {
		island := sphere
		if c.density {
			island.density = make([]f64, len(sphere.positions), heap)
			for p, v in sphere.positions do island.density[v] = 0.25 if p.x > 0 else 1
		}
		defer if c.density do delete(island.density, heap)
		quad_edge := edge_for(island, 1500)
		iso, err := odin_isotropic(island, quad_edge, 0, 90, &run, &reason, &checks)
		defer isotropic_destroy(&iso)
		if !testing.expectf(t, err == .None, "%s: isotropic failed", c.name) do continue
		guided := odin_face_guides(iso, quad_edge, c.guides, c.strength, heap)
		defer delete(guided, heap)
		s := f64(c.strength)
		strongest := s / (1 - s + 0.01)
		felt, off_plane, off_guide, too_strong := 0, 0, 0, 0
		for g, f in guided {
			if g == {} do continue
			felt += 1
			tri := iso.triangles[f]
			p0, p1, p2 := iso.positions[tri[0]], iso.positions[tri[1]], iso.positions[tri[2]]
			strength := length3(g)
			if strength > strongest * (1 + 1e-9) do too_strong += 1
			if abs(dot3(unit_or_zero(cross3(p1 - p0, p2 - p0)), g)) > 1e-9 * strength do off_plane += 1
			if c.guides[0] == ring[0] {
				middle := (p0 + p1 + p2) / 3
				round := unit_or_zero([3]f64{-middle.y, middle.x, 0})
				if abs(dot3(round, g)) < 0.9 * strength do off_guide += 1
			}
		}
		log.infof("%s: %d of %d triangles feel a guide", c.name, felt, len(iso.triangles))
		testing.expectf(t, (guided != nil) == (c.felt[1] > 0), "%s: guides given %v with %d felt", c.name, guided != nil, felt)
		testing.expectf(t, felt >= c.felt[0] && felt <= c.felt[1], "%s: %d triangles feel a guide, not %d to %d", c.name, felt, c.felt[0], c.felt[1])
		testing.expectf(t, off_plane == 0 && off_guide == 0 && too_strong == 0, "%s: %d directions off their triangle's plane, %d off the guide and %d stronger than asked", c.name, off_plane, off_guide, too_strong)
	}
}
