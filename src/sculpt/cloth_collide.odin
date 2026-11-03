package sculpt

import "base:runtime"
import "core:math"
import "core:math/linalg"

import "../geom"
import "../jobs"

// Collisions for the cloth (cloth.odin): after each substep's constraint rounds, every
// free vertex is pushed out of the floor, out of other objects and away from the cloth's
// own far parts, each a parallel pass that reads the positions the rounds left and
// writes new ones, so the result is the same on any number of threads. Blender's cloth
// brush raycasts against Collision-modifier objects every step; here each other object
// is a signed distance volume built once (cloth_volume_build) and kept until it changes,
// so a step costs one trilinear read a vertex an object, however dense the object is.

// A signed distance volume of a mesh: distances on a regular lattice in the mesh's own
// space, negative inside, clamped to `band` either side of the surface.
Cloth_Volume :: struct {
	dist:      []f32,
	dims:      [3]int,
	origin:    Vec3, // the first lattice point
	cell:      f32,
	band:      f32,
	allocator: runtime.Allocator,
}

// One object the cloth collides with: its volume and how to get there from the cloth
// mesh's space (an affine map; the transforms are similarities, so distances scale by
// `scale`, cloth units per volume unit).
Cloth_Collider :: struct {
	volume:    ^Cloth_Volume,
	to_volume: matrix[4, 4]f32,
	scale:     f32,
}

// What the cloth collides with for a stroke (sculptor_cloth_collide).
Cloth_Collisions :: struct {
	floor:       bool,
	floor_at:    Vec3, // a point of the floor plane, in the cloth mesh's space
	floor_up:    Vec3, // its normal, unit length, pointing to where the cloth may be
	colliders:   [dynamic]Cloth_Collider,
	gap:         f32, // how far from a surface the cloth stays; 0 for half a link
	thickness:   f32, // how far apart self collision keeps two vertices, in mean links; 0 for one
}

// Lattice points along the volume's longest side at most, and how many cells either side
// of the surface the distances are worked out for.
CLOTH_VOLUME_CELLS :: 96
CLOTH_VOLUME_BAND :: 4
// Triangles a leaf of the tree the volume's distances are found with: small leaves make
// each query try few triangles (layer_carry.odin measured eight as the best).
CLOTH_VOLUME_LEAF :: 8
// The share of its motion along a surface a vertex in contact keeps losing: Blender's
// cloth brush collisions take 35 %.
CLOTH_FRICTION :: 0.35
// Self collision looks for neighbours in cells of twice the thickness, a vertex at most
// this many a cell, which keeps a crumpled fold from costing more than the rest.
CLOTH_SELF_MAX :: 32

// Builds `v` as the signed distance volume of the closed mesh `m`, over its box and a
// band round it, CLOTH_VOLUME_CELLS lattice points along its longest side. Each lattice
// point near the surface takes the distance to the nearest triangle (a tree of small
// leaves built for it), negative where it lies behind that triangle. False for a mesh
// without triangles.
cloth_volume_build :: proc(v: ^Cloth_Volume, m: geom.Mesh, pool: ^jobs.Pool, allocator := context.allocator) -> bool {
	cloth_volume_destroy(v)
	if len(m.indices) < 3 do return false
	bounds := geom.AABB_EMPTY
	for p in m.positions do geom.aabb_grow(&bounds, p)
	extent := bounds.hi - bounds.lo
	size := max(extent.x, extent.y, extent.z)
	if !(size > 0) do return false
	v.cell = size / f32(CLOTH_VOLUME_CELLS - 1 - 2 * CLOTH_VOLUME_BAND)
	v.band = v.cell * CLOTH_VOLUME_BAND
	v.origin = bounds.lo - v.band
	for a in 0 ..< 3 do v.dims[a] = int(math.ceil((extent[a] + 2 * v.band) / v.cell)) + 1
	v.allocator = allocator
	v.dist = make([]f32, v.dims.x * v.dims.y * v.dims.z, allocator)
	Build :: struct {
		v:   ^Cloth_Volume,
		m:   geom.Mesh,
		bvh: geom.Bvh,
	}
	b := Build{v = v, m = m}
	b.bvh = geom.bvh_build_morton(m, CLOTH_VOLUME_LEAF, pool, context.allocator)
	defer geom.bvh_destroy(&b.bvh)
	// A slab of lattice points a job; each row starts its search from the last point's
	// triangle, which the next is likely near.
	jobs.parallel_for(pool, v.dims.z, &b, proc(data: rawptr, z: int) {
		b := cast(^Build)data
		v, m := b.v, b.m
		for y in 0 ..< v.dims.y {
			hint := geom.BVH_NONE
			for x in 0 ..< v.dims.x {
				p := v.origin + Vec3{f32(x), f32(y), f32(z)} * v.cell
				d := v.band
				tri, bary, dist, ok := geom.bvh_closest(b.bvh, m, p, v.band, hint)
				if ok {
					hint = tri
					c := m.indices[3 * tri:][:3]
					a, e, f := m.positions[c[0]], m.positions[c[1]], m.positions[c[2]]
					q := bary[0] * a + bary[1] * e + bary[2] * f
					n := linalg.cross(e - a, f - a)
					d = -dist if linalg.dot(p - q, n) < 0 else dist
				}
				if !ok do d = math.nan_f32()
				v.dist[(z * v.dims.y + y) * v.dims.x + x] = d
			}
			// Past the band the sign is unknown: a run of such points between two
			// inside ones is inside (deep in the mesh), any other outside, as a row
			// leaving the box starts and ends outside a closed mesh.
			row := v.dist[(z * v.dims.y + y) * v.dims.x:][:v.dims.x]
			x := 0
			for x < len(row) {
				if !math.is_nan(row[x]) {
					x += 1
					continue
				}
				end := x
				for end < len(row) && math.is_nan(row[end]) do end += 1
				inside := x > 0 && end < len(row) && row[x - 1] < 0 && row[end] < 0
				for k in x ..< end do row[k] = -v.band if inside else v.band
				x = end
			}
		}
	})
	return true
}

cloth_volume_destroy :: proc(v: ^Cloth_Volume) {
	if v.dist != nil do delete(v.dist, v.allocator)
	v^ = {}
}

// The volume's distance at `p` (its own space), trilinear between lattice points, and
// which way it grows (unit length, or zero where it cannot tell); the band outside the
// lattice.
cloth_volume_sample :: proc(v: ^Cloth_Volume, p: Vec3) -> (d: f32, grad: Vec3) {
	g := (p - v.origin) / v.cell
	for a in 0 ..< 3 do if !(g[a] >= 0 && g[a] < f32(v.dims[a] - 1)) do return v.band, {}
	i := [3]int{int(g.x), int(g.y), int(g.z)}
	t := g - Vec3{f32(i.x), f32(i.y), f32(i.z)}
	at :: #force_inline proc(v: ^Cloth_Volume, x, y, z: int) -> f32 {return v.dist[(z * v.dims.y + y) * v.dims.x + x]}
	c: [2][2][2]f32
	for dz in 0 ..< 2 do for dy in 0 ..< 2 do for dx in 0 ..< 2 do c[dz][dy][dx] = at(v, i.x + dx, i.y + dy, i.z + dz)
	x00 := math.lerp(c[0][0][0], c[0][0][1], t.x)
	x10 := math.lerp(c[0][1][0], c[0][1][1], t.x)
	x01 := math.lerp(c[1][0][0], c[1][0][1], t.x)
	x11 := math.lerp(c[1][1][0], c[1][1][1], t.x)
	y0, y1 := math.lerp(x00, x10, t.y), math.lerp(x01, x11, t.y)
	d = math.lerp(y0, y1, t.z)
	// The gradient of the same trilinear blend.
	gx := math.lerp(math.lerp(c[0][0][1] - c[0][0][0], c[0][1][1] - c[0][1][0], t.y), math.lerp(c[1][0][1] - c[1][0][0], c[1][1][1] - c[1][1][0], t.y), t.z)
	gy := math.lerp(x10 - x00, x11 - x01, t.z)
	gz := y1 - y0
	grad = linalg.normalize0(Vec3{gx, gy, gz})
	return
}

// Sets what the cloth stroke under way collides with; the colliders' volumes must stay
// alive until it ends. Takes effect from the next step.
sculptor_cloth_collide :: proc(s: ^Sculptor, with: Cloth_Collisions) {
	c := &s.cloth
	if c.collide.colliders == nil do c.collide.colliders = make([dynamic]Cloth_Collider, s.history.allocator)
	clear(&c.collide.colliders)
	append(&c.collide.colliders, ..with.colliders[:])
	colliders := c.collide.colliders
	c.collide = with
	c.collide.colliders = colliders
	c.collide.floor_up = linalg.normalize0(with.floor_up)
	if c.collide.floor_up == {} do c.collide.floor = false
}

// Whether the stroke collides with anything.
@(private)
cloth_collides :: proc(c: ^Cloth) -> bool {
	return c.collide.floor || len(c.collide.colliders) > 0 || c.settings.self_collide
}

// One collision pass over the cloth: c.pos in, c.next out (the caller swaps).
@(private)
cloth_collide_pass :: proc(s: ^Sculptor, pool: ^jobs.Pool) {
	c := &s.cloth
	n := len(c.verts)
	if c.settings.self_collide do cloth_self_grid(s)
	jobs.parallel_for(pool, (n + CLOTH_CHUNK - 1) / CLOTH_CHUNK, s, proc(data: rawptr, k: int) {
		s := cast(^Sculptor)data
		c := &s.cloth
		col := &c.collide
		gap := col.gap if col.gap > 0 else c.link_mean * 0.5
		lo, hi := k * CLOTH_CHUNK, min((k + 1) * CLOTH_CHUNK, len(c.verts))
		for i in lo ..< hi {
			p := c.pos[i]
			free := 1 - c.pin[i]
			if free <= 0 {
				c.next[i] = p
				continue
			}
			q := p
			if c.settings.self_collide do q += cloth_self_push(s, i) * free
			touched := false
			if col.floor {
				// No gap from the floor, which stands at the scene's lowest point: often
				// the cloth's own, which must not jump up as the stroke begins.
				if d := linalg.dot(q - col.floor_at, col.floor_up); d < 0 {
					q -= col.floor_up * d
					touched = true
				}
			}
			for &o in col.colliders {
				x := o.to_volume * [4]f32{q.x, q.y, q.z, 1}
				d, grad := cloth_volume_sample(o.volume, x.xyz)
				d *= o.scale
				if d >= gap || grad == {} do continue
				// Back from the volume's space: the turn of the map's inverse is its
				// transpose, scaled, so the gradient's way comes back by the transpose.
				t := o.to_volume
				linear := matrix[3, 3]f32{t[0, 0], t[0, 1], t[0, 2], t[1, 0], t[1, 1], t[1, 2], t[2, 0], t[2, 1], t[2, 2]}
				up := linalg.normalize0(linalg.transpose(linear) * grad)
				q += up * (gap - d)
				touched = true
			}
			if touched {
				// Friction: what moved along the surface since the last step loses a share.
				moved := q - c.prev[i]
				q -= moved * CLOTH_FRICTION * free
			}
			c.next[i] = linalg.lerp(p, q, free)
		}
	})
}

// Self collision's grid: each vertex's cell (of twice the thickness) hashed into a table
// of as many slots as vertices, then counting-sorted by slot in index order, so each
// slot lists its vertices ascending whatever the threads did.
@(private = "file")
cloth_self_grid :: proc(s: ^Sculptor) {
	c := &s.cloth
	n := len(c.verts)
	c.self_cell = 2 * c.link_mean * (c.collide.thickness if c.collide.thickness > 0 else 1)
	resize(&c.self_slot, n)
	resize(&c.self_first, n + 1)
	resize(&c.self_order, n)
	for &x in c.self_first do x = 0
	for i in 0 ..< n {
		slot := cloth_self_slot(c, cloth_self_cell(c, c.pos[i]))
		c.self_slot[i] = slot
		c.self_first[slot + 1] += 1
	}
	for i in 0 ..< n do c.self_first[i + 1] += c.self_first[i]
	fill := make([]u32, n, context.temp_allocator)
	copy(fill, c.self_first[:n])
	for i in 0 ..< n {
		slot := c.self_slot[i]
		c.self_order[fill[slot]] = u32(i)
		fill[slot] += 1
	}
}

@(private = "file")
cloth_self_cell :: #force_inline proc(c: ^Cloth, p: Vec3) -> [3]i32 {
	g := p / c.self_cell
	return {i32(math.floor(g.x)), i32(math.floor(g.y)), i32(math.floor(g.z))}
}

@(private = "file")
cloth_self_slot :: #force_inline proc(c: ^Cloth, cell: [3]i32) -> u32 {
	h := u32(cell.x) * 73856093 ~ u32(cell.y) * 19349663 ~ u32(cell.z) * 83492791
	return h % u32(len(c.self_slot))
}

// How far vertex `i` moves away from the vertices of the cloth nearer than the thickness
// that are not its own neighbours: half of each overlap (the other vertex takes the other
// half on its own), at most CLOTH_SELF_MAX of them, in the grid's order.
@(private = "file")
cloth_self_push :: proc(s: ^Sculptor, i: int) -> Vec3 {
	c := &s.cloth
	p := c.pos[i]
	thick := c.self_cell * 0.5
	home := cloth_self_cell(c, p)
	push: Vec3
	met := 0
	links := c.links[c.first[i]:c.first[i + 1]]
	for dz in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
		cell := home + {dx, dy, dz}
		slot := cloth_self_slot(c, cell)
		for k in c.self_first[slot] ..< c.self_first[slot + 1] {
			u := c.self_order[k]
			if int(u) == i || cloth_self_cell(c, c.pos[u]) != cell do continue
			d := p - c.pos[u]
			dist := linalg.length(d)
			if dist >= thick || dist < 1e-12 do continue
			near := false
			for l in links do if l == u {near = true; break}
			if near do continue
			push += d * ((thick - dist) * 0.5 / dist)
			met += 1
			if met == CLOTH_SELF_MAX do return push
		}
	}
	return push
}
