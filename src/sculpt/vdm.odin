package sculpt

import "core:math"
import "core:math/linalg"

import "../geom"

// Vector displacement stamps (VDM): an alpha that holds a 3D offset per pixel instead of
// a grey value (Alpha.vectors), so one dab can lay down a horn, a lip or a scale with
// overhangs, as ZBrush's, Blender's and Mudbox's VDM brushes do. The offsets are in
// radii in the image's frame: x along its right, y along its up and z out of the surface.
// The Draw brush with a VDM alpha moves each point by its offset laid on the dab's plane
// (Blender's area-plane mapping), turned as the alpha turns (Brush.alpha_up), and times
// the strength; every other brush reads a VDM as the grey alpha of its offsets' lengths.
// A dab goes to the vertices, to the detail skin (heights and its vector page), or is
// split between them by size, as Draw is.

// The built-in stamps: a starter set of shapes heights alone can't make.
Vdm_Shape :: enum u8 {
	Horn,  // a cone that curls toward the image's up
	Ear,   // a raised rim folded in over a hollow
	Scale, // a plate whose lower edge hangs over the surface
	Rivet, // a round dome with a lip
	Lip,   // a ridge across the image that hangs down over its lower side
	Knot,  // a twisted lump
}

VDM_SHAPE_NAMES := [Vdm_Shape]string {
	.Horn  = "Horn",
	.Ear   = "Ear",
	.Scale = "Scale",
	.Rivet = "Rivet",
	.Lip   = "Lip",
	.Knot  = "Knot",
}

// Pixels a side of the built-in stamps: their shapes are smooth, so fewer than the grey
// alphas' do.
VDM_SIZE :: 128

// The offset at (u, v), each from −1 to 1 across the image (v up), between pixels
// linearly; zero outside or for an alpha with no vectors.
alpha_vector_sample :: #force_inline proc(a: ^Alpha, u, v: f32) -> Vec3 {
	if a.vectors == nil || !(abs(u) < 1 && abs(v) < 1) do return {}
	last := f32(a.size - 1)
	x := (u * 0.5 + 0.5) * last
	y := (0.5 - v * 0.5) * last
	x0, y0 := min(int(x), a.size - 2), min(int(y), a.size - 2)
	fx, fy := x - f32(x0), y - f32(y0)
	row := a.vectors[y0 * a.size:]
	below := a.vectors[(y0 + 1) * a.size:]
	top := row[x0] + (row[x0 + 1] - row[x0]) * fx
	bottom := below[x0] + (below[x0 + 1] - below[x0]) * fx
	return top + (bottom - top) * fy
}

// One of the built-in stamps, `size` pixels a side (at least 2).
vdm_make :: proc(shape: Vdm_Shape, size := VDM_SIZE, allocator := context.allocator) -> Alpha {
	a := Alpha{size = max(size, 2)}
	a.vectors = make([][3]f32, a.size * a.size, allocator)
	last := f32(a.size - 1)
	for j in 0 ..< a.size {
		for i in 0 ..< a.size {
			u := 2 * f32(i) / last - 1
			v := 1 - 2 * f32(j) / last
			a.vectors[j * a.size + i] = vdm_shape_at(shape, u, v)
		}
	}
	vdm_grey(&a, allocator)
	return a
}

// The built-in shape's offset at (u, v), in radii.
@(private = "file")
vdm_shape_at :: proc(shape: Vdm_Shape, u, v: f32) -> Vec3 {
	r := math.sqrt(u * u + v * v)
	smooth :: proc(x: f32) -> f32 {
		t := clamp(x, 0, 1)
		return t * t * (3 - 2 * t)
	}
	switch shape {
	case .Horn:
		// Height grows toward the middle; the base draws in toward the axis and the tip
		// curls toward the image's up, past the base, so it overhangs.
		t := smooth(1 - r / 0.75)
		h := 1.6 * math.pow(t, 1.4)
		lean := h / 1.6
		return {-0.55 * t * u, -0.55 * t * v + 0.9 * lean * lean, h}
	case .Ear:
		// A rim round a hollow, folded in over it.
		rim := math.exp(-math.pow((r - 0.55) / 0.13, 2))
		hollow := -0.25 * smooth(1 - r / 0.5)
		inward := Vec3{} if r < 1e-6 else Vec3{-u / r, -v / r, 0} * (0.3 * rim)
		return inward + {0, 0, 0.55 * rim + hollow}
	case .Scale:
		// An oval plate, thickest at its lower edge, which is pushed down over the surface.
		d := math.sqrt(u * u / 0.55 + (v + 0.1) * (v + 0.1) / 0.45)
		t := smooth((1 - d) / 0.25)
		thick := t * (0.25 + 0.2 * clamp(-v, 0, 1))
		return {0, -0.45 * thick, thick}
	case .Rivet:
		dome := 0.32 * math.sqrt(max(0, 1 - (r / 0.45) * (r / 0.45)))
		lip := 0.08 * math.exp(-math.pow((r - 0.52) / 0.06, 2))
		return {0, 0, dome + lip}
	case .Lip:
		// A ridge along the image's right, fading at its ends, hanging over its lower side.
		across := math.exp(-math.pow(v / 0.22, 2))
		along := smooth((0.95 - abs(u)) / 0.3)
		t := across * along
		return {0, -0.35 * t, 0.4 * t}
	case .Knot:
		// A lump whose rings turn about the middle.
		t := smooth(1 - r / 0.8)
		swirl := 0.45 * t * (1 - t) * 2
		return {-v * swirl, u * swirl, 0.7 * t * t}
	}
	return {}
}

// An alpha from a vector image `width` by `height` (`vectors` row by row from the top, in
// radii): padded with zero to a square about its middle, then averaged down to at most
// ALPHA_MAX_SIZE a side. False for an empty image.
alpha_from_vectors :: proc(vectors: [][3]f32, width, height: int, allocator := context.allocator) -> (a: Alpha, ok: bool) {
	if width <= 0 || height <= 0 || len(vectors) < width * height do return {}, false
	side := max(width, height)
	a.size = max(min(side, ALPHA_MAX_SIZE), 2)
	a.vectors = make([][3]f32, a.size * a.size, allocator)
	scale := f32(side) / f32(a.size)
	ox, oy := (side - width) / 2, (side - height) / 2
	for j in 0 ..< a.size {
		y0 := int(f32(j) * scale)
		y1 := max(int(f32(j + 1) * scale), y0 + 1)
		for i in 0 ..< a.size {
			x0 := int(f32(i) * scale)
			x1 := max(int(f32(i + 1) * scale), x0 + 1)
			sum: Vec3
			for y in y0 ..< y1 {
				sy := y - oy
				if sy < 0 || sy >= height do continue
				for x in x0 ..< x1 {
					sx := x - ox
					if sx >= 0 && sx < width do sum += vectors[sy * width + sx]
				}
			}
			a.vectors[j * a.size + i] = sum / f32((y1 - y0) * (x1 - x0))
		}
	}
	vdm_grey(&a, allocator)
	return a, true
}

// Gives a VDM alpha its grey values, each offset's length over the longest, which the
// other brushes, the reach and the thumbnails read.
@(private)
vdm_grey :: proc(a: ^Alpha, allocator := context.allocator) {
	delete(a.values, allocator)
	a.values = make([]f32, len(a.vectors), allocator)
	most: f32
	for v in a.vectors do most = max(most, linalg.length(v))
	if most > 0 do for v, i in a.vectors do a.values[i] = linalg.length(v) / most
	alpha_measure(a)
}

// Whether a dab lays a VDM: the Draw brush with a vector alpha.
@(private)
dab_vdm :: #force_inline proc(d: ^Dab) -> bool {
	return d.brush.kind == .Draw && d.alpha != nil && d.alpha.vectors != nil
}

// How far a VDM dab moves a point `delta` from its centre, in the mesh's space, before
// the mask: the stamp's offset where the point falls on its plane, laid in the dab's frame
// (Dab.au, av, an are over the radius), times the radius and the strength, inverted
// pushing in, and fading as the point lies off the plane as an alpha does.
@(private)
vdm_move :: #force_inline proc(d: ^Dab, delta: Vec3) -> Vec3 {
	off := alpha_vector_sample(d.alpha, linalg.dot(delta, d.au), linalg.dot(delta, d.av))
	if off == {} do return {}
	h := linalg.dot(delta, d.an)
	r := d.brush.radius
	k := r * r * d.brush.strength * falloff(h * h) * (-1 if d.brush.invert else 1)
	return (d.au * off.x + d.av * off.y + d.an * off.z) * k
}

// A VDM dab's vertices: each owned vertex of hit leaf i moves by vdm_move, shielded by the
// mask, HD fade, facing and Connected.
@(private)
job_vdm :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	first, last := owned(s, s.hit[i])
	moved: u32
	bounds := geom.AABB_EMPTY
	for v in first ..< last {
		p := m.positions[v]
		delta := p - d.center
		if linalg.dot(delta, delta) < d.r2 {
			guard := shield(s.fade, s.mask, v) * facing_weight(d, m.normals[:], v)
			if guard > 0 {
				move := vdm_move(d, delta) * guard
				if move != {} {
					p += move
					m.positions[v] = p
					moved += 1
				}
			}
		}
		geom.aabb_grow(&bounds, p)
	}
	s.partials[i].moved = moved
	s.partials[i].bounds = bounds
}
