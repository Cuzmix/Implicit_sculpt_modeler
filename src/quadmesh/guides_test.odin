package quadmesh

import "base:runtime"
import "core:log"
import "core:math"
import "core:testing"

import "../geom"

// The guides per triangle in Odin against the C++'s (qm_stage_face_guides) on a sphere's
// isotropic mesh: a ring of guide segments round it, plain and with a density that
// doubles the quads' size on one half (which widens the reach there), and a guide at full
// strength off to one side, which only some triangles feel. Every direction the same bit
// for bit, and nil from both where no guide comes near.
@(test)
face_guides_match_the_cpp :: proc(t: ^testing.T) {
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
		some:     bool,
	}
	cases := []Case {
		{"ring", ring[:], 0.5, false, true},
		{"ring with density", ring[:], 0.5, true, true},
		{"side at full strength", side, 1, false, true},
		{"far", far, 0.5, false, false},
		{"no strength", ring[:], 0, false, false},
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
		ours := odin_face_guides(iso, quad_edge, c.guides, c.strength, heap)
		defer delete(ours, heap)
		felt := 0
		for g in ours do if g != {} do felt += 1
		log.infof("%s: %d of %d triangles feel a guide", c.name, felt, len(iso.triangles))
		testing.expectf(t, (ours != nil) == c.some, "%s: %d triangles feel a guide", c.name, felt)
		when AVAILABLE {
			theirs, cpp_err := cpp_face_guides(iso, quad_edge, c.guides, c.strength, &reason)
			defer delete(theirs, heap)
			if !testing.expectf(t, cpp_err == .None, "%s: the C++ failed", c.name) do continue
			if !testing.expectf(t, len(ours) == len(theirs), "%s: %d directions against the C++'s %d", c.name, len(ours), len(theirs)) do continue
			differ := 0
			for g, f in ours do if g != theirs[f] do differ += 1
			testing.expectf(t, differ == 0, "%s: %d of %d directions differ from the C++'s", c.name, differ, len(ours))
		}
	}
}
