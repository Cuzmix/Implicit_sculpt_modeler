package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"
import "../uv"

@(private = "file")
source_sphere :: proc(s: ^Sculptor, m: ^geom.Mesh, subdiv: int, pool: ^jobs.Pool) {
	m^ = geom.icosphere(subdiv)
	sculptor_init(s, m, pool, 64)
}

// A sphere with UVs, for texture layers.
@(private = "file")
source_texels :: proc(l: ^Levels) {
	levels_init(l, geom.icosphere(3), nil, 64)
	base := l.levels[0]
	u := uv.make_uvs(len(base.mesh.indices) / 3, l.allocator)
	_ = uv.unwrap(&u, base.mesh.positions[:], base.mesh.indices[:], base.sculptor.faces)
	levels_take_uvs(l, u)
}

// A red spot on the sphere's top, a radius of 0.25 round `at`.
@(private = "file")
red_spot :: proc(s: ^Sculptor, at: Vec3) {
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Paint, radius = 0.25, strength = 1, color = {230, 20, 20}}, at)
	_ = sculptor_stroke_end(s)
}

// The colour and coverage at the vertex nearest `p`.
@(private = "file")
color_near :: proc(s: ^Sculptor, p: Vec3) -> Color {
	best, at := max(f32), 0
	for q, v in s.mesh.positions {
		d := linalg.length2(q - p)
		if d < best do best, at = d, v
	}
	return s.color[at]
}

// Smudge drags the paint under its first dab along the stroke onto bare clay, lays
// nothing on its first dab, and undoes as one step; serial and parallel agree bit for bit.
@(test)
smudge_drags_paint_along_the_stroke :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	result: [2][]Color
	for p, i in ([2]^jobs.Pool{nil, &pool}) {
		m: geom.Mesh
		s: Sculptor
		source_sphere(&s, &m, 5, p)
		start := linalg.normalize(Vec3{-0.3, 0, 1})
		red_spot(&s, start)
		sculptor_stroke_begin(&s)
		first := apply_dab(&s, {kind = .Paint, source = .Smudge, radius = 0.2, strength = 1}, start)
		testing.expect(t, first == 0, "the first dab laid paint")
		for k in 1 ..= 8 {
			at := linalg.normalize(Vec3{-0.3 + 0.06 * f32(k), 0, 1})
			_ = apply_dab(&s, {kind = .Paint, source = .Smudge, radius = 0.2, strength = 1}, at)
		}
		testing.expect(t, sculptor_stroke_end(&s))
		far := color_near(&s, linalg.normalize(Vec3{0.18, 0, 1}))
		testing.expectf(t, far.a > 40 && far.r > far.g, "the smudge's end is %v", far)
		result[i] = slice.clone(s.color, context.temp_allocator)
		testing.expect(t, sculptor_undo(&s))
		testing.expect(t, color_near(&s, linalg.normalize(Vec3{0.18, 0, 1})).a == 0, "undo left the smudge")
		sculptor_destroy(&s)
		geom.mesh_destroy(&m)
	}
	testing.expect(t, slice.equal(result[0], result[1]), "parallel smudging differs from serial")
}

// Clone paints what lies the offset away: a dab at bare clay with the red spot behind its
// offset turns red, and one whose source is bare leaves the clay bare.
@(test)
clone_copies_the_surface_the_offset_away :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	source_sphere(&s, &m, 5, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	src := linalg.normalize(Vec3{-0.4, 0, 1})
	dst := linalg.normalize(Vec3{0.4, 0, 1})
	red_spot(&s, src)
	sculptor_stroke_begin(&s)
	painted := apply_dab(&s, {kind = .Paint, source = .Clone, clone_offset = src - dst, radius = 0.15, strength = 1}, dst)
	_ = sculptor_stroke_end(&s)
	testing.expect(t, painted > 0, "clone painted nothing")
	c := color_near(&s, dst)
	testing.expectf(t, c.a > 200 && c.r > 200 && c.g < 60, "the clone's middle is %v", c)
	// The source bare: nothing to copy.
	other := linalg.normalize(Vec3{0, 0.5, 1})
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Paint, source = .Clone, clone_offset = linalg.normalize(Vec3{0, -0.5, 1}) - other, radius = 0.1, strength = 1}, other)
	_ = sculptor_stroke_end(&s)
	testing.expect(t, color_near(&s, other).a == 0, "a bare source painted")
}

// Stencil lays the picture where each vertex shows through the view, as far as the
// picture's alpha says: a picture blue on its left half and clear on its right paints the
// left of the dab blue and leaves the right bare. Looking down -z, the mesh's x and y are
// the view's.
@(test)
stencil_lays_the_picture_through_the_view :: proc(t: ^testing.T) {
	m: geom.Mesh
	s: Sculptor
	source_sphere(&s, &m, 5, nil)
	defer {sculptor_destroy(&s); geom.mesh_destroy(&m)}
	pixels: [4 * 4 * 4]u8
	blue := [4]u8{10, 30, 240, 255}
	for y in 0 ..< 4 do for x in 0 ..< 2 do copy(pixels[(y * 4 + x) * 4:][:4], blue[:])
	st := Paint_Stencil {
		clip    = 1,
		to_uv   = {{0.5, 0, 0.5}, {0, -0.5, 0.5}},
		pixels  = pixels[:],
		size    = {4, 4},
		opacity = 1,
	}
	sculptor_stroke_begin(&s)
	_ = apply_dab(&s, {kind = .Paint, source = .Stencil, stencil = &st, radius = 0.6, strength = 1}, UP_Z)
	_ = sculptor_stroke_end(&s)
	left := color_near(&s, linalg.normalize(Vec3{-0.3, 0, 1}))
	right := color_near(&s, linalg.normalize(Vec3{0.3, 0, 1}))
	testing.expectf(t, left.a > 100 && left.b > 200 && left.r < 40, "the left is %v", left)
	testing.expectf(t, right.a == 0, "the right is %v", right)
}

@(private = "file")
UP_Z :: Vec3{0, 0, 1}

// On a texture layer, Clone copies the layer's paint the offset away and Smudge drags it,
// colour alone.
@(test)
texel_clone_and_smudge :: proc(t: ^testing.T) {
	l: Levels
	source_texels(&l)
	defer levels_destroy(&l)
	testing.expect(t, levels_texel_layer_add(&l, 512) == 0)
	s := &levels_current(&l).sculptor
	stroke :: proc(l: ^Levels, s: ^Sculptor, brush: Brush, at: ..Vec3) {
		_ = levels_texels_attach(l)
		sculptor_stroke_begin(s)
		for p in at do _ = apply_dab(s, brush, p)
		_ = sculptor_stroke_end(s)
		if step := levels_texels_detach(l); step != nil {
			texel_step_free(step)
			free(step)
		}
	}
	// The layer's colour where the ray down onto `p` meets it.
	at :: proc(l: ^Levels, p: Vec3) -> Color {
		c, _, _ := levels_paint_at(l, p * 2, -p)
		return c
	}
	src := linalg.normalize(Vec3{-0.4, 0, 1})
	dst := linalg.normalize(Vec3{0.4, 0, 1})
	stroke(&l, s, {kind = .Paint, radius = 0.25, strength = 1, color = {230, 20, 20}}, src)
	stroke(&l, s, {kind = .Paint, source = .Clone, clone_offset = src - dst, radius = 0.15, strength = 1}, dst)
	c := at(&l, dst)
	testing.expectf(t, c.a > 200 && c.r > 200 && c.g < 60, "the clone's middle is %v", c)
	side := linalg.normalize(Vec3{0.4, 0.5, 1})
	before := at(&l, side)
	path: [10]Vec3
	for &p, k in path do p = linalg.normalize(Vec3{0.4, 0.06 * f32(k), 1})
	stroke(&l, s, {kind = .Paint, source = .Smudge, radius = 0.2, strength = 1}, ..path[:])
	after := at(&l, side)
	testing.expectf(t, before.a == 0 && after.a > 20, "the smudge reached %v from %v", after, before)
}

// Gradient on a texture layer runs the colour along its axis, as on the vertices: red at
// the bottom of the sphere, blue at its top.
@(test)
texel_gradient_runs_along_its_axis :: proc(t: ^testing.T) {
	l: Levels
	source_texels(&l)
	defer levels_destroy(&l)
	testing.expect(t, levels_texel_layer_add(&l, 512) == 0)
	testing.expect(t, levels_texel_command(&l, .Gradient, {255, 0, 0}, {}, nil, gradient = {to = {0, 0, 255}, axis = {0, 0, 1}}))
	low, _, ok1 := levels_paint_at(&l, {0, 0, -3}, {0, 0, 1})
	high, _, ok2 := levels_paint_at(&l, {0, 0, 3}, {0, 0, -1})
	testing.expect(t, ok1 && ok2)
	testing.expectf(t, low.r > 220 && low.b < 35, "the bottom is %v", low)
	testing.expectf(t, high.b > 220 && high.r < 35, "the top is %v", high)
}
