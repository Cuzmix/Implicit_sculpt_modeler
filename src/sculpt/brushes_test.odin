package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sculptor over an icosphere, for the tests below; free with sphere_free.
@(private = "file")
Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
	before:   []Vec3, // positions after setup, before the test sculpts
}

@(private = "file")
sphere_make :: proc(subdiv: int, pool: ^jobs.Pool = nil) -> ^Sphere {
	sp := new(Sphere)
	sp.mesh = geom.icosphere(subdiv)
	sculptor_init(&sp.sculptor, &sp.mesh, pool, 64)
	for id in 0 ..< len(sp.sculptor.nodes) do mark_stale(&sp.sculptor, u32(id), .Shape)
	_ = sculptor_flush(&sp.sculptor)
	sp.before = slice.clone(sp.mesh.positions[:], context.temp_allocator)
	return sp
}

@(private = "file")
sphere_free :: proc(sp: ^Sphere) {
	sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	free(sp)
}

@(private = "file")
TOP :: Vec3{0, 0, 1}

// Every new brush changes only what lies inside its radius, and changes something.
@(test)
brushes_move_only_inside_radius :: proc(t: ^testing.T) {
	for kind in ([?]Brush_Kind{.Clay, .Flatten, .Inflate, .Pinch, .Crease}) {
		for invert in ([2]bool{false, true}) {
			sp := sphere_make(4)
			defer sphere_free(sp)
			// A bump first, so the plane brushes have something to level.
			_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.2, strength = 1}, TOP)
			bumped := slice.clone(sp.mesh.positions[:], context.temp_allocator)
			moved := apply_dab(&sp.sculptor, {kind = kind, radius = 0.35, strength = 1, invert = invert}, TOP)
			testing.expectf(t, moved > 0, "%v (invert %v) moved nothing", kind, invert)
			for p, i in sp.mesh.positions {
				if linalg.length(bumped[i] - TOP) >= 0.35 && p != bumped[i] {
					testing.expectf(t, false, "%v moved a vertex outside its radius", kind)
					break
				}
			}
		}
	}
}

@(test)
inflate_moves_along_vertex_normals :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	center := linalg.normalize(Vec3{0.3, 0.2, 1})
	_ = apply_dab(&sp.sculptor, {kind = .Inflate, radius = 0.4, strength = 1}, center)
	moved := 0
	for p, i in sp.mesh.positions {
		step := p - sp.before[i]
		if step == {} do continue
		moved += 1
		// On a sphere each vertex normal points straight out.
		testing.expect(t, linalg.dot(linalg.normalize(step), sp.before[i]) > 0.999, "inflate moved a vertex off its normal")
	}
	testing.expect(t, moved > 0, "inflate moved nothing")
}

@(test)
flatten_levels_a_bump :: proc(t: ^testing.T) {
	sp := sphere_make(5)
	defer sphere_free(sp)
	for _ in 0 ..< 4 do _ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.15, strength = 1}, TOP)
	peak := max_height(sp.mesh)
	for _ in 0 ..< 10 do _ = apply_dab(&sp.sculptor, {kind = .Flatten, radius = 0.3, strength = 1}, TOP)
	testing.expectf(t, max_height(sp.mesh) < 1 + 0.5 * (peak - 1), "flatten left the bump at %v of %v", max_height(sp.mesh), peak)
}

// Clay only ever builds up, a dab never past its plane.
@(test)
clay_builds_up_toward_its_plane :: proc(t: ^testing.T) {
	sp := sphere_make(5)
	defer sphere_free(sp)
	brush := Brush{kind = .Clay, radius = 0.3, strength = 1}
	_ = apply_dab(&sp.sculptor, brush, TOP)
	// The plane sits CLAY_HEIGHT radii above the average of the area, which is below the top.
	testing.expect(t, max_height(sp.mesh) <= 1 + brush.radius * CLAY_HEIGHT, "clay went past its plane")
	for _ in 0 ..< 29 do _ = apply_dab(&sp.sculptor, brush, TOP)
	raised := 0
	for p, i in sp.mesh.positions {
		testing.expect(t, p.z >= sp.before[i].z - 1e-6, "clay lowered a vertex")
		if p.z > sp.before[i].z + 1e-4 do raised += 1
	}
	testing.expect(t, raised > 10, "clay raised nothing")
}

@(test)
pinch_pulls_toward_the_centre :: proc(t: ^testing.T) {
	for invert in ([2]bool{false, true}) {
		sp := sphere_make(4)
		defer sphere_free(sp)
		_ = apply_dab(&sp.sculptor, {kind = .Pinch, radius = 0.3, strength = 1, invert = invert}, TOP)
		closer, farther := 0, 0
		for p, i in sp.mesh.positions {
			if p == sp.before[i] do continue
			if p.xy == {} do continue // the vertex under the centre stays put
			if linalg.length(p.xy) < linalg.length(sp.before[i].xy) do closer += 1
			else do farther += 1
		}
		if invert {
			testing.expect(t, farther > 0 && closer == 0, "inverted pinch should push apart")
		} else {
			testing.expect(t, closer > 0 && farther == 0, "pinch should pull together")
		}
	}
}

@(test)
crease_cuts_in :: proc(t: ^testing.T) {
	for invert in ([2]bool{false, true}) {
		sp := sphere_make(4)
		defer sphere_free(sp)
		_ = apply_dab(&sp.sculptor, {kind = .Crease, radius = 0.3, strength = 1, invert = invert}, TOP)
		top := top_vertex(sp.mesh)
		if invert {
			testing.expect(t, linalg.length(sp.mesh.positions[top]) > 1, "inverted crease should raise a ridge")
		} else {
			testing.expect(t, linalg.length(sp.mesh.positions[top]) < 1, "crease should cut in")
		}
	}
}

// A dab mirrored across X leaves a mirror-symmetric sphere mirror-symmetric.
@(test)
symmetric_dabs_mirror :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	mirror := mirror_map(sp.mesh, .X)
	center := linalg.normalize(Vec3{0.5, 0.3, 0.8})
	for kind in ([?]Brush_Kind{.Draw, .Clay, .Pinch, .Smooth}) {
		_ = apply_dab(&sp.sculptor, {kind = kind, radius = 0.3, strength = 1, symmetry = {.X}}, center)
	}
	_ = sculptor_flush(&sp.sculptor)
	worst: f32
	for p, i in sp.mesh.positions {
		q := sp.mesh.positions[mirror[i]]
		worst = max(worst, linalg.length(p - Vec3{-q.x, q.y, q.z}))
	}
	testing.expectf(t, worst < 1e-5, "mirror images differ by %v", worst)
	near := nearest(sp.before, center)
	testing.expect(t, sp.mesh.positions[near] != sp.before[near], "the dab did nothing")
	all := mirrors({.X, .Y, .Z})
	testing.expect_value(t, len(all), 8)
	for a, i in all do for b in all[:i] do testing.expect(t, a != b, "a mirror image repeats")
	testing.expect_value(t, len(mirrors({.Y})), 2)
}

@(test)
grab_drags_by_the_offset :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	s := &sp.sculptor
	sculptor_stroke_begin(s)
	center := linalg.normalize(Vec3{0.4, 0, 0.9})
	held := sculptor_grab_begin(s, {kind = .Grab, radius = 0.3, strength = 1, symmetry = {.X}}, center)
	testing.expect(t, held > 0, "grab held nothing")
	offset := Vec3{0.05, 0.1, 0}
	for k in 1 ..= 4 do _ = sculptor_grab_move(s, offset * f32(k) / 4)
	near := nearest(sp.before, center)
	mirrored := nearest(sp.before, center * Vec3{-1, 1, 1})
	step := sp.mesh.positions[near] - sp.before[near]
	testing.expect(t, linalg.length(step - offset) < 0.02, "the vertex under the brush should follow the pointer")
	mstep := sp.mesh.positions[mirrored] - sp.before[mirrored]
	testing.expect(t, linalg.length(mstep - offset * Vec3{-1, 1, 1}) < 0.02, "the mirror image should follow the mirrored way")
	for p, i in sp.mesh.positions {
		if linalg.length(sp.before[i] - center) >= 0.3 && linalg.length(sp.before[i] - center * Vec3{-1, 1, 1}) >= 0.3 {
			testing.expect_value(t, p, sp.before[i])
		}
	}
	for node in s.bvh.nodes {
		if node.count > 0 do testing.expect_value(t, node.bounds, geom.leaf_bounds(s.bvh, sp.mesh, node))
	}
	sculptor_grab_end(s)
	testing.expect(t, sculptor_stroke_end(s), "the grab was not an undo step")
	testing.expect(t, sculptor_undo(s), "undo failed")
	for p, i in sp.mesh.positions do testing.expect_value(t, p, sp.before[i])
}

// Masked vertices stay put under every brush, in proportion to the mask.
@(test)
mask_shields_vertices :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	s := &sp.sculptor
	testing.expect(t, sculptor_mask_command(s, .Fill), "fill was not a step")
	for kind in ([?]Brush_Kind{.Draw, .Smooth, .Clay, .Inflate, .Crease}) {
		testing.expect_value(t, apply_dab(s, {kind = kind, radius = 0.4, strength = 1}, TOP), 0)
	}
	testing.expect(t, sculptor_mask_command(s, .Clear), "clear was not a step")
	testing.expect(t, !sculptor_has_mask(s), "clear left a mask")

	// Paint a mask on the top, then draw over a wider area: only the unmasked part moves.
	painted := apply_dab(s, {kind = .Mask, radius = 0.2, strength = 1}, TOP)
	testing.expect(t, painted > 0, "the mask brush painted nothing")
	top := top_vertex(sp.mesh)
	testing.expect_value(t, s.mask[top], 255)
	testing.expect(t, apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, TOP) > 0, "draw moved nothing")
	testing.expect_value(t, sp.mesh.positions[top], sp.before[top])
	for p, i in sp.mesh.positions {
		if s.mask[i] == 0 && linalg.length(sp.before[i] - TOP) < 0.45 do testing.expect(t, p != sp.before[i], "an unmasked vertex did not move")
	}
	_ = apply_dab(s, {kind = .Mask, radius = 0.2, strength = 1, invert = true}, TOP)
	testing.expect_value(t, s.mask[top], 0)
}

// Mask strokes and commands undo and redo, and only send masks (not normals) to update.
@(test)
mask_undo_and_upload :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	s := &sp.sculptor
	normals := slice.clone(sp.mesh.normals[:], context.temp_allocator)
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Mask, radius = 0.3, strength = 0.6}, TOP)
	_ = apply_dab(s, {kind = .Mask, radius = 0.3, strength = 0.6}, linalg.normalize(Vec3{0.2, 0, 1}))
	testing.expect(t, sculptor_stroke_end(s), "mask stroke was not a step")
	painted := slice.clone(s.mask, context.temp_allocator)
	ranges := sculptor_flush(s)
	testing.expect(t, len(ranges) > 0, "painting uploads nothing")
	for i in 0 ..< u32(len(painted)) {
		if painted[i] == 0 do continue
		inside := false
		for r in ranges do inside ||= i >= r.first && i < r.first + r.count
		testing.expect(t, inside, "masked vertex outside the upload ranges")
	}
	testing.expect(t, slice.equal(sp.mesh.normals[:], normals), "masking changed normals")
	testing.expect(t, sculptor_mask_command(s, .Invert), "invert was not a step")
	testing.expect_value(t, s.mask[0], 255 - painted[0])

	testing.expect(t, sculptor_undo(s), "undo invert failed")
	testing.expect(t, slice.equal(s.mask, painted), "undo of invert is off")
	testing.expect(t, sculptor_undo(s), "undo stroke failed")
	testing.expect(t, !sculptor_has_mask(s), "undo of the stroke left a mask")
	testing.expect(t, len(sculptor_flush(s)) > 0, "undo uploads nothing")
	testing.expect(t, sculptor_redo(s), "redo failed")
	testing.expect(t, slice.equal(s.mask, painted), "redo of the stroke is off")
	testing.expect_value(t, sp.mesh.positions[0], sp.before[0])
}

// A mask painted on one subdivision level holds on the others.
@(test)
mask_follows_levels :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	base := &l.levels[0].sculptor
	_ = apply_dab(base, {kind = .Mask, radius = 0.6, strength = 1}, TOP)
	testing.expect(t, levels_subdivide(&l), "subdivide failed")
	testing.expect(t, levels_subdivide(&l), "subdivide failed")
	for k in 1 ..< len(l.levels) {
		lv, below := l.levels[k], l.levels[k - 1]
		for u in 0 ..< len(below.mesh.positions) {
			testing.expect_value(t, lv.sculptor.mask[lv.even_of[u]], below.sculptor.mask[u])
		}
	}
	top := &l.levels[2].sculptor
	testing.expect(t, sculptor_mask_command(top, .Invert), "invert was not a step")
	_ = sculptor_flush(top)
	levels_set_current(&l, 0)
	for u in 0 ..< len(base.mask) {
		testing.expect_value(t, base.mask[u], top.mask[l.levels[2].even_of[l.levels[1].even_of[u]]])
	}
	testing.expect(t, len(sculptor_flush(base)) > 0, "the carried mask uploads nothing")
}

// The heaviest brushes give the same mesh on worker threads as on one.
@(test)
new_brushes_parallel_match_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> []Vec3 {
		sp := sphere_make(5, pool)
		defer sphere_free(sp)
		kinds := [?]Brush_Kind{.Clay, .Flatten, .Inflate, .Pinch, .Crease, .Mask, .Draw}
		for kind, i in kinds {
			center := linalg.normalize(Vec3{0.2 * f32(i), 0.1, 1})
			_ = apply_dab(&sp.sculptor, {kind = kind, radius = 0.5, strength = 0.7, symmetry = {.X, .Y}}, center)
		}
		_ = sculptor_flush(&sp.sculptor)
		return slice.clone(sp.mesh.positions[:], context.temp_allocator)
	}
	serial, parallel := run(nil), run(&pool)
	testing.expect(t, slice.equal(serial, parallel), "parallel brushes differ from serial")
}

@(private = "file")
max_height :: proc(m: geom.Mesh) -> f32 {
	h := min(f32)
	for p in m.positions do h = max(h, p.z)
	return h
}

// The unsculpted sphere's vertex at its top (it stays the nearest to TOP).
@(private = "file")
top_vertex :: proc(m: geom.Mesh) -> int {
	return nearest(m.positions[:], TOP)
}

@(private = "file")
nearest :: proc(positions: []Vec3, p: Vec3) -> int {
	best, best_d := 0, max(f32)
	for q, i in positions {
		if d := linalg.length(q - p); d < best_d do best, best_d = i, d
	}
	return best
}

// For each vertex, the vertex at its mirror image across the plane `axis` = 0.
@(private = "file")
mirror_map :: proc(m: geom.Mesh, axis: Axis) -> []int {
	out := make([]int, len(m.positions), context.temp_allocator)
	for p, i in m.positions {
		q := p
		q[int(axis)] = -q[int(axis)]
		out[i] = nearest(m.positions[:], q)
	}
	return out
}
