package poly

import "core:math"
import "core:math/linalg"

// Ready-made cages, as ZBrush's Initialize and Blender's Add Mesh make them: closed (the
// plane aside), outward facing, quads wherever the shape allows, sized to fit a radius-1
// sphere about the origin with Y up, so a new cage sits where a new sphere would.

Primitive :: enum u8 {
	Cube,
	Plane,
	Cylinder,
	Sphere, // a quad sphere: a subdivided cube pushed onto the sphere
	Torus,
	Cone,
}

@(rodata)
PRIMITIVE_NAMES := [Primitive]string {
	.Cube     = "Cube",
	.Plane    = "Plane",
	.Cylinder = "Cylinder",
	.Sphere   = "Quad sphere",
	.Torus    = "Torus",
	.Cone     = "Cone",
}

// The counts a primitive is made with: `around` and `along` for the round ones, `across`
// for the grid ones; out-of-range values are clamped to PRIMITIVE_MIN..PRIMITIVE_MAX.
Primitive_Options :: struct {
	across: int, // segments along each side of a cube, plane or quad sphere
	around: int, // segments round a cylinder, torus or cone
	along:  int, // segments along a cylinder's axis or round a torus's tube
}

PRIMITIVE_DEFAULTS := Primitive_Options{across = 1, around = 8, along = 1}
// A cage is for blocking out: past a few hundred segments a side the sculpting tools are
// the better way, and a cube of 256 a side is already 393k faces.
PRIMITIVE_MIN :: 1
PRIMITIVE_MAX :: 256

// Builds primitive `kind`. It cannot fail: every shape is made from valid polygons.
primitive :: proc(kind: Primitive, opts := PRIMITIVE_DEFAULTS, allocator := context.allocator) -> Mesh {
	across := clamp(opts.across, PRIMITIVE_MIN, PRIMITIVE_MAX)
	around := clamp(opts.around, 3, PRIMITIVE_MAX)
	along := clamp(opts.along, PRIMITIVE_MIN, PRIMITIVE_MAX)
	p: Builder
	defer builder_destroy(&p)
	switch kind {
	case .Cube:     build_box(&p, across, false)
	case .Sphere:   build_box(&p, max(across, 2), true)
	case .Plane:    build_plane(&p, across)
	case .Cylinder: build_cylinder(&p, around, along)
	case .Torus:    build_torus(&p, around, max(along, 3))
	case .Cone:     build_cone(&p, around)
	}
	m, err := mesh_from_polygons(p.positions[:], p.sizes[:], p.corners[:], nil, allocator)
	assert(err == .None, "a primitive built bad polygons")
	return m
}

@(private = "file")
Builder :: struct {
	positions: [dynamic]Vec3,
	sizes:     [dynamic]int,
	corners:   [dynamic]u32,
	// Lattice points already made, so faces that meet share their vertices.
	at:        map[[3]i32]u32,
}

@(private = "file")
builder_destroy :: proc(p: ^Builder) {
	delete(p.positions)
	delete(p.sizes)
	delete(p.corners)
	delete(p.at)
}

@(private = "file")
point :: proc(p: ^Builder, key: [3]i32, pos: Vec3) -> u32 {
	if v, ok := p.at[key]; ok do return v
	v := u32(len(p.positions))
	append(&p.positions, pos)
	p.at[key] = v
	return v
}

@(private = "file")
polygon :: proc(p: ^Builder, verts: ..u32) {
	append(&p.sizes, len(verts))
	append(&p.corners, ..verts)
}

// A cube of n × n quads a side, or, with `round`, the same pushed onto the sphere with
// the tangent spacing that keeps its quads about the same size.
@(private = "file")
build_box :: proc(p: ^Builder, n: int, round: bool) {
	// Each side: the axis it faces along, its sign, and two axes in its plane whose cross
	// product points out, so the quads run counter-clockwise seen from outside.
	Side :: struct {
		axis, u, w: int,
		sign:       i32,
	}
	SIDES :: [6]Side{{0, 1, 2, 1}, {0, 2, 1, -1}, {1, 2, 0, 1}, {1, 0, 2, -1}, {2, 0, 1, 1}, {2, 1, 0, -1}}
	half := f32(math.sqrt(f32(1) / 3)) // a cube whose corners touch the unit sphere
	for s in SIDES {
		for j in 0 ..< n {
			for i in 0 ..< n {
				quad: [4]u32
				for c, k in ([4][2]int{{i, j}, {i + 1, j}, {i + 1, j + 1}, {i, j + 1}}) {
					key: [3]i32
					key[s.axis] = s.sign * i32(n)
					key[s.u] = i32(2 * c.x - n)
					key[s.w] = i32(2 * c.y - n)
					pos: Vec3
					for a in 0 ..< 3 {
						t := f32(key[a]) / f32(n)
						if round do t = math.tan(t * math.PI / 4)
						pos[a] = t
					}
					quad[k] = point(p, key, linalg.normalize(pos) if round else pos * half)
				}
				polygon(p, ..quad[:])
			}
		}
	}
}

// A square of n × n quads in the XZ plane facing +Y.
@(private = "file")
build_plane :: proc(p: ^Builder, n: int) {
	for j in 0 ..< n {
		for i in 0 ..< n {
			quad: [4]u32
			// Z then X runs counter-clockwise seen from above, as z × x = y.
			for c, k in ([4][2]int{{i, j}, {i + 1, j}, {i + 1, j + 1}, {i, j + 1}}) {
				z := f32(2 * c.x - n) / f32(n)
				x := f32(2 * c.y - n) / f32(n)
				quad[k] = point(p, {i32(c.x), 0, i32(c.y)}, {x, 0, z} * 0.9)
			}
			polygon(p, ..quad[:])
		}
	}
}

@(private = "file")
ring_point :: proc(around, k: int, radius, y: f32) -> Vec3 {
	a := 2 * math.PI * f32(k % around) / f32(around)
	return {radius * math.cos(a), y, -radius * math.sin(a)}
}

// A cylinder round Y: `around` quads round, `along` rows, and one polygon at each end.
@(private = "file")
build_cylinder :: proc(p: ^Builder, around, along: int) {
	r := f32(0.7)
	h := f32(0.7)
	for j in 0 ..< along {
		for k in 0 ..< around {
			y0 := -h + 2 * h * f32(j) / f32(along)
			y1 := -h + 2 * h * f32(j + 1) / f32(along)
			a := point(p, {i32(k % around), i32(j), 0}, ring_point(around, k, r, y0))
			b := point(p, {i32((k + 1) % around), i32(j), 0}, ring_point(around, k + 1, r, y0))
			c := point(p, {i32((k + 1) % around), i32(j + 1), 0}, ring_point(around, k + 1, r, y1))
			d := point(p, {i32(k % around), i32(j + 1), 0}, ring_point(around, k, r, y1))
			polygon(p, a, b, c, d)
		}
	}
	top := make([]u32, around, context.temp_allocator)
	bottom := make([]u32, around, context.temp_allocator)
	for k in 0 ..< around {
		top[k] = p.at[{i32(k), i32(along), 0}]
		bottom[around - 1 - k] = p.at[{i32(k), 0, 0}]
	}
	polygon(p, ..top)
	polygon(p, ..bottom)
}

// A cone round Y: a polygon base and `around` triangles up to the tip.
@(private = "file")
build_cone :: proc(p: ^Builder, around: int) {
	r := f32(0.8)
	h := f32(0.6)
	tip := point(p, {0, 1, 1}, {0, h, 0})
	base := make([]u32, around, context.temp_allocator)
	for k in 0 ..< around do base[k] = point(p, {i32(k), 0, 0}, ring_point(around, k, r, -h))
	for k in 0 ..< around do polygon(p, base[k], base[(k + 1) % around], tip)
	flipped := make([]u32, around, context.temp_allocator)
	for k in 0 ..< around do flipped[k] = base[around - 1 - k]
	polygon(p, ..flipped)
}

// A torus round Y: `around` segments round the ring, `tube` round the tube.
@(private = "file")
build_torus :: proc(p: ^Builder, around, tube: int) {
	big := f32(0.7)
	small := f32(0.28)
	at := proc(around, tube, k, j: int, big, small: f32) -> Vec3 {
		a := 2 * math.PI * f32(k % around) / f32(around)
		b := 2 * math.PI * f32(j % tube) / f32(tube)
		r := big + small * math.cos(b)
		return {r * math.cos(a), small * math.sin(b), -r * math.sin(a)}
	}
	for k in 0 ..< around {
		for j in 0 ..< tube {
			q: [4]u32
			for c, i in ([4][2]int{{k, j}, {k + 1, j}, {k + 1, j + 1}, {k, j + 1}}) {
				q[i] = point(p, {i32(c.x % around), i32(c.y % tube), 0}, at(around, tube, c.x, c.y, big, small))
			}
			// Round the ring, then round the tube, runs counter-clockwise seen from outside.
			polygon(p, ..q[:])
		}
	}
}
