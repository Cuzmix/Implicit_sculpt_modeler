package uv

import "core:math"

import "../geom"

// Texel density set, not only read (the Surface plan's UV6d), as Blender's Texel Density
// add-on and RizomUV's TD set it: every island is first scaled so a unit of its surface
// takes the same UV length as on every other (Blender's Average Islands Scale), so a
// texture's detail is as fine everywhere; the islands are packed again as large as the
// square holds; and the whole layout is then shrunk about the square's corner to the
// density asked for when that is less. More than the square holds cannot be had in one
// square, and the report says how much it does hold. Islands held by pins keep their
// place and size.

Density_Report :: struct {
	reached: f64, // the density the islands now have, in UV lengths a unit of the surface
	most:    f64, // the most one square holds for these islands, packed
}

// Sets the texel density of `u` (UVs of the triangles `indices` at `positions`) to
// `target` UV lengths a unit of the surface, or as near as one square allows.
// Deterministic: islands are visited in their numbering's order.
set_density :: proc(u: ^Uvs, positions: []geom.Vec3, indices: []u32, target: f64) -> (r: Density_Report) {
	if !has(u^) || u.islands == 0 || target <= 0 do return
	place := movable_islands(u^, indices)
	// Each island's area on the surface and in the square, and its box's middle.
	surface := make([]f64, u.islands, context.temp_allocator)
	texture := make([]f64, u.islands, context.temp_allocator)
	lo := make([][2]f32, u.islands, context.temp_allocator)
	hi := make([][2]f32, u.islands, context.temp_allocator)
	for &l in lo do l = {math.F32_MAX, math.F32_MAX}
	for &h in hi do h = {-math.F32_MAX, -math.F32_MAX}
	for c, t in u.corner {
		i := u.island[t]
		q := surface_frame(positions, indices, u32(t))
		surface[i] += abs(q[1].x * q[2].y) * 0.5
		texture[i] += abs(f64(c[1].x - c[0].x) * f64(c[2].y - c[0].y) - f64(c[2].x - c[0].x) * f64(c[1].y - c[0].y)) * 0.5
		for p in c {
			lo[i] = {min(lo[i].x, p.x), min(lo[i].y, p.y)}
			hi[i] = {max(hi[i].x, p.x), max(hi[i].y, p.y)}
		}
	}
	all_surface, all_texture: f64
	for i in 0 ..< u.islands {
		all_surface += surface[i]
		all_texture += texture[i]
	}
	if all_surface <= 0 || all_texture <= 0 do return
	// One density for all: the layout's own, so the packer starts near the size it ends at.
	even := math.sqrt(all_texture / all_surface)
	grow := make([]f32, u.islands, context.temp_allocator)
	for i in 0 ..< u.islands {
		grow[i] = 1
		if place[i] && surface[i] > 0 && texture[i] > 0 do grow[i] = f32(even / math.sqrt(texture[i] / surface[i]))
	}
	for &c, t in u.corner {
		i := u.island[t]
		if grow[i] == 1 do continue
		mid := (lo[i] + hi[i]) * 0.5
		for &p in c do p = mid + (p - mid) * grow[i]
	}
	pack(u, indices)
	r.most = density_of(u^, positions, indices)
	r.reached = r.most
	if target >= r.most || r.most <= 0 do return
	shrink := f32(target / r.most)
	for &c, t in u.corner do if place[u.island[t]] do for &p in c do p *= shrink
	u.filled = boxes_filled(u^)
	r.reached = density_of(u^, positions, indices)
	return
}

// The layout's texel density over all its triangles, as stretch reads it.
@(private = "file")
density_of :: proc(u: Uvs, positions: []geom.Vec3, indices: []u32) -> f64 {
	surface, texture: f64
	for c, t in u.corner {
		q := surface_frame(positions, indices, u32(t))
		surface += abs(q[1].x * q[2].y) * 0.5
		texture += abs(f64(c[1].x - c[0].x) * f64(c[2].y - c[0].y) - f64(c[2].x - c[0].x) * f64(c[1].y - c[0].y)) * 0.5
	}
	return math.sqrt(texture / surface) if surface > 0 && texture > 0 else 0
}
