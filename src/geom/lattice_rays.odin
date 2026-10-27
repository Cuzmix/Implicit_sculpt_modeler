package geom

import "base:runtime"
import "core:math"
import "core:slice"
import "core:sync"

import "../jobs"

// Lattice rays: on a lattice of spacing h placed at an origin, a ray along one axis w through
// every lattice point (u, v) of the two other axes, with every crossing of the mesh along it
// and the winding number just past each crossing. The crossings are found with exact
// fixed-point edge tests and a top-left rule, so a ray through a shared edge or vertex
// counts it once and a closed mesh gives exact answers. The voxel remesh (remesh.odin)
// decides inside and outside and places its vertices from them; the voxel package builds a
// signed distance field from them (voxelize.odin).

LATTICE_FIX :: 1 << 16 // fixed-point steps per lattice step

Lattice_Hit :: struct {
	w:    f32, // where along the ray, in lattice steps from the origin
	wind: i32, // the winding number just past this crossing (summed along the ray)
}

// The rays along one axis, indexed u + nu * v, where u and v are the next two axes after w
// (so u, v, w is right-handed); ray r's crossings are hits[first[r]:first[r + 1]], sorted
// along the ray.
Lattice_Rays :: struct {
	nu, nv:    int,
	first:     []u32,
	hits:      []Lattice_Hit,
	allocator: runtime.Allocator,
}

// The mesh's vertices in lattice steps from `origin`, in fixed point, as the casts read
// them: computed once for the three axes.
lattice_quantize :: proc(m: Mesh, origin: Vec3, h: f32, pool: ^jobs.Pool, allocator := context.allocator) -> [][3]i32 {
	Quantize :: struct {
		m:      Mesh,
		origin: Vec3,
		h:      f32,
		q:      [][3]i32,
	}
	x := Quantize{m, origin, h, make([][3]i32, len(m.positions), allocator)}
	jobs.parallel_ranges(pool, len(m.positions), &x, proc(data: rawptr, lo, hi: int) {
		x := cast(^Quantize)data
		for v in lo ..< hi {
			l := (x.m.positions[v] - x.origin) / x.h
			x.q[v] = {i32(math.round(l.x * LATTICE_FIX)), i32(math.round(l.y * LATTICE_FIX)), i32(math.round(l.z * LATTICE_FIX))}
		}
	}, RANGE_GRAIN)
	return x.q
}

// What the casting jobs share: the mesh, its quantized vertices and the lattice.
@(private = "file")
Lattice_Caster :: struct {
	m:      Mesh,
	q:      [][3]i32,
	origin: Vec3,
	h:      f32,
	axis:   int,
	split:  int, // triangles from here on count `weight` times in the winding number
	weight: i32,
	rays:   ^Lattice_Rays,
	cursor: []u32, // scratch while filling: the next free hit of each ray
}

// Every crossing of `m` with the lattice's rays along `axis`, on the lattice of `n` points
// per axis from `origin` at spacing `h`; `q` is lattice_quantize of the same placement. A
// triangle facing −w is entered along +w and raises the winding number; triangles from
// `split` on count `weight` times (the remesh's booleans keep two meshes apart in one sum).
lattice_rays_cast :: proc(m: Mesh, q: [][3]i32, origin: Vec3, h: f32, n: [3]int, axis: int, split: int, weight: i32, pool: ^jobs.Pool, allocator := context.allocator) -> (rays: Lattice_Rays) {
	rays.allocator = allocator
	rays.nu, rays.nv = n[(axis + 1) % 3], n[(axis + 2) % 3]
	rays.first = make([]u32, rays.nu * rays.nv + 1, allocator)
	c := Lattice_Caster{m = m, q = q, origin = origin, h = h, axis = axis, split = split, weight = weight, rays = &rays}
	tris := len(m.indices) / 3
	jobs.parallel_ranges(pool, tris, &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Lattice_Caster)data
		for t in lo ..< hi do triangle_hits(c, t, false)
	}, 1 << 14)
	for i in 1 ..< len(rays.first) do rays.first[i] += rays.first[i - 1]
	rays.hits = make([]Lattice_Hit, rays.first[len(rays.first) - 1], allocator)
	c.cursor = slice.clone(rays.first, context.temp_allocator)
	jobs.parallel_ranges(pool, tris, &c, proc(data: rawptr, lo, hi: int) {
		c := cast(^Lattice_Caster)data
		for t in lo ..< hi do triangle_hits(c, t, true)
	}, 1 << 14)
	// Sort each ray's crossings along it, then sum the winding.
	jobs.parallel_ranges(pool, rays.nu * rays.nv, &rays, proc(data: rawptr, lo, hi: int) {
		rays := cast(^Lattice_Rays)data
		for ray in lo ..< hi {
			hs := rays.hits[rays.first[ray]:rays.first[ray + 1]]
			for i in 1 ..< len(hs) {
				x := hs[i]
				k := i
				for k > 0 && hs[k - 1].w > x.w {
					hs[k] = hs[k - 1]
					k -= 1
				}
				hs[k] = x
			}
			for i in 1 ..< len(hs) do hs[i].wind += hs[i - 1].wind
		}
	}, 1 << 12)
	return
}

lattice_rays_destroy :: proc(r: ^Lattice_Rays) {
	delete(r.first, r.allocator)
	delete(r.hits, r.allocator)
	r^ = {}
}

// The crossings along the ray through lattice point (u, v), sorted along it.
lattice_ray_hits :: #force_inline proc(r: Lattice_Rays, u, v: int) -> []Lattice_Hit {
	ray := u + r.nu * v
	return r.hits[r.first[ray]:r.first[ray + 1]]
}

// Counts (or with `fill`, records) the crossings of triangle t with the rays along c.axis.
// In the plane of the rays (u, v), a ray at a lattice point crosses the triangle if it is
// inside all three edges, or on an edge that the top-left rule gives to this triangle;
// computed exactly in 64-bit integers.
@(private = "file")
triangle_hits :: #force_inline proc(c: ^Lattice_Caster, t: int, fill: bool) {
	w := c.axis
	u, v := (w + 1) % 3, (w + 2) % 3
	rays := c.rays
	i0, i1, i2 := c.m.indices[3 * t], c.m.indices[3 * t + 1], c.m.indices[3 * t + 2]
	a, b, cc := c.q[i0], c.q[i1], c.q[i2]
	au, av := i64(a[u]), i64(a[v])
	bu, bv := i64(b[u]), i64(b[v])
	cu, cv := i64(cc[u]), i64(cc[v])
	area := (bu - au) * (cv - av) - (bv - av) * (cu - au)
	if area == 0 do return
	// Along +w a triangle facing -w is entered, raising the winding number.
	delta: i32 = -1 if area > 0 else 1
	if t >= c.split do delta *= c.weight
	aw := (c.m.positions[i0][w] - c.origin[w]) / c.h
	bw := (c.m.positions[i1][w] - c.origin[w]) / c.h
	cw := (c.m.positions[i2][w] - c.origin[w]) / c.h
	if area < 0 {
		bu, bv, cu, cv = cu, cv, bu, bv
		bw, cw = cw, bw
		area = -area
	}
	lo_u := (min(au, bu, cu) + LATTICE_FIX - 1) / LATTICE_FIX
	hi_u := min(max(au, bu, cu) / LATTICE_FIX, i64(rays.nu - 1))
	lo_v := (min(av, bv, cv) + LATTICE_FIX - 1) / LATTICE_FIX
	hi_v := min(max(av, bv, cv) / LATTICE_FIX, i64(rays.nv - 1))
	covers :: #force_inline proc(e, du, dv: i64) -> bool {
		return e > 0 || (e == 0 && (dv < 0 || (dv == 0 && du < 0)))
	}
	for iv in lo_v ..= hi_v {
		pv := iv * LATTICE_FIX
		for iu in lo_u ..= hi_u {
			pu := iu * LATTICE_FIX
			e_ab := (bu - au) * (pv - av) - (bv - av) * (pu - au) // c's share
			e_bc := (cu - bu) * (pv - bv) - (cv - bv) * (pu - bu) // a's share
			e_ca := (au - cu) * (pv - cv) - (av - cv) * (pu - cu) // b's share
			if !covers(e_ab, bu - au, bv - av) || !covers(e_bc, cu - bu, cv - bv) || !covers(e_ca, au - cu, av - cv) do continue
			ray := int(iu) + rays.nu * int(iv)
			if !fill {
				sync.atomic_add_explicit(&rays.first[ray + 1], 1, .Relaxed)
				continue
			}
			slot := sync.atomic_add_explicit(&c.cursor[ray], 1, .Relaxed)
			at := (f64(e_bc) * f64(aw) + f64(e_ca) * f64(bw) + f64(e_ab) * f64(cw)) / f64(area)
			rays.hits[slot] = {w = f32(at), wind = delta}
		}
	}
}
