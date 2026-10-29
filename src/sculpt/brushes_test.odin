package sculpt

import "core:math"
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
	// On a curved surface it builds the top itself up, rather than only levelling it off
	// as a plane nearer the area's average did (Clay seemed to do nothing on a sphere).
	testing.expectf(t, max_height(sp.mesh) > 1 + 0.6 * brush.radius, "clay left the top at %v", max_height(sp.mesh))
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

// A tilted Draw pushes along the turned normal, and its mirror image the mirrored way.
@(test)
tilt_turns_the_push_and_mirrors :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	mirror := mirror_map(sp.mesh, .X)
	center := linalg.normalize(Vec3{0.5, 0.3, 0.8})
	turn := linalg.matrix3_rotate(f32(0.5), Vec3{0, 1, 0}) // about 29 degrees about +Y
	_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.3, strength = 1, symmetry = {.X}, tilt = turn}, center)
	near := nearest(sp.before, center)
	push := linalg.normalize(sp.mesh.positions[near] - sp.before[near])
	// The untilted push is about the surface normal there, the centre's direction.
	testing.expectf(t, linalg.dot(push, linalg.normalize(turn * center)) > 0.99, "pushed along %v, not the turned normal", push)
	testing.expect(t, linalg.dot(push, center) < 0.93, "the push did not turn")
	worst: f32
	for p, i in sp.mesh.positions {
		q := sp.mesh.positions[mirror[i]]
		worst = max(worst, linalg.length(p - Vec3{-q.x, q.y, q.z}))
	}
	testing.expectf(t, worst < 1e-5, "mirror images differ by %v", worst)
}

@(test)
alphas_fade_out_and_sample_between_pixels :: proc(t: ^testing.T) {
	for shape in Alpha_Shape {
		a := alpha_make(shape, 64)
		defer alpha_destroy(&a)
		edge, low, high: f32 = 0, 1, 0
		for j in 0 ..< a.size {
			for i in 0 ..< a.size {
				value := a.values[j * a.size + i]
				low, high = min(low, value), max(high, value)
				if i == 0 || j == 0 || i == a.size - 1 || j == a.size - 1 do edge = max(edge, value)
			}
		}
		testing.expectf(t, low >= 0 && high <= 1 && high > 0.5, "%v runs %v to %v", shape, low, high)
		testing.expectf(t, edge < 0.01, "%v is %v at its edge, where stamps would show a rim", shape, edge)
	}
	square := alpha_make(.Square, 64)
	defer alpha_destroy(&square)
	testing.expect(t, alpha_sample(&square, 0, 0) == 1 && alpha_sample(&square, 1, 0) == 0 && alpha_sample(&square, -2, 0.5) == 0)

	// A row of three pixels, padded to a square: the middle row, and linear between.
	row, ok := alpha_from_grey({0, 1, 0.5}, 3, 1)
	defer alpha_destroy(&row)
	testing.expect(t, ok && row.size == 3)
	testing.expect(t, row.values[3] == 0 && row.values[4] == 1 && row.values[5] == 0.5 && row.values[0] == 0 && row.values[8] == 0)
	testing.expect(t, abs(alpha_sample(&row, -0.5, 0) - 0.5) < 1e-6, "halfway between 0 and 1")
	// A large image is averaged down.
	big := make([]f32, 1024 * 1024, context.temp_allocator)
	for &value, i in big do value = 1 if (i / 1024) < 512 else 0
	down, down_ok := alpha_from_grey(big, 1024, 1024)
	defer alpha_destroy(&down)
	testing.expect(t, down_ok && down.size == ALPHA_MAX_SIZE && down.values[0] == 1 && down.values[len(down.values) - 1] == 0)
}

// The place on a dab's alpha of a vertex at `p` near the top of the sphere, where the
// area normal is +Z: u along +X, v along +Y, in radii.
@(private = "file")
top_uv :: proc(p: Vec3, radius: f32) -> [2]f32 {return {p.x / radius, p.y / radius}}

@(test)
alpha_stamps_its_shape_facing_up :: proc(t: ^testing.T) {
	R :: 0.3
	sp := sphere_make(5)
	defer sphere_free(sp)
	square := alpha_make(.Square)
	defer alpha_destroy(&square)
	_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = R, strength = 1, alpha = &square, alpha_up = {0, 1, 0}}, TOP)
	corner_moved := false
	for p, i in sp.mesh.positions {
		if p == sp.before[i] do continue
		uv := top_uv(sp.before[i], R)
		testing.expectf(t, sp.before[i].z > 0 && abs(uv.x) < 1.01 && abs(uv.y) < 1.01, "moved a vertex at %v, off the square", uv)
		if linalg.length(uv) > 1.05 do corner_moved = true
	}
	testing.expect(t, corner_moved, "a square alpha reaches past the round brush into its corners")

	// The star's point goes where alpha_up says.
	star := alpha_make(.Star)
	defer alpha_destroy(&star)
	above := nearest(sp.before, linalg.normalize(Vec3{0, 0.7 * R, 1}))
	below := nearest(sp.before, linalg.normalize(Vec3{0, -0.7 * R, 1}))
	for up in ([2]Vec3{{0, 1, 0}, {0, -1, 0}}) {
		before := slice.clone(sp.mesh.positions[:], context.temp_allocator)
		_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = R, strength = 1, alpha = &star, alpha_up = up}, TOP)
		rise_above := linalg.length(sp.mesh.positions[above] - before[above])
		rise_below := linalg.length(sp.mesh.positions[below] - before[below])
		if up.y > 0 {
			testing.expectf(t, rise_above > 0 && rise_below == 0, "up +Y: the point should rise above (%v), not below (%v)", rise_above, rise_below)
		} else {
			testing.expectf(t, rise_below > 0 && rise_above == 0, "up -Y: the point should rise below (%v), not above (%v)", rise_below, rise_above)
		}
	}
}

@(test)
alpha_mirrors_with_symmetry :: proc(t: ^testing.T) {
	sp := sphere_make(5)
	defer sphere_free(sp)
	mirror := mirror_map(sp.mesh, .X)
	// Only the image's left half raises anything.
	grey := make([]f32, 32 * 32, context.temp_allocator)
	for &value, i in grey do value = 1 if i % 32 < 16 else 0
	half, _ := alpha_from_grey(grey, 32, 32)
	defer alpha_destroy(&half)
	center := linalg.normalize(Vec3{0.5, 0, 0.8})
	_ = apply_dab(&sp.sculptor, {kind = .Mask, radius = 0.25, strength = 1, symmetry = {.X}, alpha = &half, alpha_up = {0, 1, 0}}, center)
	testing.expect(t, sp.sculptor.mask != nil)
	if sp.sculptor.mask == nil do return
	worst := 0
	left, right := 0, 0
	for v in 0 ..< len(sp.mesh.positions) {
		worst = max(worst, abs(int(sp.sculptor.mask[v]) - int(sp.sculptor.mask[mirror[v]])))
		if sp.sculptor.mask[v] == 0 || sp.before[v].x < 0 do continue
		// Seen from outside, the image's left is toward the middle of the sphere. The
		// pixels either side of the image's middle blend, so a strip there counts as
		// neither.
		x := sp.before[v].x - nearest_x(sp.before, center)
		if x < -0.02 do left += 1
		else if x > 0.02 do right += 1
	}
	testing.expectf(t, worst <= 1, "the mirror image masked differently, by up to %d", worst)
	testing.expectf(t, left > 0 && right == 0, "masked %d vertices on the image's left and %d on its right", left, right)
}

@(private = "file")
nearest_x :: proc(positions: []Vec3, p: Vec3) -> f32 {return positions[nearest(positions, p)].x}

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

// Grow spreads the mask one ring of triangles a step, Shrink draws it back, and each
// press is one undo step.
@(test)
mask_grow_and_shrink_move_the_edge_a_ring :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	s := &sp.sculptor
	mask_ensure(s)
	seed := top_vertex(sp.mesh)
	s.mask[seed] = 255
	start := slice.clone(s.mask, context.temp_allocator)
	one := ring_grown(sp.mesh, start)
	two := ring_grown(sp.mesh, one)
	testing.expect(t, sculptor_mask_command(s, .Grow), "grow was not a step")
	testing.expect(t, slice.equal(s.mask, one), "one step of grow is not the first ring")
	testing.expect(t, sculptor_mask_command(s, .Grow), "grow was not a step")
	testing.expect(t, slice.equal(s.mask, two), "two steps of grow are not two rings")
	testing.expect(t, sculptor_mask_command(s, .Shrink), "shrink was not a step")
	testing.expect(t, slice.equal(s.mask, one), "shrink did not take back the outer ring")
	testing.expect(t, sculptor_mask_command(s, .Shrink, steps = 2), "shrink was not a step")
	testing.expect(t, !sculptor_has_mask(s), "two steps of shrink left a mask")
	testing.expect(t, !sculptor_mask_command(s, .Grow, steps = 3), "growing no mask was a step")
	for _ in 0 ..< 4 do testing.expect(t, sculptor_undo(s), "undo failed")
	testing.expect(t, slice.equal(s.mask, start), "undo did not bring back the seed")
	testing.expect(t, sculptor_mask_command(s, .Grow, steps = 2), "grow was not a step")
	testing.expect(t, slice.equal(s.mask, two), "two steps in one press are not two rings")
}

// Blur softens a hard edge only near it; Sharpen then narrows the soft edge back
// toward a hard one without moving it.
@(test)
mask_blur_softens_and_sharpen_narrows_the_edge :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	s := &sp.sculptor
	mask_ensure(s)
	for p, v in sp.mesh.positions do s.mask[v] = 255 if p.x > 0 else 0
	hard := slice.clone(s.mask, context.temp_allocator)
	partial :: proc(mask: []u8) -> (n: int) {
		for k in mask do if k != 0 && k != 255 do n += 1
		return
	}
	testing.expect(t, sculptor_mask_command(s, .Blur, steps = 3), "blur was not a step")
	soft := partial(s.mask)
	testing.expect(t, soft > 0, "blur left the edge hard")
	for p, v in sp.mesh.positions {
		// Three steps reach three rings, under 0.3 on this sphere.
		if abs(p.x) > 0.3 do testing.expect_value(t, s.mask[v], hard[v])
	}
	testing.expect(t, sculptor_mask_command(s, .Sharpen, steps = 20), "sharpen was not a step")
	testing.expectf(t, partial(s.mask) < soft / 2, "sharpen left %d of %d vertices half masked", partial(s.mask), soft)
	for p, v in sp.mesh.positions {
		if p.x > 0.1 do testing.expectf(t, s.mask[v] >= 128, "sharpen unmasked x = %v", p.x)
		if p.x < -0.1 do testing.expectf(t, s.mask[v] < 128, "sharpen masked x = %v", p.x)
	}
}

// Working only near the mask's edge gives what every vertex worked out every step
// gives, for each neighbourhood command, on a mask with soft and hard edges and a
// partly masked patch.
@(test)
mask_steps_match_a_full_pass :: proc(t: ^testing.T) {
	for command in ([?]Mask_Command{.Blur, .Sharpen, .Grow, .Shrink}) {
		sp := sphere_make(4)
		s := &sp.sculptor
		_ = apply_dab(s, {kind = .Mask, radius = 0.7, strength = 0.9}, TOP)
		_ = apply_dab(s, {kind = .Mask, radius = 0.3, strength = 0.4}, {1, 0, 0})
		for p, v in sp.mesh.positions do if p.z < -0.5 do s.mask[v] = 255
		want := slice.clone(s.mask, context.temp_allocator)
		from := make([]u8, len(want), context.temp_allocator)
		for _ in 0 ..< 5 {
			copy(from, want)
			for v in 0 ..< u32(len(want)) do want[v] = mask_filtered(s, from, command, v)
		}
		_ = sculptor_mask_command(s, command, steps = 5)
		testing.expectf(t, slice.equal(s.mask, want), "%v differs from a full pass", command)
		sphere_free(sp)
	}
}

// Each vertex masked when a triangle it is a corner of has a masked corner in `mask`
// (255 or 0 only): what one step of Grow gives, worked out from the triangles.
@(private = "file")
ring_grown :: proc(m: geom.Mesh, mask: []u8) -> []u8 {
	out := slice.clone(mask, context.temp_allocator)
	for f in 0 ..< len(m.indices) / 3 {
		tri := m.indices[3 * f:][:3]
		if mask[tri[0]] == 255 || mask[tri[1]] == 255 || mask[tri[2]] == 255 {
			for v in tri do out[v] = 255
		}
	}
	return out
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

	// And the neighbourhood mask commands, which read across node borders.
	masks :: proc(pool: ^jobs.Pool) -> []u8 {
		sp := sphere_make(5, pool)
		defer sphere_free(sp)
		s := &sp.sculptor
		_ = apply_dab(s, {kind = .Mask, radius = 0.6, strength = 0.8}, TOP)
		for command in ([?]Mask_Command{.Grow, .Blur, .Sharpen, .Shrink}) do _ = sculptor_mask_command(s, command, steps = 2)
		return slice.clone(s.mask, context.temp_allocator)
	}
	testing.expect(t, slice.equal(masks(nil), masks(&pool)), "parallel mask commands differ from serial")
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

// A drawn falloff is the curve read from the rim in, and brushes follow it: a firm
// curve moves vertices near the rim almost as far as the centre, the built-in one
// barely does.
@(test)
drawn_falloff_shapes_the_dab :: proc(t: ^testing.T) {
	cone: Falloff
	falloff_set_curve(&cone, geom.CURVE_LINEAR)
	for x in ([?]f32{0, 0.1, 0.5, 0.9}) {
		w := falloff_drawn(&cone, x * x)
		testing.expectf(t, abs(w - (1 - x)) < 0.01, "cone at %v: %v", x, w)
	}
	testing.expect(t, falloff_drawn(&cone, 1) == 0 && falloff_drawn(&cone, 2) == 0)

	firm: Falloff
	falloff_set_curve(&firm, {{0, 0.9}, {0.1, 1}})
	moved :: proc(shape: ^Falloff) -> (centre, rim: f32) {
		sp := sphere_make(5)
		defer sphere_free(sp)
		_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.4, strength = 0.5, falloff_shape = shape}, TOP)
		for p, v in sp.mesh.positions {
			d := linalg.length(p - sp.before[v])
			off := linalg.length(sp.before[v].xy)
			if off < 0.05 do centre = max(centre, d)
			if off > 0.26 && off < 0.3 do rim = max(rim, d)
		}
		return
	}
	c0, r0 := moved(nil)
	c1, r1 := moved(&firm)
	testing.expectf(t, c0 > 0 && c1 > 0, "nothing moved: %v %v", c0, c1)
	testing.expectf(t, r0 < 0.4 * c0, "built-in falloff at 0.7 radii moved %v of %v", r0, c0)
	testing.expectf(t, r1 > 0.8 * c1, "firm falloff at 0.7 radii moved %v of %v", r1, c1)
}

// Focal shift reshapes a falloff without changing its ends: 0 leaves the table as it was,
// a positive shift weighs the middle of the brush less and a negative one more, and every
// shape falls from 1 at the centre to 0 at the rim.
@(test)
focal_shift_moves_the_weight :: proc(t: ^testing.T) {
	plain, cone, flat, point: Falloff
	falloff_set_curve(&cone, geom.CURVE_LINEAR)
	falloff_set_shaped(&flat, geom.CURVE_LINEAR, 0)
	testing.expect(t, cone.table == flat.table)
	falloff_set_shaped(&plain, nil, 0)
	for w, i in plain.table do testing.expect_value(t, w, falloff(f32(i) / FALLOFF_STEPS))
	half := [?]f32{FOCAL_MIN, -50, 0, 50, FOCAL_MAX}
	last: f32 = 2
	for focal in half {
		f: Falloff
		falloff_set_shaped(&f, nil, focal)
		testing.expect_value(t, f.table[0], 1)
		testing.expect_value(t, f.table[FALLOFF_STEPS], 0)
		for i in 1 ..= FALLOFF_STEPS do testing.expectf(t, f.table[i] <= f.table[i - 1], "focal %v rises at %d", focal, i)
		mid := falloff_drawn(&f, 0.25)
		testing.expectf(t, mid < last, "focal %v at half a radius: %v, not under %v", focal, mid, last)
		last = mid
	}
	// Beyond the first cells, where the tip is rounded off, the table follows the shape.
	for focal in ([?]f32{50, FOCAL_MAX, -50}) {
		f: Falloff
		falloff_set_shaped(&f, nil, focal)
		p := math.pow(2, -focal / 50)
		for i in 0 ..= 64 {
			d := 0.125 + 0.875 * f32(i) / 64
			exact := falloff(math.pow(d * d, p))
			testing.expectf(t, abs(falloff_drawn(&f, d * d) - exact) < 0.005, "focal %v at %v: %v, not %v", focal, d, falloff_drawn(&f, d * d), exact)
		}
	}
	falloff_set_shaped(&point, nil, FOCAL_MAX)
	falloff_set_shaped(&flat, nil, FOCAL_MIN)
	testing.expectf(t, falloff_drawn(&point, 0.25) < 0.2 && falloff_drawn(&flat, 0.25) > 0.95, "point %v, plateau %v", falloff_drawn(&point, 0.25), falloff_drawn(&flat, 0.25))
}

// A mask shape masks what falls inside it on screen, through the mesh, and is an undo
// step; an unmask shape inside it clears what it covers.
@(test)
mask_shape_masks_inside_it :: proc(t: ^testing.T) {
	sp := sphere_make(5)
	defer sphere_free(sp)
	s := &sp.sculptor
	// Looking down z, flat: x and y are already the screen.
	clip: matrix[4, 4]f32 = 1
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculptor_mask_shape(s, clip, rect, false))
	inside :: proc(p: Vec3, r: f32) -> bool {return abs(p.x) < r && abs(p.y) < r}
	wrong := 0
	for p, v in sp.mesh.positions {
		near_edge := abs(abs(p.x) - 0.3) < 0.01 || abs(abs(p.y) - 0.3) < 0.01
		if !near_edge && (s.mask[v] == 255) != inside(p, 0.3) do wrong += 1
	}
	testing.expectf(t, wrong == 0, "%d vertices masked wrongly", wrong)
	// A triangle lasso unmasks its part.
	tri := [][2]f32{{0, 0.25}, {-0.25, -0.25}, {0.25, -0.25}}
	testing.expect(t, sculptor_mask_shape(s, clip, tri, true))
	cleared := 0
	for p, v in sp.mesh.positions do if abs(p.x) < 0.02 && abs(p.y) < 0.02 && s.mask[v] == 0 do cleared += 1
	testing.expect(t, cleared > 0)
	testing.expect(t, sculptor_undo(s) && sculptor_undo(s))
	for k in s.mask do if k != 0 {
		testing.expect(t, false, "undo left a mask")
		break
	}
}

// Mask by cavity masks a groove a Crease cut and leaves the round sphere alone.
@(test)
mask_cavity_finds_a_groove :: proc(t: ^testing.T) {
	sp := sphere_make(6)
	defer sphere_free(sp)
	s := &sp.sculptor
	_ = apply_dab(s, {kind = .Crease, radius = 0.15, strength = 1}, TOP)
	_ = apply_dab(s, {kind = .Crease, radius = 0.15, strength = 1}, TOP)
	_ = sculptor_flush(s)
	testing.expect(t, sculptor_mask_command(s, .Cavity))
	groove, elsewhere: int
	for p, v in sp.mesh.positions {
		off := linalg.length(sp.before[v].xy)
		if off < 0.02 && sp.before[v].z > 0 && s.mask[v] > 128 do groove += 1
		if linalg.length(p - TOP) > 0.5 && s.mask[v] > 10 do elsewhere += 1
	}
	testing.expectf(t, groove > 0, "nothing in the groove masked")
	testing.expectf(t, elsewhere == 0, "%d vertices away from the groove masked", elsewhere)
}

@(test)
layer_stops_at_its_height :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil)
	defer sculptor_destroy(&s)
	defer geom.mesh_destroy(&m)
	sculptor_recompute_all(&s)
	brush := Brush{kind = .Layer, radius = 0.3, strength = 1}
	top := Vec3{0, 0, 1}
	peak := proc(m: ^geom.Mesh) -> (r: f32) {
		for p in m.positions do r = max(r, linalg.length(p))
		return
	}
	sculptor_stroke_begin(&s)
	for _ in 0 ..< 40 do _ = apply_dab(&s, brush, top)
	_ = sculptor_flush(&s)
	_ = sculptor_stroke_end(&s)
	height := peak(&m) - 1
	want := brush.radius * LAYER_HEIGHT
	testing.expectf(t, abs(height - want) < 0.1 * want, "one stroke raised %.4f, want %.4f", height, want)
	// A second stroke adds one more layer, no more.
	sculptor_stroke_begin(&s)
	for _ in 0 ..< 40 do _ = apply_dab(&s, brush, top * (1 + height))
	_ = sculptor_stroke_end(&s)
	testing.expectf(t, abs(peak(&m) - 1 - 2 * want) < 0.2 * want, "two strokes raised %.4f, want %.4f", peak(&m) - 1, 2 * want)
}

@(test)
snake_hook_pulls_out_a_horn :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil)
	defer sculptor_destroy(&s)
	defer geom.mesh_destroy(&m)
	sculptor_recompute_all(&s)
	brush := Brush{kind = .Snake_Hook, radius = 0.25, strength = 0.5, drag = {0, 0, 0.05}}
	at := Vec3{0, 0, 1}
	sculptor_stroke_begin(&s)
	for _ in 0 ..< 10 {
		_ = apply_dab(&s, brush, at)
		at += brush.drag
	}
	_ = sculptor_stroke_end(&s)
	tip: f32
	for p in m.positions do tip = max(tip, p.z)
	// The vertices at the centre follow the hook all the way.
	testing.expectf(t, tip > 1.4, "the tip reached %.3f", tip)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && r.degenerate_triangles == 0, "%v", r)
}

@(test)
morph_brings_the_surface_back :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil)
	defer sculptor_destroy(&s)
	defer geom.mesh_destroy(&m)
	sculptor_recompute_all(&s)
	testing.expect(t, sculptor_morph_store(&s))
	stored := make([]Vec3, len(m.positions))
	defer delete(stored)
	copy(stored, m.positions[:])
	top := Vec3{0, 0, 1}
	far :: proc(m: ^geom.Mesh, stored: []Vec3) -> (r: f32) {
		for p, v in m.positions do r = max(r, linalg.length(p - stored[v]))
		return
	}
	sculptor_stroke_begin(&s)
	for _ in 0 ..< 10 do _ = apply_dab(&s, Brush{kind = .Draw, radius = 0.3, strength = 1}, top)
	_ = sculptor_flush(&s)
	_ = sculptor_stroke_end(&s)
	moved := far(&m, stored)
	testing.expect(t, moved > 0.05)
	// Morph at full strength, many times: back to the stored surface.
	sculptor_stroke_begin(&s)
	for _ in 0 ..< 40 do _ = apply_dab(&s, Brush{kind = .Morph, radius = 0.5, strength = 1}, top * (1 + moved))
	_ = sculptor_stroke_end(&s)
	testing.expectf(t, far(&m, stored) < 0.01 * moved, "still %.5f from the target (moved %.4f)", far(&m, stored), moved)
	// Without a target the brush moves nothing.
	sculptor_morph_clear(&s)
	testing.expect(t, apply_dab(&s, Brush{kind = .Morph, radius = 0.5, strength = 1}, top) == 0)
}

@(test)
front_only_leaves_the_far_side :: proc(t: ^testing.T) {
	for front in ([2]bool{false, true}) {
		// A thin disc facing +z: a brush on its front reaches its back too.
		m := geom.icosphere(5)
		for &p in m.positions do p.z *= 0.05
		s: Sculptor
		sculptor_init(&s, &m, nil)
		sculptor_recompute_all(&s)
		before := slice.clone(m.positions[:])
		brush := Brush{kind = .Draw, radius = 0.5, strength = 1}
		if front do brush.facing = {0, 0, 1}
		_ = apply_dab(&s, brush, {0, 0, 0.05})
		back_moved := 0
		for p, v in m.positions do if before[v].z < 0 && p != before[v] do back_moved += 1
		testing.expectf(t, (back_moved == 0) == front, "front only %v: %d back vertices moved", front, back_moved)
		delete(before)
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
}

@(test)
stroke_restore_puts_the_surface_back :: proc(t: ^testing.T) {
	m := geom.icosphere(5)
	s: Sculptor
	sculptor_init(&s, &m, nil)
	defer sculptor_destroy(&s)
	defer geom.mesh_destroy(&m)
	sculptor_recompute_all(&s)
	start := slice.clone(m.positions[:])
	defer delete(start)
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, Brush{kind = .Draw, radius = 0.3, strength = 1}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_restore(&s))
	testing.expect(t, slice.equal(m.positions[:], start), "restore left the dab")
	// A second, bigger dab after the restore, then undo: back to the start in one step.
	_ = apply_dab(&s, Brush{kind = .Draw, radius = 0.6, strength = 1}, {0, 0, 1})
	testing.expect(t, sculptor_stroke_end(&s))
	testing.expect(t, !slice.equal(m.positions[:], start))
	testing.expect(t, sculptor_undo(&s))
	testing.expect(t, slice.equal(m.positions[:], start), "undo did not take the whole stroke back")
}

// A masked vertex anywhere is found: in the first word, in a later block, or among the
// last few that do not fill a word.
@(test)
has_mask_finds_any_masked_vertex :: proc(t: ^testing.T) {
	s: Sculptor
	testing.expect(t, !sculptor_has_mask(&s))
	s.mask = make([]u8, 8 * 5000 + 3)
	defer delete(s.mask)
	testing.expect(t, !sculptor_has_mask(&s))
	for at in ([?]int{0, 7, 8 * 4096 + 1, 8 * 5000 - 1, 8 * 5000, 8 * 5000 + 2}) {
		s.mask[at] = 1
		testing.expectf(t, sculptor_has_mask(&s), "vertex %d", at)
		s.mask[at] = 0
	}
}

// Radial symmetry lays a dab's copies evenly round its axis: on a sphere about Y, each of
// the four quarter turns of the point pressed is sculpted as a dab of its own there would.
@(test)
radial_symmetry_turns_every_dab :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	center := linalg.normalize(Vec3{0.7, 0.3, 0.5})
	brush := Brush{kind = .Draw, radius = 0.3, strength = 1}
	radial := brush
	radial.radial, radial.radial_axis = 4, .Y
	_ = apply_dab(&sp.sculptor, radial, center)
	turned := [4]Vec3{center, {center.z, center.y, -center.x}, {-center.x, center.y, -center.z}, {-center.z, center.y, center.x}}
	for p, k in turned {
		one := sphere_make(4)
		defer sphere_free(one)
		_ = apply_dab(&one.sculptor, brush, p)
		v := nearest(sp.before, p)
		got, want := sp.mesh.positions[v] - sp.before[v], one.mesh.positions[v] - one.before[v]
		testing.expect(t, linalg.length(want) > 0.005, "the dab pushed nothing out")
		testing.expectf(t, linalg.length(got - want) < 1e-4, "copy %d moved %v, a dab of its own %v", k, got, want)
	}
	// Between the copies nothing moved.
	between := linalg.normalize(Vec3{0.7, 0.3, 0.5} + Vec3{0.5, 0.3, -0.7})
	v := nearest(sp.before, between)
	testing.expect_value(t, sp.mesh.positions[v], sp.before[v])
	images := symmetry_images({symmetry = {.X}, radial = 3})
	testing.expect_value(t, len(images), 6)
	testing.expect(t, images[0].turn == 1 && !images[0].flipped, "the dab itself comes first, unturned")
}

// Local symmetry mirrors about the object's middle rather than its origin: a sphere built
// off the origin is sculpted on both sides of its own middle.
@(test)
local_symmetry_mirrors_about_the_middle :: proc(t: ^testing.T) {
	middle := Vec3{2, 0, 0}
	mesh := geom.icosphere(4)
	defer geom.mesh_destroy(&mesh)
	for &p in mesh.positions do p += middle
	s: Sculptor
	sculptor_init(&s, &mesh, nil, 64)
	defer sculptor_destroy(&s)
	before := slice.clone(mesh.positions[:], context.temp_allocator)
	center := linalg.normalize(Vec3{0.6, 0.2, 0.8}) + middle
	_ = apply_dab(&s, {kind = .Draw, radius = 0.3, strength = 1, symmetry = {.X}, sym_center = middle}, center)
	a, b := nearest(before, center), nearest(before, {2 * middle.x - center.x, center.y, center.z})
	rise_a := linalg.length(mesh.positions[a] - middle) - linalg.length(before[a] - middle)
	rise_b := linalg.length(mesh.positions[b] - middle) - linalg.length(before[b] - middle)
	testing.expect(t, rise_a > 0.005, "the dab pushed nothing out")
	testing.expectf(t, abs(rise_b - rise_a) < 1e-4, "the image rose %f, the dab %f", rise_b, rise_a)
}

// A grab with radial symmetry drags each copy's vertices the turned way.
@(test)
grab_follows_radial_turns :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	s := &sp.sculptor
	sculptor_stroke_begin(s)
	center := linalg.normalize(Vec3{0.9, 0, 0.4})
	held := sculptor_grab_begin(s, {kind = .Grab, radius = 0.3, strength = 1, radial = 2, radial_axis = .Y}, center)
	testing.expect(t, held > 0, "grab held nothing")
	offset := Vec3{0.05, 0.1, 0.02}
	_ = sculptor_grab_move(s, offset)
	opposite := nearest(sp.before, Vec3{-center.x, center.y, -center.z})
	step := sp.mesh.positions[opposite] - sp.before[opposite]
	testing.expectf(t, linalg.length(step - Vec3{-offset.x, offset.y, -offset.z}) < 0.02, "the half-turned copy moved %v", step)
	sculptor_stroke_end(s)
}

// A dab on the X plane with feathering moves the surface there as far as one dab without
// symmetry, where its mirror image would otherwise double it; away from the plane a
// feathered dab is the same as an unfeathered one.
@(test)
feathered_symmetry_does_not_double_on_the_plane :: proc(t: ^testing.T) {
	on_plane := linalg.normalize(Vec3{0, 0.3, 0.9})
	away := linalg.normalize(Vec3{0.7, 0.3, 0.6})
	rise :: proc(center: Vec3, symmetry: Symmetry, feather: bool) -> f32 {
		sp := sphere_make(4)
		defer sphere_free(sp)
		_ = apply_dab(&sp.sculptor, {kind = .Draw, radius = 0.3, strength = 0.2, symmetry = symmetry, feather = feather}, center)
		near := nearest(sp.before, center)
		return linalg.length(sp.mesh.positions[near]) - linalg.length(sp.before[near])
	}
	single, doubled, feathered := rise(on_plane, {}, false), rise(on_plane, {.X}, false), rise(on_plane, {.X}, true)
	testing.expectf(t, abs(doubled - 2 * single) < 0.1 * single, "unfeathered %v, one dab %v", doubled, single)
	testing.expectf(t, abs(feathered - single) < 1e-3 * single, "feathered %v, one dab %v", feathered, single)
	testing.expect_value(t, rise(away, {.X}, true), rise(away, {.X}, false))
	images := symmetry_images({symmetry = {.X}})
	testing.expect_value(t, symmetry_feather({radius = 0.3, feather = true}, images[:], away), 1)
}

// A row of dabs piles up more the closer they are, about as the inverse of the spacing,
// and a drawn falloff counts as the built-in one does when it is the same shape.
@(test)
dab_overlap_grows_as_dabs_come_closer :: proc(t: ^testing.T) {
	a, b := dab_overlap(nil, 0.25), dab_overlap(nil, 0.125)
	testing.expectf(t, abs(b / a - 2) < 0.02, "overlap %v at 0.25, %v at 0.125", a, b)
	// The built-in falloff's integral across a radius is 16/15.
	testing.expectf(t, abs(a * 0.25 - 16.0 / 15) < 0.01, "overlap %v", a)
	builtin: Falloff
	falloff_set_shaped(&builtin, nil, 0)
	testing.expectf(t, abs(dab_overlap(&builtin, 0.3) - dab_overlap(nil, 0.3)) < 1e-4, "table %v, built in %v", dab_overlap(&builtin, 0.3), dab_overlap(nil, 0.3))
}

// Same side leaves what faces away from the surface pressed: a grab reaching past the
// sphere's middle picks up some of its back half, and with Same side none of it.
@(test)
grab_same_side_leaves_the_far_side :: proc(t: ^testing.T) {
	front := Vec3{0, 0, 1}
	held :: proc(same_side: bool, center: Vec3) -> (count, back: int) {
		sp := sphere_make(3)
		defer sphere_free(sp)
		s := &sp.sculptor
		sculptor_stroke_begin(s)
		count = sculptor_grab_begin(s, {kind = .Grab, radius = 1.6, strength = 1, same_side = same_side}, center)
		for v in s.grab.verts do back += int(sp.mesh.positions[v].z < -0.05)
		sculptor_grab_end(s)
		_ = sculptor_stroke_end(s)
		return
	}
	all, all_back := held(false, front)
	side, side_back := held(true, front)
	testing.expectf(t, all_back > 0 && side_back == 0 && side < all, "all %d (%d behind), same side %d (%d behind)", all, all_back, side, side_back)
}

// Silhouette moves only what faces the way the drag pulls it out: a grab reaching past the
// sphere's middle, dragged out of its front, moves the front and leaves the back half.
@(test)
grab_silhouette_moves_what_faces_the_drag :: proc(t: ^testing.T) {
	sp := sphere_make(3)
	defer sphere_free(sp)
	s := &sp.sculptor
	sculptor_stroke_begin(s)
	_ = sculptor_grab_begin(s, {kind = .Grab, radius = 1.6, strength = 1, silhouette = true}, {0, 0, 1})
	_ = sculptor_grab_move(s, {0, 0, 0.2})
	sculptor_grab_end(s)
	_ = sculptor_stroke_end(s)
	moved_front, moved_back: int
	for p, v in sp.mesh.positions {
		if p == sp.before[v] do continue
		if sp.before[v].z > 0.5 do moved_front += 1
		if sp.before[v].z < -0.05 do moved_back += 1
	}
	testing.expectf(t, moved_front > 0 && moved_back == 0, "front %d, back %d", moved_front, moved_back)
}

// The nearest point to a line passing just off the sphere is on its silhouette, within
// the radius asked; a line further off finds none.
@(test)
nearest_to_line_finds_the_silhouette :: proc(t: ^testing.T) {
	sp := sphere_make(4)
	defer sphere_free(sp)
	p, ok := sculptor_nearest_to_line(&sp.sculptor, {1.05, 0, 3}, {0, 0, -1}, 0.1)
	testing.expectf(t, ok && abs(p.x - 1) < 0.05 && abs(p.z) < 0.15, "%v %v", p, ok)
	_, far := sculptor_nearest_to_line(&sp.sculptor, {1.3, 0, 3}, {0, 0, -1}, 0.1)
	testing.expect(t, !far)
}

// A grab's twist turns what it holds about where it took hold, by each vertex's weight:
// the vertex at the press stays, one near it turns nearly the whole way, and with X
// symmetry the mirror image turns the mirrored way.
@(test)
grab_twist_turns_the_mirrored_way :: proc(t: ^testing.T) {
	sp := sphere_make(5)
	defer sphere_free(sp)
	s := &sp.sculptor
	sculptor_stroke_begin(s)
	center := linalg.normalize(Vec3{0.5, 0, 0.86})
	held := sculptor_grab_begin(s, {kind = .Grab, radius = 0.4, strength = 1, symmetry = {.X}}, center)
	testing.expect(t, held > 0, "grab held nothing")
	_ = sculptor_grab_move(s, {}, {axis = -linalg.normalize(center), angle = math.PI / 4})
	at := nearest(sp.before, center)
	// The vertex nearest the press is a little off it: it moves no further than an eighth
	// of a turn about the press would take it.
	off := linalg.length(sp.before[at] - center)
	testing.expectf(t, linalg.length(sp.mesh.positions[at] - sp.before[at]) <= 0.8 * off + 1e-4, "the vertex %v from the press moved %v", off, sp.mesh.positions[at] - sp.before[at])
	side := nearest(sp.before, linalg.normalize(center + {0, 0.08, 0}))
	mirror := nearest(sp.before, sp.before[side] * Vec3{-1, 1, 1})
	step := sp.mesh.positions[side] - sp.before[side]
	mstep := sp.mesh.positions[mirror] - sp.before[mirror]
	testing.expectf(t, linalg.length(step) > 0.02, "the vertex beside the press moved only %v", step)
	testing.expectf(t, linalg.length(mstep - step * Vec3{-1, 1, 1}) < 1e-3, "the mirror image moved %v for %v", mstep, step)
	for p, i in sp.mesh.positions {
		if linalg.length(sp.before[i] - center) >= 0.4 && linalg.length(sp.before[i] - center * Vec3{-1, 1, 1}) >= 0.4 do testing.expect_value(t, p, sp.before[i])
	}
	sculptor_grab_end(s)
	testing.expect(t, sculptor_stroke_end(s), "the twist was not an undo step")
	testing.expect(t, sculptor_undo(s), "undo failed")
	for p, i in sp.mesh.positions do testing.expect_value(t, p, sp.before[i])
}

// A twisting grab gives the same mesh on worker threads as on one.
@(test)
grab_twist_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(pool: ^jobs.Pool) -> []Vec3 {
		sp := sphere_make(6, pool)
		defer sphere_free(sp)
		s := &sp.sculptor
		sculptor_stroke_begin(s)
		_ = sculptor_grab_begin(s, {kind = .Grab, radius = 0.6, strength = 1, symmetry = {.X}, radial = 3, radial_axis = .Y}, linalg.normalize(Vec3{0.3, 0.2, 1}))
		for k in 1 ..= 3 do _ = sculptor_grab_move(s, {0.02, 0.05, 0} * f32(k), {axis = {0, 0, -1}, angle = 0.3 * f32(k)})
		sculptor_grab_end(s)
		_ = sculptor_stroke_end(s)
		_ = sculptor_flush(s)
		return slice.clone(sp.mesh.positions[:], context.temp_allocator)
	}
	serial, parallel := run(nil), run(&pool)
	testing.expect(t, slice.equal(serial, parallel), "a parallel twist differs from a serial one")
}
