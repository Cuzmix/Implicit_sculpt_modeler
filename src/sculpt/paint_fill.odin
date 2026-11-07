package sculpt

import "base:runtime"
import "core:math/linalg"

import "../jobs"

// Fill layers (Surface plan PT6 and MK1, after Substance Painter's fill layers with
// generated masks and 3D-Coat's smart materials): a texture layer whose paint is not
// stroked but made, one colour, roughness, metal and height laid over the whole surface
// as far as a mask made from the sculpt itself allows: in its cavities (dirt), on its
// edges and crests (wear), where it bends, where it faces up (dust) or down, up its
// height (a gradient from the ground) or where the sculpt is masked. The mask is measured
// on the current level's vertices, from the same cavity measure Mask cavities and Mask by
// use, and laid into the texture through the texel map, so it is as fine as the sculpt.
//
// A fill layer keeps what it was made from (Texel_Layer.fill), so changing any of it
// makes the layer again, and Update makes it again after sculpting, each one undo step
// whose tiles and settings swap back together (Texel_Step.fill). Making it is never part
// of a stroke: sculpting leaves the layer as it was until Update, so a stroke never waits
// for a texture to be remade. Strokes may paint on it like any texture layer, and making
// it again replaces what they painted.

Fill_Mask :: enum u8 {
	Everywhere,  // the whole surface
	Cavities,    // how far a point sits below its neighbours: grime in creases and pores
	Edges,       // how far it stands above them: wear on crests and ridges
	Curvature,   // how sharply it bends either way
	Facing_Up,   // how far its normal turns up: dust, snow, moss
	Facing_Down, // how far it turns down: soot, drips, shade
	Height,      // how high it is between the lowest and highest point: a gradient from the ground
	Sculpt_Mask, // the sculpt's mask as it is
}

Paint_Fill :: struct {
	mask:     Fill_Mask,
	color:    [3]u8, // sRGB
	material: [2]u8, // roughness, metal
	height:   u16, // as Height_Paint has it, HEIGHT_FLAT for none
	// Cavities, Edges, Curvature: how strongly the shape counts, 0 to 1 (0.5 is Mask
	// cavities' gain, 0 a quarter of it and 1 four times).
	strength: f32,
	// The mask's levels: a measure at or under `low` covers nothing, at or over `high`
	// fully, and between them the coverage rises smoothly.
	low, high: f32,
	invert:   bool, // the mask turned over: covers where it would not
}

// A fill as a new fill layer starts: the whole surface, mid grey's levels.
PAINT_FILL_DEFAULT :: Paint_Fill {
	mask     = .Everywhere,
	color    = {128, 128, 128},
	material = {128, 0},
	height   = HEIGHT_FLAT,
	strength = 0.5,
	low      = 0,
	high     = 1,
}

// Whether two fills make the same layer.
paint_fill_same :: proc(a, b: Paint_Fill) -> bool {return a == b}

// The picked stack row's texture layer when it is a fill layer.
levels_fill_picked :: proc(l: ^Levels) -> (layer: ^Texel_Layer, ok: bool) {
	layer, _ = levels_texel_picked(l)
	return layer, layer != nil && layer.filled
}

// Makes a texture layer of the picked row a fill layer with `fill`, or makes a fill layer
// again with it, as one undo step kept in `step` (its tiles and its settings as they
// were). `up` is the way up in the mesh's own space, which Facing and Height measure
// along. Returns false with nothing changed when the picked row is not a texture layer,
// dynamic topology is on or the texel map cannot be made.
levels_texel_fill :: proc(l: ^Levels, fill: Paint_Fill, up: Vec3, step: ^Texel_Step) -> bool {
	layer, writes := levels_texel_picked(l)
	lv := levels_current(l)
	s := &lv.sculptor
	_ = sculptor_stroke_end(s)
	if layer == nil || s.dyn != nil || !levels_texel_map(l) do return false
	m := &l.texels.tex_map
	// The settings swap with the tiles: the step is the fill as it was.
	if step != nil {
		step.fill, step.filled, step.fill_set = layer.fill, layer.filled, true
		step.layer = layer.id
	}
	layer.fill, layer.filled = fill, true
	touched := make([dynamic]int, 0, len(layer.tiles), context.temp_allocator)
	for tile, i in m.tiles {
		if tile == nil do continue
		texel_step_save(step, layer, i)
		append(&touched, i)
	}
	if len(touched) == 0 do return true
	cover := fill_measure(s, fill, linalg.normalize0(up))

	Job :: struct {
		layer:   ^Texel_Layer,
		m:       ^Texel_Map,
		indices: []u32,
		touched: []int,
		writes:  Paint_Channels,
		fill:    Paint_Fill,
		cover:   []f32,
	}
	job := Job{layer, m, lv.mesh.indices[:], touched[:], writes, fill, cover}
	jobs.parallel_for(l.pool, len(touched), &job, proc(data: rawptr, j: int) {
		job := cast(^Job)data
		i := job.touched[j]
		h := runtime.heap_allocator()
		tile := job.layer.tiles[i]
		if tile == nil {
			tile = new(Texel_Tile, h)
			job.layer.tiles[i] = tile
		}
		if .Color in job.writes && tile.color == nil do tile.color = make([]Color, TILE_TEXELS, h)
		if job.writes & {.Roughness, .Metal} != {} && tile.material == nil do tile.material = make([]Material_Paint, TILE_TEXELS, h)
		if .Height in job.writes && tile.height == nil {
			tile.height = make([]Height_Paint, TILE_TEXELS, h)
			for &v in tile.height do v = {HEIGHT_FLAT, 0}
		}
		f := job.fill
		mt := job.m.tiles[i]
		for k in 0 ..< TILE_TEXELS {
			t := mt.tri[k]
			if t == TEXEL_NONE do continue
			idx := job.indices[3 * t:][:3]
			b := bary_unpack(mt.bary[k])
			c := job.cover[idx[0]] * (1 - b.x - b.y) + job.cover[idx[1]] * b.x + job.cover[idx[2]] * b.y
			a := u8(clamp(c, 0, 1) * 255 + 0.5)
			if .Color in job.writes do tile.color[k] = {f.color.r, f.color.g, f.color.b, a}
			if .Roughness in job.writes do tile.material[k][0], tile.material[k][1] = f.material[0], a
			if .Metal in job.writes do tile.material[k][2], tile.material[k][3] = f.material[1], a
			if .Height in job.writes do tile.height[k] = {f.height, u16(clamp(c, 0, 1) * 65535 + 0.5)}
		}
	})
	for i in touched do texels_touch(&l.texels, u32(i))
	return true
}

// Per vertex of the current level, how far the fill covers it, 0 to 1: the mask's measure
// through its levels, turned over when asked.
@(private = "file")
fill_measure :: proc(s: ^Sculptor, fill: Paint_Fill, up: Vec3) -> []f32 {
	n := len(s.mesh.positions)
	out := make([]f32, n, context.temp_allocator)
	Job :: struct {
		s:      ^Sculptor,
		fill:   Paint_Fill,
		up:     Vec3,
		gain:   f32,
		lo, hi: f32, // Height: the lowest and highest point along `up`
		out:    []f32,
	}
	job := Job{s = s, fill = fill, up = up, out = out}
	job.gain = CAVITY_GAIN * pow4(2 * clamp(fill.strength, 0, 1) - 1)
	if fill.mask == .Height {
		job.lo, job.hi = max(f32), -max(f32)
		for p in s.mesh.positions {
			d := linalg.dot(p, up)
			job.lo, job.hi = min(job.lo, d), max(job.hi, d)
		}
	}
	jobs.parallel_ranges(s.pool, n, &job, proc(data: rawptr, lo, hi: int) {
		job := cast(^Job)data
		s := job.s
		f := job.fill
		for v in lo ..< hi {
			x: f32 = 1
			switch f.mask {
			case .Everywhere:
			case .Cavities, .Edges, .Curvature:
				depth, ok := cavity_depth(s, u32(v))
				if !ok {
					x = 0
					break
				}
				#partial switch f.mask {
				case .Cavities: x = depth * job.gain
				case .Edges:    x = -depth * job.gain
				case:           x = abs(depth) * job.gain
				}
			case .Facing_Up:   x = linalg.dot(s.mesh.normals[v], job.up)
			case .Facing_Down: x = -linalg.dot(s.mesh.normals[v], job.up)
			case .Height:
				x = (linalg.dot(s.mesh.positions[v], job.up) - job.lo) / (job.hi - job.lo) if job.hi > job.lo else 1
			case .Sculpt_Mask:
				x = f32(s.mask[v]) / 255 if s.mask != nil else 0
			}
			job.out[v] = fill_levels(f, x)
		}
	}, 1 << 14)
	return out
}

// 4 raised to `e` (-1 to 1): a quarter to four times.
@(private = "file")
pow4 :: proc(e: f32) -> f32 {
	return linalg.pow(f32(4), e)
}

// The coverage of measure `x` through the fill's levels: nothing at or under `low`, full at
// or over `high`, a smooth rise between, turned over when asked.
fill_levels :: proc(f: Paint_Fill, x: f32) -> f32 {
	lo, hi := clamp(f.low, 0, 1), clamp(f.high, 0, 1)
	c: f32
	if hi <= lo do c = 1 if x >= lo else 0
	else {
		u := clamp((x - lo) / (hi - lo), 0, 1)
		c = u * u * (3 - 2 * u)
	}
	return 1 - c if f.invert else c
}
