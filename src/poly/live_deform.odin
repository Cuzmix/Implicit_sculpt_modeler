package poly

import "core:math"
import "core:math/linalg"

// The live stack's deformers. Deform, after the shell and bevel, bends, twists or tapers
// the whole along an axis (ZBrush's Gizmo deformers Bend Arc, Twist and Taper, Blender's
// Simple Deform). Displace pushes every point along its normal by a smooth noise
// (Blender's Displace with a Clouds texture), for rock, bark or hammered metal; the app
// runs it on the finest drawn surface, after Smooth, since on the cage's few points it
// would only shift corners. Both only move points, so the meshes keep their topology and
// the cage's maps onto them, and a change of amount moves points without making the level
// again.

Deform_Kind :: enum u8 {
	Off,
	Bend,
	Twist,
	Taper,
}

// The most Bend and Twist turn, in radians (two whole turns), and Taper's widest factor.
LIVE_DEFORM_TURN_MAX :: 4 * math.PI
LIVE_TAPER_MAX :: 1

// Moves `m`'s points by the deformer `kind` along `axis`, over the span lo to hi that the
// cage covers along it, so the same amount does the same to a small cage and a large one.
// Bend curls the axis into an arc of `amount` radians, round the axis after the next,
// toward the next, the middle of the span staying put; Twist turns each slice round the
// axis (through the origin) by up to `amount` radians at the span's ends, the middle
// still; Taper scales each slice square to the axis by 1 at the span's low end to
// 1 + `amount` at its high end.
live_deform :: proc(m: ^Mesh, kind: Deform_Kind, axis: Mirror_Axis, amount: f32, lo, hi: Vec3) {
	a := int(axis)
	c := (a + 1) % 3 // the way Bend curls toward
	b := (a + 2) % 3 // the axis Bend curls round
	length := hi[a] - lo[a]
	if kind == .Off || length <= 1e-12 || abs(amount) <= 1e-6 do return
	mid := (lo[a] + hi[a]) / 2
	for &p in m.positions {
		s := p[a] - mid
		switch kind {
		case .Off:
		case .Bend:
			// The axis becomes an arc of radius length / amount, centred off the axis
			// toward c, so a point's distance across it (along c) shortens or lengthens
			// its radius as a bent bar's inside and outside do.
			r := length / amount
			t := s / r
			d := r - p[c]
			p[a] = mid + d * math.sin(t)
			p[c] = r - d * math.cos(t)
		case .Twist:
			t := amount * s / length
			sn, cs := math.sin(t), math.cos(t)
			u, v := p[c], p[b]
			p[c], p[b] = u * cs - v * sn, u * sn + v * cs
		case .Taper:
			f := 1 + amount * (p[a] - lo[a]) / length
			p[c] *= f
			p[b] *= f
		}
	}
}

// Pushes each of `m`'s points along its normal by `strength` times a smooth noise of its
// place `scale` across a feature, the same everywhere for the same place, so mirror
// images and a cage moved and moved back come out alike.
live_displace :: proc(m: ^Mesh, strength, scale: f32) {
	if strength == 0 || scale <= 1e-9 do return
	normals := make([]Vec3, len(m.positions), context.temp_allocator)
	for v in 0 ..< u32(len(m.positions)) do normals[v] = vert_normal(m, v)
	for &p, v in m.positions do p = live_displace_at(p, normals[v], strength, scale)
}

// Where Displace puts a point at `p` with unit normal `n`: two octaves of noise, the
// second half as strong at twice the detail. Apply to sculpt bakes it with this too.
live_displace_at :: proc(p, n: Vec3, strength, scale: f32) -> Vec3 {
	if strength == 0 || scale <= 1e-9 do return p
	q := p / scale
	x := live_noise(q) + 0.5 * live_noise(q * 2 + 17.3)
	return p + n * (strength * x / 1.5)
}

// Smooth value noise in -1 to 1: a hashed value at each whole point, blended with a
// quintic step across each cell.
live_noise :: proc(p: Vec3) -> f32 {
	cell := linalg.floor(p)
	f := p - cell
	u := f * f * f * (f * (f * 6 - 15) + 10)
	ix, iy, iz := i32(cell.x), i32(cell.y), i32(cell.z)
	value :: proc(x, y, z: i32) -> f32 {
		h := u32(x) * 0x8da6b343 ~ u32(y) * 0xd8163841 ~ u32(z) * 0xcb1ab31f
		h = (h ~ (h >> 15)) * 0x2c1b3c6d
		h = (h ~ (h >> 12)) * 0x297a2d39
		h ~= h >> 15
		return f32(h) / f32(max(u32)) * 2 - 1
	}
	x0 := math.lerp(value(ix, iy, iz), value(ix + 1, iy, iz), u.x)
	x1 := math.lerp(value(ix, iy + 1, iz), value(ix + 1, iy + 1, iz), u.x)
	x2 := math.lerp(value(ix, iy, iz + 1), value(ix + 1, iy, iz + 1), u.x)
	x3 := math.lerp(value(ix, iy + 1, iz + 1), value(ix + 1, iy + 1, iz + 1), u.x)
	return math.lerp(math.lerp(x0, x1, u.y), math.lerp(x2, x3, u.y), u.z)
}
