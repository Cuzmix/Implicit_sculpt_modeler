package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"

@(private = "file")
Posed :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
	// Per vertex, its mirror partner on the sphere before posing, by position.
	partner:  []u32,
}

@(private = "file")
posed_make :: proc(subdiv: int) -> ^Posed {
	p := new(Posed)
	p.mesh = geom.icosphere(subdiv)
	sculptor_init(&p.sculptor, &p.mesh, nil, 64)
	for id in 0 ..< len(p.sculptor.nodes) do mark_stale(&p.sculptor, u32(id), .Shape)
	_ = sculptor_flush(&p.sculptor)
	pos := p.mesh.positions[:]
	p.partner = make([]u32, len(pos), context.temp_allocator)
	for q, i in pos {
		best, best_d := 0, max(f32)
		for r, j in pos do if d := linalg.length(r - Vec3{-q.x, q.y, q.z}); d < best_d do best, best_d = j, d
		p.partner[i] = u32(best)
	}
	return p
}

// Raises the sphere's +X side as an arm is raised: each vertex past x = 0.2 turns about
// the Z axis through (0.2, 0, 0), by up to `angle` past x = 0.6.
@(private = "file")
posed_raise :: proc(p: ^Posed, angle: f32) {
	for &q in p.mesh.positions {
		k := clamp((q.x - 0.2) / 0.4, 0, 1)
		a := angle * k * k * (3 - 2 * k)
		r := q - Vec3{0.2, 0, 0}
		c, s := math.cos(a), math.sin(a)
		q = Vec3{0.2, 0, 0} + Vec3{c * r.x - s * r.y, s * r.x + c * r.y, r.z}
	}
	nodes := make([]u32, len(p.sculptor.nodes), context.temp_allocator)
	for &n, i in nodes do n = u32(i)
	sculptor_nodes_moved(&p.sculptor, nodes)
	_ = sculptor_flush(&p.sculptor)
}

@(private = "file")
posed_free :: proc(p: ^Posed) {
	sculptor_destroy(&p.sculptor)
	geom.mesh_destroy(&p.mesh)
	free(p)
}

// On a symmetric sphere every vertex pairs with the one at its mirror image, those on the
// plane with themselves, and the pairing goes both ways.
@(test)
mirror_pairs_match_the_mirror_image :: proc(t: ^testing.T) {
	p := posed_make(3)
	defer posed_free(p)
	paired, ok := sculptor_mirror_find(&p.sculptor, .X, {})
	testing.expect(t, ok)
	testing.expect_value(t, paired, len(p.mesh.positions))
	testing.expect(t, slice.equal(p.sculptor.mirror, p.partner), "the pairs are not the mirror images")
	for m, v in p.sculptor.mirror do testing.expect(t, p.sculptor.mirror[m] == u32(v), "a pairing that does not go both ways")
}

// The pairs are found on a posed mesh too, where the mirror plane lands nowhere near the
// raised side's partners: the topology decides them.
@(test)
mirror_pairs_survive_posing :: proc(t: ^testing.T) {
	p := posed_make(3)
	defer posed_free(p)
	posed_raise(p, 1.2)
	paired, ok := sculptor_mirror_find(&p.sculptor, .X, {})
	testing.expect(t, ok)
	testing.expect_value(t, paired, len(p.mesh.positions))
	testing.expect(t, slice.equal(p.sculptor.mirror, p.partner), "posing changed the pairs")
}

// On the posed mesh a dab under poseable symmetry moves its vertex's partner as far as
// itself, where the plane's image would have landed in the air beside the raised side.
@(test)
poseable_dab_lands_on_the_partner :: proc(t: ^testing.T) {
	p := posed_make(4)
	defer posed_free(p)
	pos := p.mesh.positions[:]
	// A place on the -X side, which the raise leaves where it was.
	near := 0
	for q, i in pos do if linalg.length(q - linalg.normalize(Vec3{-0.8, 0.3, 0.5})) < linalg.length(pos[near] - linalg.normalize(Vec3{-0.8, 0.3, 0.5})) do near = i
	posed_raise(p, 1.2)
	_, ok := sculptor_mirror_find(&p.sculptor, .X, {})
	testing.expect(t, ok)
	before := slice.clone(pos, context.temp_allocator)
	center := pos[near]
	_ = apply_dab(&p.sculptor, {kind = .Draw, radius = 0.25, strength = 1, symmetry = {.X}, poseable = true}, center)
	_ = sculptor_flush(&p.sculptor)
	partner := p.partner[near]
	own := linalg.length(pos[near] - before[near])
	other := linalg.length(pos[partner] - before[partner])
	testing.expect(t, own > 1e-4, "the dab did nothing")
	testing.expectf(t, abs(own - other) < 0.1 * own, "the partner moved %v, the dab's vertex %v", other, own)
	// The push follows the partner's own surface.
	push := linalg.normalize(pos[partner] - before[partner])
	testing.expectf(t, linalg.dot(push, linalg.normalize(p.mesh.normals[partner])) > 0.95, "pushed along %v", push)
	// Without pairs the plane's image stands in, which misses the raised partner.
	sculptor_mirror_clear(&p.sculptor)
	before2 := slice.clone(pos, context.temp_allocator)
	_ = apply_dab(&p.sculptor, {kind = .Draw, radius = 0.1, strength = 1, symmetry = {.X}, poseable = true}, center)
	testing.expect(t, pos[partner] == before2[partner], "the plane's image reached the raised partner")
}

// An unposed sphere dabbed with poseable symmetry comes out as the plane's mirror does.
@(test)
poseable_dab_matches_the_plane_unposed :: proc(t: ^testing.T) {
	p := posed_make(4)
	defer posed_free(p)
	_, ok := sculptor_mirror_find(&p.sculptor, .X, {})
	testing.expect(t, ok)
	center := linalg.normalize(Vec3{0.5, 0.3, 0.8})
	near := 0
	pos := p.mesh.positions[:]
	for q, i in pos do if linalg.length(q - center) < linalg.length(pos[near] - center) do near = i
	before := slice.clone(pos, context.temp_allocator)
	_ = apply_dab(&p.sculptor, {kind = .Draw, radius = 0.3, strength = 1, symmetry = {.X}, poseable = true}, pos[near])
	_ = sculptor_flush(&p.sculptor)
	worst: f32
	for q, i in pos {
		r := pos[p.partner[i]]
		worst = max(worst, linalg.length(q - Vec3{-r.x, r.y, r.z}))
	}
	testing.expect(t, pos[near] != before[near], "the dab did nothing")
	testing.expectf(t, worst < 1e-3, "the two sides differ by %v", worst)
}

// Dynamic topology drops the pairs; a mesh with nothing to pair finds none.
@(test)
mirror_pairs_drop_with_dynamic_topology :: proc(t: ^testing.T) {
	p := posed_make(2)
	defer posed_free(p)
	_, ok := sculptor_mirror_find(&p.sculptor, .X, {})
	testing.expect(t, ok && sculptor_mirror_ready(&p.sculptor))
	testing.expect(t, sculptor_dyn_enable(&p.sculptor))
	testing.expect(t, !sculptor_mirror_ready(&p.sculptor), "pairs kept under dynamic topology")
	_, again := sculptor_mirror_find(&p.sculptor, .X, {})
	testing.expect(t, !again, "pairs found under dynamic topology")
}
