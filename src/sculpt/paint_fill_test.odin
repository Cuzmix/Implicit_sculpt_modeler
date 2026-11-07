package sculpt

import "base:runtime"
import "core:testing"

import "../geom"
import "../jobs"
import "../uv"

// An unwrapped icosphere's levels with one texture layer picked, on `pool` (nil: this
// thread).
@(private = "file")
fill_fixture :: proc(l: ^Levels, pool: ^jobs.Pool) {
	levels_init(l, geom.icosphere(3), pool, 64)
	base := l.levels[0]
	u := uv.make_uvs(len(base.mesh.indices) / 3, l.allocator)
	_ = uv.unwrap(&u, base.mesh.positions[:], base.mesh.indices[:], base.sculptor.faces)
	levels_take_uvs(l, u)
	_ = levels_texel_layer_add(l, 512)
}

// The coverage of every texel the map reaches, summed with the colour channel's, over the
// texels on the surface (the mean coverage, 0 to 1), and the texels whose place on the
// surface is above and below the middle, each with its mean coverage.
@(private = "file")
fill_coverage :: proc(l: ^Levels) -> (mean, upper, lower: f32) {
	layer, _ := levels_texel_picked(l)
	m := &l.texels.tex_map
	n, nu, nl: f32
	for tile, i in m.tiles {
		if tile == nil do continue
		for k in 0 ..< TILE_TEXELS {
			p, ok := levels_texel_position(l, tile, k)
			if !ok do continue
			a := f32(layer.tiles[i].color[k].a) / 255
			mean += a
			n += 1
			if p.y > 0.3 {
				upper += a
				nu += 1
			} else if p.y < -0.3 {
				lower += a
				nl += 1
			}
		}
	}
	return mean / n, upper / nu, lower / nl
}

// A fill layer lays its colour everywhere, or only where its mask says: Facing up on the
// upper half of a sphere, Height more toward the top, a dent's cavity; and an undo of the
// step puts the tiles and the settings back as they were.
@(test)
a_fill_follows_its_mask :: proc(t: ^testing.T) {
	l: Levels
	fill_fixture(&l, nil)
	defer levels_destroy(&l)
	f := PAINT_FILL_DEFAULT
	f.color = {200, 40, 30}
	step := new(Texel_Step)
	testing.expect(t, levels_texel_fill(&l, f, {0, 1, 0}, step))
	mean, _, _ := fill_coverage(&l)
	testing.expectf(t, mean > 0.99, "Everywhere covers %v", mean)
	layer, ok := levels_fill_picked(&l)
	testing.expect(t, ok && layer.fill == f)

	up := f
	up.mask = .Facing_Up
	second := new(Texel_Step)
	testing.expect(t, levels_texel_fill(&l, up, {0, 1, 0}, second))
	_, upper, lower := fill_coverage(&l)
	testing.expectf(t, upper > 0.5 && lower < 0.01, "Facing up: %v above, %v below", upper, lower)

	height := f
	height.mask = .Height
	third := new(Texel_Step)
	testing.expect(t, levels_texel_fill(&l, height, {0, 1, 0}, third))
	_, upper, lower = fill_coverage(&l)
	testing.expectf(t, upper > 0.8 && lower < 0.2, "Height: %v above, %v below", upper, lower)

	// Undone, the Facing up fill comes back, settings and tiles.
	levels_texel_step_swap(&l, third)
	layer, _ = levels_fill_picked(&l)
	testing.expect_value(t, layer.fill.mask, Fill_Mask.Facing_Up)
	_, upper, lower = fill_coverage(&l)
	testing.expect(t, upper > 0.5 && lower < 0.01)
	for s in ([3]^Texel_Step{step, second, third}) {
		texel_step_free(s)
		free(s)
	}
}

// Cavities covers the middle of a bowl pressed into the sphere, Edges far less; Invert
// turns a mask over.
@(test)
a_cavity_fill_finds_a_dent :: proc(t: ^testing.T) {
	l: Levels
	fill_fixture(&l, nil)
	defer levels_destroy(&l)
	// A bowl at the top: the vertices near +Y pulled down, the middle most.
	lv := levels_current(&l)
	for &p in lv.mesh.positions do if p.y > 0.8 {
		u := (p.y - 0.8) / 0.2
		p.y -= 0.3 * u * u
	}
	geom.mesh_recompute_normals(&lv.mesh)
	f := PAINT_FILL_DEFAULT
	f.mask = .Cavities
	measure := fill_cover_at_top(&l, f)
	testing.expectf(t, measure > 0.3, "the bowl's cavity covers %v", measure)
	f.mask = .Edges
	edges := fill_cover_at_top(&l, f)
	testing.expectf(t, edges < measure * 0.5, "edges cover the bowl %v, cavities %v", edges, measure)
	f.mask, f.invert = .Everywhere, true
	testing.expect(t, levels_texel_fill(&l, f, {0, 1, 0}, nil))
	mean, _, _ := fill_coverage(&l)
	testing.expectf(t, mean < 0.01, "Everywhere inverted covers %v", mean)

	fill_cover_at_top :: proc(l: ^Levels, f: Paint_Fill) -> f32 {
		_ = levels_texel_fill(l, f, {0, 1, 0}, nil)
		layer, _ := levels_texel_picked(l)
		m := &l.texels.tex_map
		sum, n: f32
		for tile, i in m.tiles {
			if tile == nil do continue
			for k in 0 ..< TILE_TEXELS {
				p, ok := levels_texel_position(l, tile, k)
				if !ok || p.y < 0 || p.x * p.x + p.z * p.z > 0.15 * 0.15 do continue
				sum += f32(layer.tiles[i].color[k].a) / 255
				n += 1
			}
		}
		return sum / max(n, 1)
	}
}

// A fill comes out the same on any thread count.
@(test)
a_fill_is_the_same_on_any_thread_count :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a, b: Levels
	fill_fixture(&a, nil)
	defer levels_destroy(&a)
	fill_fixture(&b, &pool)
	defer levels_destroy(&b)
	f := PAINT_FILL_DEFAULT
	f.mask, f.low, f.high = .Curvature, 0.1, 0.6
	testing.expect(t, levels_texel_fill(&a, f, {0, 1, 0}, nil))
	testing.expect(t, levels_texel_fill(&b, f, {0, 1, 0}, nil))
	la, _ := levels_texel_picked(&a)
	lb, _ := levels_texel_picked(&b)
	for tile, i in la.tiles {
		if tile == nil {
			testing.expect(t, lb.tiles[i] == nil)
			continue
		}
		testing.expect(t, runtime.memory_compare(raw_data(tile.color), raw_data(lb.tiles[i].color), len(tile.color) * size_of(Color)) == 0)
	}
}

// The levels: under `low` nothing, over `high` full, a smooth rise between; Invert turns it.
@(test)
fill_levels_shape_the_mask :: proc(t: ^testing.T) {
	f := PAINT_FILL_DEFAULT
	f.low, f.high = 0.2, 0.6
	testing.expect_value(t, fill_levels(f, 0.1), 0)
	testing.expect_value(t, fill_levels(f, 0.7), 1)
	testing.expect(t, abs(fill_levels(f, 0.4) - 0.5) < 1e-5)
	f.invert = true
	testing.expect_value(t, fill_levels(f, 0.7), 0)
}

// A fill layer's settings are kept in the file with its tiles, and a painted layer's file
// names none.
@(test)
a_fill_layer_reads_back :: proc(t: ^testing.T) {
	l: Levels
	fill_fixture(&l, nil)
	defer levels_destroy(&l)
	f := PAINT_FILL_DEFAULT
	f.mask, f.color, f.material, f.strength, f.low, f.high, f.invert = .Edges, {10, 200, 30}, {40, 250}, 0.75, 0.1, 0.8, true
	testing.expect(t, levels_texel_fill(&l, f, {0, 1, 0}, nil))
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, levels_write(&l, &out))
	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	layer, ok := levels_fill_picked(&back)
	testing.expect(t, ok && layer.fill == f, "the fill read back")
}
