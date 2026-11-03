package sculpt

import "core:math/linalg"
import "core:slice"

// Capture VDM: a stamp made from a sculpted slab, as ZBrush makes a VDM brush from a
// plane. Its upward faces are the stamp's square: each pixel's offset is how far the
// surface over that spot stands from the flat face it started as, out of the face and
// sideways, read from the detail skin where the object has one, whose samples keep where
// they started (their base on the unmoved mesh) and so give overhangs exactly. Vertices
// moved by hand are read by where the surface stands above each spot, which is exact for
// heights and loses only their own sideways moves, so a shape with overhangs belongs in
// the skin (Detail goes to: Skin).

// Pixels a side of a captured stamp unless asked otherwise.
VDM_CAPTURE_SIZE :: 256

// The stamp `s`'s upward faces make, `pixels` a side (2 to ALPHA_MAX_SIZE): the
// square that holds them, its middle the stamp's, its half width a radius; the image's
// up runs toward −z and out of the surface is +y, so it reads as the slab looks from
// above with the front at the bottom. `why` says why there is none.
vdm_capture :: proc(s: ^Sculptor, pixels := VDM_CAPTURE_SIZE, allocator := context.allocator) -> (a: Alpha, why: string) {
	size := clamp(pixels, 2, ALPHA_MAX_SIZE)
	m := s.mesh
	P := m.positions[:]
	I := m.indices[:]
	tris := len(I) / 3
	// Faces that look up, by their own normal, with the corners' heights to find the
	// level the face started at.
	up := make([dynamic]u32, 0, tris / 2, context.temp_allocator)
	heights := make([dynamic]f32, 0, tris / 2, context.temp_allocator)
	lo, hi := Vec3{max(f32), 0, max(f32)}, Vec3{-max(f32), 0, -max(f32)}
	for t in 0 ..< tris {
		p0, p1, p2 := P[I[3 * t]], P[I[3 * t + 1]], P[I[3 * t + 2]]
		n := linalg.cross(p1 - p0, p2 - p0)
		if !(n.y > 0.5 * linalg.length(n)) do continue
		append(&up, u32(t))
		for p in ([3]Vec3{p0, p1, p2}) {
			append(&heights, p.y)
			lo.x, lo.z = min(lo.x, p.x), min(lo.z, p.z)
			hi.x, hi.z = max(hi.x, p.x), max(hi.z, p.z)
		}
	}
	if len(up) == 0 do return {}, "it has no face looking up (+y) to capture from"
	// The level most of the face sits at: the median, so the stamp's own rise does not
	// move it.
	slice.sort(heights[:])
	level := heights[len(heights) / 2]
	mid := (lo + hi) * 0.5
	half := max(hi.x - lo.x, hi.z - lo.z) * 0.5
	if !(half > 0) do return {}, "its upward faces have no width"

	// Each pixel's place on the slab, then the topmost upward face over it.
	last := f32(size - 1)
	Hit :: struct {
		tri:    u32,
		b1, b2: f32,
		y:      f32,
	}
	hits := make([]Hit, size * size, context.temp_allocator)
	for &h in hits do h.tri = max(u32)
	to_pixel :: #force_inline proc(x, mid, half, last: f32) -> f32 {return ((x - mid) / half * 0.5 + 0.5) * last}
	for t in up {
		p0, p1, p2 := P[I[3 * t]], P[I[3 * t + 1]], P[I[3 * t + 2]]
		// x runs with the image's right and z against its up, so row j is at −z.
		i0 := max(int(to_pixel(min(p0.x, p1.x, p2.x), mid.x, half, last)), 0)
		i1 := min(int(to_pixel(max(p0.x, p1.x, p2.x), mid.x, half, last)) + 1, size - 1)
		j0 := max(int(to_pixel(-max(p0.z, p1.z, p2.z), -mid.z, half, last)), 0)
		j1 := min(int(to_pixel(-min(p0.z, p1.z, p2.z), -mid.z, half, last)) + 1, size - 1)
		e1, e2 := [2]f32{p1.x - p0.x, p1.z - p0.z}, [2]f32{p2.x - p0.x, p2.z - p0.z}
		det := e1.x * e2.y - e1.y * e2.x
		if det == 0 do continue
		for j in j0 ..= j1 {
			z := mid.z - (1 - 2 * f32(j) / last) * half
			for i in i0 ..= i1 {
				x := mid.x + (2 * f32(i) / last - 1) * half
				d := [2]f32{x - p0.x, z - p0.z}
				b1 := (d.x * e2.y - d.y * e2.x) / det
				b2 := (e1.x * d.y - e1.y * d.x) / det
				EPS :: -1e-5
				if b1 < EPS || b2 < EPS || 1 - b1 - b2 < EPS do continue
				y := p0.y + (p1.y - p0.y) * b1 + (p2.y - p0.y) * b2
				h := &hits[j * size + i]
				if h.tri == max(u32) || y > h.y do h^ = {t, b1, b2, y}
			}
		}
	}

	vectors := make([][3]f32, size * size, context.temp_allocator)
	for h, k in hits {
		if h.tri == max(u32) do continue
		i, j := k % size, k / size
		rest := Vec3{mid.x + (2 * f32(i) / last - 1) * half, level, mid.z - (1 - 2 * f32(j) / last) * half}
		off := skin_surface_at(s, h.tri, h.b1, h.b2) - rest
		// Into the stamp's frame (x right, y up the image, z out), in radii.
		vectors[k] = Vec3{off.x, -off.z, off.y} / half
	}
	ok: bool
	a, ok = alpha_from_vectors(vectors, size, size, allocator)
	if !ok do return {}, "the capture is empty"
	return a, ""
}
