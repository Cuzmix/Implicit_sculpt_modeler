package voxel

import "base:runtime"
import "core:math"
import "core:slice"

import "../geom"
import "../jobs"

// Voxelisation: a closed mesh becomes clay. The lattice is the voxel grid; rays along x,
// y and z through every voxel row collect where the mesh crosses them (geom.lattice_rays,
// the exact casts the voxel remesh uses), the winding number along x says which voxels are
// inside, and a voxel beside a crossing gets the distance a plane through the crossings on
// its axes would have (exact for a flat surface, never more than the nearest axis distance).
// Those seeds are within a voxel of the surface, so the band repair (band.odin) solves the
// rest of the band from them, as it does after a stroke.

// How far along an axis a voxel can be from a crossing and still lie within BAND + 1 of the
// surface: a voxel that close has a surface point within BAND + 1 along each axis, and the
// surface there crosses a lattice edge of that point's cell (along the axis nearest its
// normal), one voxel further at most. A feature too small to cross any edge is not in the
// field at all.
VOXELIZE_REACH :: BAND + 2
// Voxels of lattice around the mesh's box: the reach, and one so a candidate brick's
// farthest voxel still has a ray.
VOXELIZE_MARGIN :: VOXELIZE_REACH + 1
// The most lattice points along an axis: the app's largest resolution, the margins and the
// point that closes the span.
VOXELIZE_MAX :: 1024 + 2 * VOXELIZE_MARGIN + 1
// A crossing is kept this far (in voxels) from the lattice points it lies between, so every
// seed is a distance above zero and quantizes to a value with the right sign.
CROSSING_MARGIN :: 0.02

// The voxel size that puts `across` voxels along the longest side of `bounds`.
voxel_size_for :: proc(bounds: geom.Aabb, across: int) -> f32 {
	e := bounds.hi - bounds.lo
	return max(e.x, e.y, e.z) / f32(max(across, 1))
}

// What the voxelising jobs share: the rays (read only once cast) and the lattice's place
// in the volume.
@(private = "file")
Voxelizer :: struct {
	c:     ^Clay,
	rays:  [3]geom.Lattice_Rays,
	g0:    [3]i32, // the voxel of lattice point (0, 0, 0)
	n:     [3]int, // lattice points per axis
	b_lo:  [3]i32, // the first brick of the box of bricks the lattice touches
	nb:    [3]int, // bricks per axis in that box
	marks: []u8,   // per brick of the box: 1 within VOXELIZE_REACH of a crossing
	slots: []u32,  // the pool slots of the marked bricks, in box order
}

// Builds `c`, which must not be initialised, as the clay of the closed mesh `m` (in the
// object's space) with voxels of size `voxel`: the field is the signed distance to the
// surface within the band, negative inside as the winding number along x says, in a
// volume centred on the mesh's box. False, with `c` left empty, for a mesh without
// triangles, a voxel size that is not positive, or one that needs more than VOXELIZE_MAX
// voxels along an axis, or when `progress` was cancelled (checked between the stages, each
// moving it over its `share` of the whole by a part measured on a 2M-vertex sphere at 1024
// voxels across in a release build), with `c` freed.
clay_from_mesh :: proc(c: ^Clay, m: geom.Mesh, voxel: f32, pool: ^jobs.Pool, allocator := context.allocator, progress: ^jobs.Progress = nil, share := [2]f32{0, 1}) -> bool {
	STAGES :: [?]f32{0, 0.02, 0.12, 0.15, 0.29, 0.46, 0.50, 1}
	stage := 0
	next :: proc(c: ^Clay, progress: ^jobs.Progress, stage: ^int, share: [2]f32) -> bool {
		stages := STAGES
		stage^ += 1
		jobs.progress_set(progress, share[0], share[1], stages[stage^])
		if !jobs.progress_cancelled(progress) do return true
		clay_destroy(c)
		return false
	}
	if len(m.indices) < 3 || !(voxel > 0) || math.is_inf(voxel) do return false
	_, bounds := geom.mesh_area_bounds(m, pool)
	if bounds.lo.x > bounds.hi.x do return false
	extent := bounds.hi - bounds.lo
	x := Voxelizer{c = c}
	for a in 0 ..< 3 {
		x.n[a] = int(extent[a] / voxel) + 2 * VOXELIZE_MARGIN + 1
		if x.n[a] > VOXELIZE_MAX do return false
	}
	clay_init(c, voxel, (bounds.lo + bounds.hi) * 0.5, pool, allocator)
	v := &c.volume
	// The lattice sits in the middle of the domain, its points on voxel centres.
	for a in 0 ..< 3 do x.g0[a] = i32(DOMAIN / 2 - x.n[a] / 2)
	origin := voxel_centre(v, x.g0)
	heap := runtime.heap_allocator()
	q := geom.lattice_quantize(m, origin, voxel, pool, heap)
	defer delete(q, heap)
	defer for &r in x.rays do geom.lattice_rays_destroy(&r)
	if !next(c, progress, &stage, share) do return false
	for a in 0 ..< 3 do x.rays[a] = geom.lattice_rays_cast(m, q, origin, voxel, x.n, a, len(m.indices) / 3, 1, pool, heap)
	if !next(c, progress, &stage, share) do return false

	// The box of bricks the lattice touches, and which of them lie within reach of a
	// crossing: a slab of bricks a job, each reading the rays whose crossings can reach it.
	x.b_lo = shr3(x.g0, 3)
	b_hi := shr3(x.g0 + {i32(x.n.x) - 1, i32(x.n.y) - 1, i32(x.n.z) - 1}, 3)
	for a in 0 ..< 3 do x.nb[a] = int(b_hi[a] - x.b_lo[a]) + 1
	x.marks = make([]u8, x.nb.x * x.nb.y * x.nb.z, heap)
	defer delete(x.marks, heap)
	jobs.parallel_for(pool, x.nb.z, &x, proc(data: rawptr, bz: int) {
		x := cast(^Voxelizer)data
		mark_slab(x, bz)
	})
	if !next(c, progress, &stage, share) do return false

	// Candidates become bricks (serially: the directory grows); a brick out of reach is a
	// tile of the sign its first voxel has.
	slots := make([dynamic]u32, 0, 1024, heap)
	defer delete(slots)
	for bz in 0 ..< x.nb.z do for by in 0 ..< x.nb.y do for bx in 0 ..< x.nb.x {
		bc := x.b_lo + {i32(bx), i32(by), i32(bz)}
		if x.marks[(bz * x.nb.y + by) * x.nb.x + bx] != 0 {
			slot, _ := volume_brick_make(v, bc, CLAMP)
			append(&slots, slot)
		} else if lattice_inside(&x, bc * BRICK) {
			table := volume_table_make(v, bc)
			table.bricks[brick_slot_in_chunk(bc)] = TILE_INSIDE
		}
	}
	x.slots = slots[:]
	if !next(c, progress, &stage, share) do return false
	jobs.parallel_for(pool, len(x.slots), &x, proc(data: rawptr, i: int) {
		x := cast(^Voxelizer)data
		seed_brick(x, x.slots[i])
	})
	if !next(c, progress, &stage, share) do return false
	// A brick the surface never came near is a tile after all; the rest are repaired.
	for slot in x.slots {
		if tile := brick_tile(&v.bricks[slot]); tile != .Brick {
			volume_brick_collapse(v, v.coords[slot], tile)
			continue
		}
		band_mark(c, slot)
	}
	{
		live := volume_slots(v, heap)
		defer delete(live, heap)
		_ = resolve_saddles(c, live, false)
	}
	if !next(c, progress, &stage, share) do return false
	band_repair(c)
	surface_mark_all(c)
	return next(c, progress, &stage, share)
}

// Whether voxel `g` is inside: the winding number of its x ray just before it is positive.
// Voxels off the lattice are outside.
@(private = "file")
lattice_inside :: proc(x: ^Voxelizer, g: [3]i32) -> bool {
	l := g - x.g0
	for a in 0 ..< 3 do if l[a] < 0 || int(l[a]) >= x.n[a] do return false
	hits := geom.lattice_ray_hits(x.rays[0], int(l.y), int(l.z))
	i := hits_before(hits, f32(l.x))
	return i > 0 && hits[i - 1].wind > 0
}

// How many of the sorted `hits` lie strictly before `w` along the ray.
@(private = "file")
hits_before :: #force_inline proc(hits: []geom.Lattice_Hit, w: f32) -> int {
	i, _ := slice.binary_search_by(hits, w, proc(h: geom.Lattice_Hit, w: f32) -> slice.Ordering {return .Less if h.w < w else .Greater})
	return i
}

// Where the surface crosses the lattice edge from point `lo` to `lo + 1` along the ray
// through (u, v) of `rays`, as a fraction of the edge: the last crossing in it that changes
// the winding's sign, the middle when none does (the x rays decided the signs differ, so
// something crosses), kept CROSSING_MARGIN off either end.
@(private = "file")
crossing_between :: proc(rays: geom.Lattice_Rays, u, v, lo: int) -> f32 {
	at := f32(0.5)
	if u >= 0 && v >= 0 && u < rays.nu && v < rays.nv {
		hits := geom.lattice_ray_hits(rays, u, v)
		for i := hits_before(hits, f32(lo)); i < len(hits) && hits[i].w < f32(lo + 1); i += 1 {
			prev: i32 = hits[i - 1].wind if i > 0 else 0
			if (prev > 0) != (hits[i].wind > 0) do at = hits[i].w - f32(lo)
		}
	}
	return clamp(at, CROSSING_MARGIN, 1 - CROSSING_MARGIN)
}

// Marks the bricks of slab `bz` of the box that lie within VOXELIZE_REACH voxels of a
// crossing of a ray along any axis (a face square to an axis is crossed by that axis's rays
// alone): every ray whose crossings can reach the slab is walked.
@(private = "file")
mark_slab :: proc(x: ^Voxelizer, bz: int) {
	z_lo := int((x.b_lo.z + i32(bz)) * BRICK - x.g0.z) - VOXELIZE_REACH // lattice z of the slab's reach
	z_hi := z_lo + BRICK - 1 + 2 * VOXELIZE_REACH
	for a in 0 ..< 3 {
		rays := x.rays[a]
		u, v := (a + 1) % 3, (a + 2) % 3
		// The range of ray indices whose lattice z can reach the slab: all of them for z rays.
		u_lo, u_hi, v_lo, v_hi := 0, rays.nu - 1, 0, rays.nv - 1
		if u == 2 do u_lo, u_hi = max(z_lo, 0), min(z_hi, rays.nu - 1)
		if v == 2 do v_lo, v_hi = max(z_lo, 0), min(z_hi, rays.nv - 1)
		for iv in v_lo ..= v_hi do for iu in u_lo ..= u_hi {
			hits := geom.lattice_ray_hits(rays, iu, iv)
			if len(hits) == 0 do continue
			g: [3]int
			g[u], g[v] = iu, iv
			i := 0
			if a == 2 do i = hits_before(hits, f32(z_lo))
			for ; i < len(hits); i += 1 {
				// The crossing lies between lattice points w and w + 1 along the axis.
				g[a] = int(math.floor(hits[i].w))
				if a == 2 && g[a] > z_hi do break
				mark_reach(x, bz, g, a)
			}
		}
	}
}

// Marks the bricks of slab `bz` within VOXELIZE_REACH of the crossing between lattice
// points `g` and `g + 1` along `axis`.
@(private = "file")
mark_reach :: #force_inline proc(x: ^Voxelizer, bz: int, g: [3]int, axis: int) {
	lo, hi: [3]i32
	for a in 0 ..< 3 {
		lo[a] = max((x.g0[a] + i32(g[a]) - VOXELIZE_REACH) >> 3, x.b_lo[a])
		hi[a] = min((x.g0[a] + i32(g[a]) + (1 if a == axis else 0) + VOXELIZE_REACH) >> 3, x.b_lo[a] + i32(x.nb[a]) - 1)
	}
	slab := x.b_lo.z + i32(bz)
	if slab < lo.z || slab > hi.z do return
	for by in lo.y ..= hi.y {
		row := (bz * x.nb.y + int(by - x.b_lo.y)) * x.nb.x
		for bx in lo.x ..= hi.x do x.marks[row + int(bx - x.b_lo.x)] = 1
	}
}

// The signs of a brick's voxels and the layer around them, from the x rays.
@(private = "file")
SIGN_WINDOW :: BRICK + 2

// Fills brick `slot` with its seeds: the sign of each voxel, and for a voxel beside a sign
// change the planar distance from the crossings on its axes; far (the clamp) elsewhere.
@(private = "file")
seed_brick :: proc(x: ^Voxelizer, slot: u32) {
	v := &x.c.volume
	bc := v.coords[slot]
	b := &v.bricks[slot]
	base := bc * BRICK - 1 // the window's first voxel
	inside: [SIGN_WINDOW * SIGN_WINDOW * SIGN_WINDOW]bool
	for wz in 0 ..< SIGN_WINDOW do for wy in 0 ..< SIGN_WINDOW {
		g := base + {0, i32(wy), i32(wz)}
		l := g - x.g0
		if l.y < 0 || l.z < 0 || int(l.y) >= x.n.y || int(l.z) >= x.n.z do continue
		hits := geom.lattice_ray_hits(x.rays[0], int(l.y), int(l.z))
		row := (wz * SIGN_WINDOW + wy) * SIGN_WINDOW
		// Walk the row with the crossings: a pointer past every crossing before the voxel.
		p := hits_before(hits, f32(l.x))
		for wx in 0 ..< SIGN_WINDOW {
			lx := l.x + i32(wx)
			if lx < 0 || int(lx) >= x.n.x do continue
			for p < len(hits) && hits[p].w < f32(lx) do p += 1
			inside[row + wx] = p > 0 && hits[p - 1].wind > 0
		}
	}
	at :: #force_inline proc(wx, wy, wz: int) -> int {return (wz * SIGN_WINDOW + wy) * SIGN_WINDOW + wx}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x_ in 0 ..< BRICK {
		w := at(x_ + 1, y + 1, z + 1)
		in_ := inside[w]
		l := bc * BRICK + {i32(x_), i32(y), i32(z)} - x.g0
		// The nearest crossing per axis, in voxels; infinite without one.
		ax := [3]f32{math.INF_F32, math.INF_F32, math.INF_F32}
		for a in 0 ..< 3 {
			u, vv := int(l[(a + 1) % 3]), int(l[(a + 2) % 3])
			for side in 0 ..< 2 {
				g := [3]int{x_ + 1, y + 1, z + 1}
				g[a] += 1 if side == 1 else -1
				if inside[at(g.x, g.y, g.z)] == in_ do continue
				if side == 1 {
					ax[a] = min(ax[a], crossing_between(x.rays[a], u, vv, int(l[a])))
				} else {
					ax[a] = min(ax[a], 1 - crossing_between(x.rays[a], u, vv, int(l[a]) - 1))
				}
			}
		}
		value := -CLAMP if in_ else CLAMP
		sum: f32
		for d in ax do if d < math.INF_F32 do sum += 1 / (d * d)
		if sum > 0 {
			d := 1 / math.sqrt(sum)
			value = quantize(-d if in_ else d)
		}
		b.d[voxel_index(x_, y, z)] = value
	}
}
