package sculpt

import "core:log"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

import "../geom"
import "../jobs"
import "../uv"

// An unwrapped icosphere's levels, on `pool` (nil: this thread).
@(private = "file")
texel_fixture :: proc(l: ^Levels, pool: ^jobs.Pool) {
	levels_init(l, geom.icosphere(2), pool, 64)
	base := l.levels[0]
	u := uv.make_uvs(len(base.mesh.indices) / 3, l.allocator)
	_ = uv.unwrap(&u, base.mesh.positions[:], base.mesh.indices[:], base.sculptor.faces)
	levels_take_uvs(l, u)
}

// The texel map puts each texel on the triangle its centre lies in: read back through its
// barycentric place, a texel inside an island lands within a texel of its own centre, and
// about as many texels are covered as the islands' area says (more, by the gutter).
@(test)
texel_map_places_each_texel :: proc(t: ^testing.T) {
	l: Levels
	texel_fixture(&l, nil)
	defer levels_destroy(&l)
	testing.expect(t, levels_texel_layer_add(&l, 512) == 0)
	testing.expect(t, levels_texel_map(&l))
	m := &l.texels.tex_map
	area: f32
	for c in l.uvs.corner {
		area += abs((c[1].x - c[0].x) * (c[2].y - c[0].y) - (c[2].x - c[0].x) * (c[1].y - c[0].y)) / 2
	}
	covered, inside := 0, 0
	across := texel_tiles_across(512)
	for tile, i in m.tiles {
		if tile == nil do continue
		for k in 0 ..< TILE_TEXELS {
			tri := tile.tri[k]
			if tri == TEXEL_NONE do continue
			covered += 1
			c := l.uvs.corner[tri]
			b := [2]f32{f32(tile.bary[k].x), f32(tile.bary[k].y)} / 65535
			p := c[0] * (1 - b.x - b.y) + c[1] * b.x + c[2] * b.y
			x := f32((i % across) * TEXEL_TILE + k % TEXEL_TILE) + 0.5
			y := f32((i / across) * TEXEL_TILE + k / TEXEL_TILE) + 0.5
			d := [2]f32{p.x * 512 - x, (1 - p.y) * 512 - y}
			if d.x * d.x + d.y * d.y < 0.01 do inside += 1
		}
	}
	expected := int(area * 512 * 512)
	testing.expectf(t, inside >= expected * 97 / 100, "%d texels on their own triangle for an area of %d", inside, expected)
	testing.expectf(t, covered > inside, "no gutter: %d covered, %d inside", covered, inside)
	// A texel's place on the surface lies on the sphere (its triangles' chords).
	for tile in m.tiles {
		if tile == nil do continue
		for k in 0 ..< TILE_TEXELS {
			p, ok := levels_texel_position(&l, tile, k)
			if !ok do continue
			r := linalg.length(p)
			testing.expectf(t, r > 0.9 && r < 1.001, "a texel lies %v from the middle", r)
			return
		}
	}
}

// The map, Fill and the composite come out the same on any thread count.
@(test)
texels_serial_and_parallel_agree :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool) -> (tri: []u32, shown: []Color) {
		l: Levels
		texel_fixture(&l, pool)
		defer levels_destroy(&l)
		testing.expect(t, levels_texel_layer_add(&l, 512) >= 0)
		testing.expect(t, levels_texel_command(&l, .Fill, {200, 40, 10}, {}, nil))
		s := &levels_current(&l).sculptor
		_ = sculptor_paint_set(s, sculptor_paint_picked(s), true, 0.6)
		_ = sculptor_stroke_end(s)
		levels_texels_flush(&l)
		for m, i in l.texels.tex_map.tiles {
			if m == nil do continue
			tri = slice.concatenate([][]u32{tri, m.tri}, context.temp_allocator)
			if sh := l.texels.shown[i]; sh != nil do shown = slice.concatenate([][]Color{shown, sh.color}, context.temp_allocator)
		}
		return
	}
	a_tri, a_shown := run(t, nil)
	b_tri, b_shown := run(t, &pool)
	testing.expect(t, len(a_tri) > 0 && slice.equal(a_tri, b_tri), "the maps differ")
	testing.expect(t, len(a_shown) > 0 && slice.equal(a_shown, b_shown), "the composites differ")
}

// Fill paints every texel on the surface, the composite shows it premultiplied by the
// layer's opacity, and its undo step puts the tiles back bit for bit both ways.
@(test)
texel_fill_composites_and_undoes :: proc(t: ^testing.T) {
	l: Levels
	texel_fixture(&l, nil)
	defer levels_destroy(&l)
	testing.expect(t, levels_texel_layer_add(&l, 512) >= 0)
	step: Texel_Step
	defer texel_step_free(&step)
	testing.expect(t, levels_texel_command(&l, .Fill, {255, 0, 0}, {64, 255}, &step))
	layer, _ := levels_texel_picked(&l)
	painted := 0
	for tile in layer.tiles do if tile != nil do painted += 1
	testing.expect(t, painted > 0 && len(step.saved) == painted)
	levels_texels_flush(&l)
	testing.expect(t, levels_texels_show(&l))
	changed, all := levels_texels_take(&l)
	testing.expect(t, all && len(changed) > 0)
	for tile, i in l.texels.shown {
		if tile == nil do continue
		m := l.texels.tex_map.tiles[i]
		for k in 0 ..< TILE_TEXELS {
			want := Color{255, 0, 0, 255} if m.tri[k] != TEXEL_NONE else {}
			if tile.color[k] != want {
				testing.expectf(t, false, "tile %d texel %d shows %v", i, k, tile.color[k])
				return
			}
		}
	}
	// Roughness and metal were not the layer's channels, so nothing of them was made.
	for tile in layer.tiles do testing.expect(t, tile == nil || tile.material == nil)
	before := make([][]Color, len(layer.tiles), context.temp_allocator)
	for tile, i in layer.tiles do if tile != nil do before[i] = slice.clone(tile.color, context.temp_allocator)
	levels_texel_step_swap(&l, &step)
	for tile in layer.tiles do testing.expect(t, tile == nil, "undo left paint")
	levels_texels_flush(&l)
	testing.expect(t, !levels_texels_show(&l))
	levels_texel_step_swap(&l, &step)
	for tile, i in layer.tiles {
		if (tile == nil) != (before[i] == nil) || (tile != nil && !slice.equal(tile.color, before[i])) {
			testing.expectf(t, false, "redo changed tile %d", i)
			return
		}
	}
}

// A picked texture layer takes no paint on its vertices: the vertex Fill and dabs refuse,
// so no colours per vertex are made for it, and a vertex layer added after goes under it.
@(test)
texture_layer_refuses_vertex_paint :: proc(t: ^testing.T) {
	l: Levels
	texel_fixture(&l, nil)
	defer levels_destroy(&l)
	s := &levels_current(&l).sculptor
	testing.expect(t, levels_texel_layer_add(&l, 512) == 0)
	testing.expect(t, sculptor_paint_on_texture(s))
	testing.expect(t, !sculptor_paint_command(s, .Fill, {10, 20, 30}))
	testing.expect(t, s.color == nil && s.paint.list[0].color == nil)
	testing.expect(t, sculptor_paint_add(s) == 0, "a vertex layer went over the texture layer")
	testing.expect(t, s.paint.list[1].texels != 0)
	testing.expect(t, !sculptor_paint_move(s, 0), "a vertex layer moved over a texture layer")
	testing.expect(t, !sculptor_paint_merge_down(s, 1), "a texture layer merged into a vertex layer")
	// A different size for a second texture layer is refused: they share one.
	testing.expect(t, levels_texel_layer_add(&l, 1024) == -1)
	testing.expect(t, levels_texel_layer_add(&l, 512) == 1, "the new texture layer is not just above the vertex layers")
}

// Texture layers come back from the scene file tile for tile, the stack's rows naming them;
// one taken out stays while its undo step could put it back.
@(test)
texels_round_trip_and_sweep :: proc(t: ^testing.T) {
	l: Levels
	texel_fixture(&l, nil)
	defer levels_destroy(&l)
	testing.expect(t, levels_texel_layer_add(&l, 512) == 0)
	testing.expect(t, levels_texel_command(&l, .Fill, {1, 2, 3}, {}, nil))
	s := &levels_current(&l).sculptor
	testing.expect(t, sculptor_paint_set_channels(s, 0, {.Metal}))
	testing.expect(t, levels_texel_command(&l, .Fill, {}, {0, 200}, nil))
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))
	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	b := &levels_current(&back).sculptor
	testing.expect(t, len(b.paint.list) == 1 && b.paint.list[0].texels != 0)
	a_layer := texels_layer(&l.texels, s.paint.list[0].texels)
	b_layer := texels_layer(&back.texels, b.paint.list[0].texels)
	testing.expect(t, b_layer != nil && back.texels.side == 512)
	if b_layer == nil do return
	for tile, i in a_layer.tiles {
		other := b_layer.tiles[i]
		same := (tile == nil) == (other == nil)
		if same && tile != nil do same = slice.equal(tile.color, other.color) && slice.equal(tile.material, other.material)
		if !same {
			testing.expectf(t, false, "tile %d differs after reading", i)
			return
		}
	}
	testing.expect(t, sculptor_paint_remove(s, 0))
	levels_texels_sweep(&l)
	testing.expect(t, len(l.texels.layers) == 1, "a layer its undo step holds was freed")
	_ = sculptor_undo(s)
	testing.expect(t, len(s.paint.list) == 1 && texels_layer(&l.texels, s.paint.list[0].texels) != nil)
}

// A Paint stroke on a picked texture layer paints its tiles and not the vertices, keeps the
// tiles it changed (as they were) in its undo step, and comes out the same on any thread
// count; swapping the step back leaves the layer unpainted.
@(test)
texel_stroke_paints_tiles :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool) -> (painted: []Color) {
		l: Levels
		texel_fixture(&l, pool)
		defer levels_destroy(&l)
		testing.expect(t, levels_texel_layer_add(&l, 1024) == 0)
		s := &levels_current(&l).sculptor
		testing.expect(t, levels_texels_attach(&l))
		sculptor_stroke_begin(s)
		start := time.tick_now()
		for k in 0 ..< 8 {
			at := linalg.normalize(Vec3{0.1 * f32(k), 0.2, 1})
			_ = apply_dab(s, {kind = .Paint, radius = 0.3, strength = 0.8, color = {20, 200, 90}}, at)
		}
		took := time.duration_milliseconds(time.tick_since(start))
		_ = sculptor_stroke_end(s)
		step := levels_texels_detach(&l)
		testing.expect(t, step != nil && len(step.saved) > 0, "the stroke kept no tiles")
		testing.expect(t, s.color == nil && s.paint.list[0].color == nil, "the stroke painted the vertices")
		layer := texels_layer(&l.texels, s.paint.list[0].texels)
		count := 0
		for tile in layer.tiles {
			if tile == nil do continue
			for c in tile.color do if c.a > 0 do count += 1
			painted = slice.concatenate([][]Color{painted, tile.color}, context.temp_allocator)
		}
		testing.expectf(t, count > 1000, "%d texels painted", count)
		log.infof("8 dabs at 1024 texels: %.2f ms, %d texels painted", took, count)
		if step == nil do return
		levels_texel_step_swap(&l, step)
		for tile in layer.tiles do testing.expect(t, tile == nil, "undo left paint")
		texel_step_free(step)
		free(step)
		return
	}
	a := run(t, nil)
	b := run(t, &pool)
	testing.expect(t, len(a) > 0 && slice.equal(a, b), "serial and parallel strokes differ")
}

// Blur over a painted line's edge spreads its paint thinly onto the clay beside it and
// softens it inside, the same on one thread as on three, and undoes as one step.
@(test)
texel_blur_softens_and_agrees :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	run :: proc(t: ^testing.T, pool: ^jobs.Pool) -> (painted: []Color) {
		l: Levels
		texel_fixture(&l, pool)
		defer levels_destroy(&l)
		testing.expect(t, levels_texel_layer_add(&l, 512) == 0)
		s := &levels_current(&l).sculptor
		at := linalg.normalize(Vec3{0.1, 0.2, 1})
		stroke :: proc(l: ^Levels, s: ^Sculptor, brush: Brush, at: Vec3, dabs: int) -> ^Texel_Step {
			_ = levels_texels_attach(l)
			sculptor_stroke_begin(s)
			for _ in 0 ..< dabs do _ = apply_dab(s, brush, at)
			_ = sculptor_stroke_end(s)
			return levels_texels_detach(l)
		}
		counts :: proc(layer: ^Texel_Layer) -> (covered, partial: int) {
			for tile in layer.tiles {
				if tile == nil || tile.color == nil do continue
				for c in tile.color {
					if c.a > 0 do covered += 1
					if c.a > 0 && c.a < 250 do partial += 1
				}
			}
			return
		}
		first := stroke(&l, s, {kind = .Paint, radius = 0.1, strength = 1, color = {250, 30, 30}}, at, 1)
		defer if first != nil {texel_step_free(first); free(first)}
		layer := texels_layer(&l.texels, s.paint.list[0].texels)
		covered, partial := counts(layer)
		blurred := stroke(&l, s, {kind = .Paint, radius = 0.25, strength = 1, blur = true}, at, 6)
		testing.expect(t, blurred != nil, "blur changed no tile")
		covered2, partial2 := counts(layer)
		testing.expectf(t, covered2 > covered && partial2 > partial, "covered %d -> %d, partial %d -> %d", covered, covered2, partial, partial2)
		for tile in layer.tiles do if tile != nil && tile.color != nil do painted = slice.concatenate([][]Color{painted, tile.color}, context.temp_allocator)
		if blurred == nil do return
		levels_texel_step_swap(&l, blurred)
		covered3, _ := counts(layer)
		testing.expect(t, covered3 == covered, "undo left the blur")
		texel_step_free(blurred)
		free(blurred)
		return
	}
	a := run(t, nil)
	b := run(t, &pool)
	testing.expect(t, len(a) > 0 && slice.equal(a, b), "serial and parallel blurs differ")
}
