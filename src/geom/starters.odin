package geom

import "core:math"
import "core:math/linalg"

import "../jobs"

// Starter base meshes (Primitive.Head and after): blockouts to begin a sculpt from, as
// ZBrush's base meshes and Nomad's starters are, made here from oriented ellipsoids so
// they need no files and carry no licence. The parts overlap; a voxel remesh keeps what
// is inside any of them (one closed surface) and a few relaxing passes round the seams
// where they meet. Each faces +Z with +Y up and, but for the hand, is symmetric across X.

// An ellipsoid: `radii` along its own x, y and z, its z turned to `axis`.
@(private = "file")
Starter_Part :: struct {
	center: Vec3,
	axis:   Vec3,
	radii:  Vec3,
}

@(private = "file")
blob :: proc(parts: ^[dynamic]Starter_Part, center, radii: Vec3, axis := Vec3{0, 0, 1}) {
	append(parts, Starter_Part{center, linalg.normalize(axis), radii})
}

// A limb from `a` to `b`, its radius going from `ra` to `rb`: a row of spheres close
// enough that their union is a smooth tapered tube, round at both ends, so limbs that
// meet at a joint run into each other with no waist.
@(private = "file")
segment :: proc(parts: ^[dynamic]Starter_Part, a, b: Vec3, ra: f32, rb: f32 = -1) {
	rb := rb if rb > 0 else ra
	steps := max(1, int(math.ceil(linalg.length(b - a) / (min(ra, rb) * 0.4))))
	for i in 0 ..= steps {
		f := f32(i) / f32(steps)
		r := ra + (rb - ra) * f
		append(parts, Starter_Part{a + (b - a) * f, {0, 0, 1}, {r, r, r}})
	}
}

// The same part on both sides of the X mirror.
@(private = "file")
pair :: proc(parts: ^[dynamic]Starter_Part, center, radii: Vec3, axis := Vec3{0, 0, 1}) {
	blob(parts, center, radii, axis)
	blob(parts, {-center.x, center.y, center.z}, radii, {-axis.x, axis.y, axis.z})
}

@(private = "file")
segment_pair :: proc(parts: ^[dynamic]Starter_Part, a, b: Vec3, ra: f32, rb: f32 = -1) {
	segment(parts, a, b, ra, rb)
	segment(parts, {-a.x, a.y, a.z}, {-b.x, b.y, b.z}, ra, rb)
}

// A head about two units tall, its middle at the origin.
@(private = "file")
head_parts :: proc(parts: ^[dynamic]Starter_Part, at: Vec3 = {}, s: f32 = 1) {
	p :: proc(parts: ^[dynamic]Starter_Part, at: Vec3, s: f32, c, r: Vec3, axis := Vec3{0, 0, 1}) {blob(parts, at + c * s, r * s, axis)}
	pp :: proc(parts: ^[dynamic]Starter_Part, at: Vec3, s: f32, c, r: Vec3, axis := Vec3{0, 0, 1}) {
		blob(parts, at + c * s, r * s, axis)
		blob(parts, at + Vec3{-c.x, c.y, c.z} * s, r * s, {-axis.x, axis.y, axis.z})
	}
	p(parts, at, s, {0, 0.22, -0.1}, {0.7, 0.74, 0.8}) // cranium
	p(parts, at, s, {0, -0.18, 0.22}, {0.6, 0.78, 0.62}) // face
	p(parts, at, s, {0, -0.6, 0.18}, {0.5, 0.32, 0.56}) // jaw
	p(parts, at, s, {0, -0.72, 0.54}, {0.2, 0.17, 0.18}) // chin
	p(parts, at, s, {0, -0.14, 0.72}, {0.12, 0.11, 0.2}, {0, -0.5, 1}) // nose
	p(parts, at, s, {0, 0.17, 0.62}, {0.13, 0.11, 0.5}, {1, 0, 0}) // brow
	pp(parts, at, s, {0.34, -0.1, 0.42}, {0.2, 0.15, 0.2}) // cheekbones
	pp(parts, at, s, {0.71, -0.06, -0.06}, {0.1, 0.17, 0.27}, {0, 1, 0}) // ears
	p(parts, at, s, {0, -1.0, -0.16}, {0.37, 0.37, 0.5}, {0, 1, 0}) // neck
}

@(private = "file")
starter_parts :: proc(shape: Primitive, parts: ^[dynamic]Starter_Part) {
	#partial switch shape {
	case .Head:
		head_parts(parts)
	case .Bust:
		head_parts(parts, {0, 1.0, 0.05}, 0.55)
		blob(parts, {0, 0.36, -0.03}, {0.22, 0.22, 0.34}, {0, 1, 0}) // neck
		blob(parts, {0, -0.3, -0.02}, {0.42, 0.52, 0.72}, {1, 0, 0}) // chest
		blob(parts, {0, -0.75, -0.02}, {0.36, 0.4, 0.6}, {1, 0, 0}) // ribs
		segment_pair(parts, {0.2, 0.12, -0.06}, {0.76, -0.12, -0.06}, 0.2, 0.23) // shoulders
		pair(parts, {0.3, -0.28, 0.2}, {0.3, 0.2, 0.12}) // chest muscles
		pair(parts, {0.5, 0.02, -0.02}, {0.12, 0.12, 0.42}, {1, -0.35, 0}) // trapezius
	case .Figure:
		blob(parts, {0, 1.76, 0.01}, {0.19, 0.25, 0.22}) // head
		blob(parts, {0, 1.47, -0.01}, {0.085, 0.085, 0.13}, {0, 1, 0}) // neck
		blob(parts, {0, 1.12, 0}, {0.19, 0.3, 0.38}, {1, 0, 0}) // chest
		blob(parts, {0, 0.72, 0.01}, {0.29, 0.25, 0.17}) // belly
		blob(parts, {0, 0.42, -0.01}, {0.19, 0.2, 0.35}, {1, 0, 0}) // pelvis
		pair(parts, {0.39, 1.29, 0}, {0.12, 0.12, 0.12}) // shoulders
		segment_pair(parts, {0.42, 1.27, 0}, {0.6, 0.85, -0.02}, 0.09, 0.07) // upper arms
		segment_pair(parts, {0.6, 0.85, -0.02}, {0.76, 0.45, 0.03}, 0.07, 0.055) // forearms
		pair(parts, {0.81, 0.33, 0.05}, {0.06, 0.09, 0.12}, {0.35, -1, 0.1}) // hands
		segment_pair(parts, {0.17, 0.36, 0}, {0.21, -0.44, 0.02}, 0.15, 0.095) // thighs
		segment_pair(parts, {0.21, -0.44, 0.02}, {0.23, -1.22, -0.02}, 0.1, 0.06) // shins
		pair(parts, {0.24, -1.3, 0.08}, {0.075, 0.06, 0.16}) // feet
	case .Hand:
		blob(parts, {0, 0, 0}, {0.48, 0.5, 0.14}) // palm
		blob(parts, {0, -0.6, -0.01}, {0.33, 0.16, 0.32}, {0, 1, 0}) // wrist
		blob(parts, {0.3, -0.2, 0.05}, {0.2, 0.28, 0.14}) // the thumb's ball
		// Index to little finger: where each starts (inside the palm, so it joins it), how
		// long, which way it points.
		Finger :: struct {
			base:   Vec3,
			length: f32,
			lean:   f32, // radians off straight up, toward the little finger
			r:      f32,
		}
		fingers := [4]Finger {
			{{0.33, 0.3, 0}, 1.0, -0.1, 0.088},
			{{0.11, 0.34, 0}, 1.1, -0.01, 0.092},
			{{-0.11, 0.32, 0}, 1.04, 0.09, 0.088},
			{{-0.32, 0.25, 0}, 0.84, 0.2, 0.075},
		}
		for f in fingers {
			dir := Vec3{-math.sin(f.lean), math.cos(f.lean), 0}
			// Three segments, the nearest longest, each a little thinner and bent forward.
			at := f.base
			lengths := [3]f32{0.4, 0.33, 0.27}
			for share, i in lengths {
				r := f.r * (1 - 0.12 * f32(i))
				d := linalg.normalize(dir + Vec3{0, 0, 0.12 * f32(i)})
				next := at + d * f.length * share
				segment(parts, at, next, r, r * 0.88)
				at = next
			}
		}
		thumb := linalg.normalize(Vec3{0.75, 0.55, 0.3})
		segment(parts, {0.4, -0.12, 0.06}, Vec3{0.4, -0.12, 0.06} + thumb * 0.38, 0.13, 0.11)
		segment(parts, Vec3{0.4, -0.12, 0.06} + thumb * 0.38, Vec3{0.4, -0.12, 0.06} + thumb * 0.38 + linalg.normalize(thumb + {0, 0.35, 0.1}) * 0.32, 0.1, 0.085)
	case .Creature:
		blob(parts, {0, 0.6, 0}, {0.37, 0.4, 0.9}) // body
		blob(parts, {0, 0.66, 0.55}, {0.4, 0.45, 0.45}) // chest
		blob(parts, {0, 0.63, -0.6}, {0.37, 0.4, 0.42}) // hips
		segment(parts, {0, 0.85, 0.8}, {0, 1.25, 1.15}, 0.24, 0.18) // neck
		blob(parts, {0, 1.35, 1.28}, {0.25, 0.25, 0.32}) // head
		blob(parts, {0, 1.24, 1.6}, {0.15, 0.14, 0.22}) // snout
		pair(parts, {0.15, 1.58, 1.2}, {0.08, 0.12, 0.16}, {0.3, 1, -0.2}) // ears
		segment_pair(parts, {0.25, 0.55, 0.6}, {0.27, 0.05, 0.64}, 0.14, 0.1) // front legs
		segment_pair(parts, {0.27, 0.05, 0.64}, {0.27, -0.4, 0.66}, 0.1, 0.075)
		segment_pair(parts, {0.25, 0.55, -0.65}, {0.27, 0.05, -0.76}, 0.17, 0.1) // hind legs
		segment_pair(parts, {0.27, 0.05, -0.76}, {0.27, -0.4, -0.68}, 0.1, 0.075)
		pair(parts, {0.27, -0.44, 0.74}, {0.1, 0.06, 0.13}) // paws
		pair(parts, {0.27, -0.44, -0.6}, {0.1, 0.06, 0.13})
		segment(parts, {0, 0.75, -1.0}, {0, 0.92, -1.42}, 0.12, 0.09) // tail
		segment(parts, {0, 0.92, -1.42}, {0, 0.86, -1.76}, 0.09, 0.07)
		segment(parts, {0, 0.86, -1.76}, {0, 0.7, -2.0}, 0.07, 0.065)
	}
}

// Builds starter `shape` with about `asked` vertices (STARTER_MIN_VERTICES at least):
// its parts as spheres, fused by a voxel remesh, relaxed, then centred and scaled into
// the unit sphere. Normals are left zero for the sculptor to compute.
starter :: proc(shape: Primitive, asked: int, pool: ^jobs.Pool, allocator := context.allocator) -> (m: Mesh, ok: bool) {
	vertices := max(asked, STARTER_MIN_VERTICES)
	parts := make([dynamic]Starter_Part, context.temp_allocator)
	starter_parts(shape, &parts)
	if len(parts) == 0 do return {}, false
	// The thinnest part sets the lattice: a part only a few steps across can break up or
	// fuse with its neighbour, so the first pass keeps six across it whatever the count.
	thinnest := max(f32)
	for part in parts do thinnest = min(thinnest, part.radii.x, part.radii.y, part.radii.z)
	// Each part a sphere whose facets are well under that step: a fine one for the big
	// parts and a coarser one for the many small spheres that make the limbs.
	fine := geodesic_sphere(24, nil, context.temp_allocator)
	coarse := geodesic_sphere(12, nil, context.temp_allocator)
	all: Mesh
	all.positions = make([dynamic]Vec3, 0, len(parts) * len(fine.positions), context.temp_allocator)
	all.indices = make([dynamic]u32, 0, len(parts) * len(fine.indices), context.temp_allocator)
	for part in parts {
		sphere := &fine if max(part.radii.x, part.radii.y, part.radii.z) > 3 * thinnest else &coarse
		z := part.axis
		x := linalg.cross(Vec3{0, 1, 0}, z)
		x = linalg.normalize(x) if linalg.length(x) > 1e-4 else Vec3{1, 0, 0}
		y := linalg.cross(z, x)
		first := u32(len(all.positions))
		for p in sphere.positions {
			q := p * part.radii
			append(&all.positions, part.center + x * q.x + y * q.y + z * q.z)
		}
		for i in sphere.indices do append(&all.indices, first + i)
	}
	fused := remesh_voxel_spacing(all, thinnest / 3, pool, context.temp_allocator) or_return
	starter_relax(&fused, STARTER_RELAX_PASSES, pool)
	// The fused surface, relaxed, is remeshed again at the count (never so coarse that the
	// thinnest part is under four steps across), then relaxed a little to take the second
	// remesh's own seams off.
	step := min(remesh_spacing(fused, vertices, pool), thinnest / 2)
	m = remesh_voxel_spacing(fused, step, pool, allocator) or_return
	starter_relax(&m, 6, pool)
	// The sculptor works the normals out itself; the remesh's are stale after relaxing.
	for &n in m.normals do n = {}
	// Into the unit sphere, about its bounds' middle, as the other shapes are.
	bounds := AABB_EMPTY
	for p in m.positions do aabb_grow(&bounds, p)
	middle := (bounds.lo + bounds.hi) * 0.5
	reach: f32 = 0
	for p in m.positions do reach = max(reach, linalg.length(p - middle))
	for &p in m.positions do p = (p - middle) * (0.98 / reach)
	return m, true
}

// Whether `shape` is a starter: a blockout to sculpt from, not a plain primitive.
is_starter :: proc(shape: Primitive) -> bool {return shape >= .Head && shape <= .Creature}

// Fewer vertices than this and the thinnest parts (fingers, a tail) fall apart on the
// remesh's lattice, so a starter is never built smaller.
STARTER_MIN_VERTICES :: 15_000

// Taubin passes (shrink by λ, grow back by μ) round the seams without shrinking the
// shape: enough to soften where parts meet at a base mesh's density.
STARTER_RELAX_PASSES :: 16

// Moves each vertex toward the average of its triangles' other corners, then back out,
// `passes` times. Each step reads one buffer and writes another, so threads never see
// each other's writes and the result is the same however the work is split.
@(private = "file")
starter_relax :: proc(m: ^Mesh, passes: int, pool: ^jobs.Pool) {
	Relax :: struct {
		vf:       Vertex_Faces,
		indices:  []u32,
		from, to: []Vec3,
		weight:   f32,
	}
	vf := vertex_faces_build(m^, pool, context.temp_allocator)
	spare := make([]Vec3, len(m.positions), context.temp_allocator)
	r := Relax{vf = vf, indices = m.indices[:]}
	for _ in 0 ..< passes {
		for weight in ([2]f32{0.5, -0.53}) {
			r.from, r.to, r.weight = m.positions[:], spare, weight
			jobs.parallel_ranges(pool, len(m.positions), &r, proc(data: rawptr, lo, hi: int) {
				r := cast(^Relax)data
				for v in lo ..< hi {
					sum: Vec3
					n := 0
					for tri in vertex_faces_of(r.vf, u32(v)) {
						for c in 0 ..< 3 {
							w := r.indices[tri * 3 + u32(c)]
							if w == u32(v) do continue
							sum += r.from[w]
							n += 1
						}
					}
					p := r.from[v]
					r.to[v] = p + (sum / f32(n) - p) * r.weight if n > 0 else p
				}
			}, RANGE_GRAIN)
			copy(m.positions[:], spare)
		}
	}
}
