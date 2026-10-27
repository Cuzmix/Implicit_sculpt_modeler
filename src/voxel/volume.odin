// Package voxel is the volume sculptor: a signed distance field kept only in a narrow
// band around the surface, in bricks of 8³ voxels, sculpted by brushes that change the
// field and shown through a triangle surface meshed brick group by brick group
// (mesh.odin). Negative is inside, as in sdf_trial and sm-sdf.
//
// The field is sparse. A brick exists only where the band passes; everywhere else a tile
// code says the voxels are all outside (Empty) or all inside (Inside). Values are fixed
// point, SCALE units a voxel, clamped to ±CLAMP, so a brick is 1 KiB and memory follows the
// surface's area, not the volume. The directory is two levels: a fixed table of chunks over
// the domain, each chunk a table of its bricks, made the first time anything in the chunk is
// not Empty.
package voxel

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

Vec3 :: geom.Vec3

BRICK :: 8 // voxels along a brick's edge
BRICK_VOXELS :: BRICK * BRICK * BRICK
NODE_BRICKS :: 2 // bricks along a node's edge: a node is 16³ voxels, the unit meshed and uploaded
NODE :: NODE_BRICKS * BRICK
CHUNK_BRICKS :: 16 // bricks along a chunk's edge: the unit of the directory
CHUNK_NODES :: CHUNK_BRICKS / NODE_BRICKS
CHUNK :: CHUNK_BRICKS * BRICK
MAX_CHUNKS :: 32 // chunks along the domain's edge: 4096 voxels, DynaMesh's top lattice
DOMAIN :: MAX_CHUNKS * CHUNK
MAX_BRICKS :: MAX_CHUNKS * CHUNK_BRICKS
MAX_NODES :: MAX_BRICKS / NODE_BRICKS
SCALE :: 4096 // fixed-point units a voxel: a thousandth of a voxel is well below what shows
BAND :: 3 // voxels either side of the surface that hold true distances
CLAMP :: i16((BAND + 1) * SCALE) // values are kept within this; one voxel past the band keeps interpolation right

// Tile codes in a chunk's brick table, where no pool index is.
TILE_EMPTY :: max(u32)
TILE_INSIDE :: max(u32) - 1
NODE_NONE :: max(u32)
// The coordinate of a free pool slot.
BRICK_FREE :: [3]i32{min(i32), min(i32), min(i32)}

Tile :: enum u8 {
	Empty,
	Inside,
	Brick,
}

// 8³ fixed-point distances, x fastest, then y, then z (voxel_index).
Brick :: struct {
	d: [BRICK_VOXELS]i16,
}

// One chunk's tables: its bricks (a tile code or the pool index of the brick) and, for
// the surface, its nodes (NODE_NONE or an index into Surface.nodes).
Chunk_Table :: struct {
	bricks: [CHUNK_BRICKS * CHUNK_BRICKS * CHUNK_BRICKS]u32,
	nodes:  [CHUNK_NODES * CHUNK_NODES * CHUNK_NODES]u32,
}

Volume :: struct {
	voxel:     f32, // a voxel's size in the object's space
	origin:    Vec3, // the object-space centre of voxel (0, 0, 0)
	chunks:    []u32, // MAX_CHUNKS³: table index + 1, 0 for a chunk that is all Empty
	tables:    [dynamic]^Chunk_Table,
	bricks:    [dynamic]Brick, // the pool
	coords:    [dynamic][3]i32, // per pool slot: its brick coordinate, BRICK_FREE when free
	saved:     [dynamic]u32, // per pool slot: the stroke that last saved the brick for undo (undo.odin)
	pending:   [dynamic]u32, // per pool slot: the repair generation the brick waits for (band.odin)
	region:    [dynamic]u32, // per pool slot: its index in the repair's region while one runs
	free:      [dynamic]u32,
	allocator: runtime.Allocator,
}

// A volume whose domain of DOMAIN³ voxels of size `voxel` is centred on `centre`.
volume_init :: proc(v: ^Volume, voxel: f32, centre: Vec3, allocator := context.allocator) {
	assert(voxel > 0, "a voxel needs a size")
	v.voxel = voxel
	v.origin = centre - f32(DOMAIN) * 0.5 * voxel
	v.allocator = allocator
	v.chunks = make([]u32, MAX_CHUNKS * MAX_CHUNKS * MAX_CHUNKS, allocator)
	v.tables = make([dynamic]^Chunk_Table, allocator)
	v.bricks = make([dynamic]Brick, allocator)
	v.coords = make([dynamic][3]i32, allocator)
	v.saved = make([dynamic]u32, allocator)
	v.pending = make([dynamic]u32, allocator)
	v.region = make([dynamic]u32, allocator)
	v.free = make([dynamic]u32, allocator)
}

volume_destroy :: proc(v: ^Volume) {
	for t in v.tables do free(t, v.allocator)
	delete(v.tables)
	delete(v.chunks, v.allocator)
	delete(v.bricks)
	delete(v.coords)
	delete(v.saved)
	delete(v.pending)
	delete(v.region)
	delete(v.free)
	v^ = {}
}

// How many bytes the field takes: bricks (free slots included) and tables.
volume_bytes :: proc(v: ^Volume) -> int {
	return len(v.bricks) * size_of(Brick) + len(v.tables) * size_of(Chunk_Table) + len(v.chunks) * size_of(u32)
}

// Bricks holding values (not free slots).
volume_brick_count :: proc(v: ^Volume) -> int {
	return len(v.bricks) - len(v.free)
}

voxel_index :: #force_inline proc(x, y, z: int) -> int {
	return (z * BRICK + y) * BRICK + x
}

// The object-space centre of voxel `g`.
voxel_centre :: #force_inline proc(v: ^Volume, g: [3]i32) -> Vec3 {
	return v.origin + Vec3{f32(g.x), f32(g.y), f32(g.z)} * v.voxel
}

// The object-space point `p` in voxel coordinates (voxel (0, 0, 0)'s centre at 0).
voxel_coords :: #force_inline proc(v: ^Volume, p: Vec3) -> Vec3 {
	return (p - v.origin) / v.voxel
}

brick_in_domain :: #force_inline proc(bc: [3]i32) -> bool {
	return bc.x >= 0 && bc.y >= 0 && bc.z >= 0 && bc.x < MAX_BRICKS && bc.y < MAX_BRICKS && bc.z < MAX_BRICKS
}

// Shifts and masks per component: Odin's array arithmetic has no shift.
shr3 :: #force_inline proc(a: [3]i32, $N: u32) -> [3]i32 {
	return {a.x >> N, a.y >> N, a.z >> N}
}

and3 :: #force_inline proc(a: [3]i32, $M: i32) -> [3]i32 {
	return {a.x & M, a.y & M, a.z & M}
}

@(private)
chunk_slot :: #force_inline proc(bc: [3]i32) -> int {
	cc := shr3(bc, 4) // CHUNK_BRICKS is 16
	return (int(cc.z) * MAX_CHUNKS + int(cc.y)) * MAX_CHUNKS + int(cc.x)
}

@(private)
brick_slot_in_chunk :: #force_inline proc(bc: [3]i32) -> int {
	lb := and3(bc, CHUNK_BRICKS - 1)
	return (int(lb.z) * CHUNK_BRICKS + int(lb.y)) * CHUNK_BRICKS + int(lb.x)
}

@(private)
node_slot_in_chunk :: #force_inline proc(nc: [3]i32) -> int {
	ln := and3(nc, CHUNK_NODES - 1)
	return (int(ln.z) * CHUNK_NODES + int(ln.y)) * CHUNK_NODES + int(ln.x)
}

// The chunk table holding brick `bc`, or nil when the chunk has never been touched.
@(private)
volume_table :: #force_inline proc(v: ^Volume, bc: [3]i32) -> ^Chunk_Table {
	t := v.chunks[chunk_slot(bc)]
	if t == 0 do return nil
	return v.tables[t - 1]
}

// The chunk table holding brick `bc`, made (all Empty, no nodes) when the chunk had none.
@(private)
volume_table_make :: proc(v: ^Volume, bc: [3]i32) -> ^Chunk_Table {
	slot := chunk_slot(bc)
	if t := v.chunks[slot]; t != 0 do return v.tables[t - 1]
	table := new(Chunk_Table, v.allocator)
	slice.fill(table.bricks[:], TILE_EMPTY)
	slice.fill(table.nodes[:], NODE_NONE)
	append(&v.tables, table)
	v.chunks[slot] = u32(len(v.tables))
	return table
}

// What brick `bc` is: a tile, or a brick with its values. Outside the domain everything is Empty.
volume_tile :: proc(v: ^Volume, bc: [3]i32) -> (tile: Tile, brick: ^Brick) {
	if !brick_in_domain(bc) do return .Empty, nil
	table := volume_table(v, bc)
	if table == nil do return .Empty, nil
	switch slot := table.bricks[brick_slot_in_chunk(bc)]; slot {
	case TILE_EMPTY:
		return .Empty, nil
	case TILE_INSIDE:
		return .Inside, nil
	case:
		return .Brick, &v.bricks[slot]
	}
}

// The pool slot of brick `bc`, or a tile code.
volume_slot :: proc(v: ^Volume, bc: [3]i32) -> u32 {
	if !brick_in_domain(bc) do return TILE_EMPTY
	table := volume_table(v, bc)
	if table == nil do return TILE_EMPTY
	return table.bricks[brick_slot_in_chunk(bc)]
}

// The value a tile stands for.
tile_value :: #force_inline proc(tile: Tile) -> i16 {
	return -CLAMP if tile == .Inside else CLAMP
}

// Makes brick `bc` a brick holding `fill` everywhere (the value of the tile it replaces,
// usually) and returns its pool slot. A brick that exists is returned as it is.
volume_brick_make :: proc(v: ^Volume, bc: [3]i32, fill: i16) -> (slot: u32, brick: ^Brick) {
	assert(brick_in_domain(bc), "brick outside the domain")
	table := volume_table_make(v, bc)
	at := brick_slot_in_chunk(bc)
	if s := table.bricks[at]; s != TILE_EMPTY && s != TILE_INSIDE do return s, &v.bricks[s]
	if len(v.free) > 0 {
		slot = pop(&v.free)
	} else {
		slot = u32(len(v.bricks))
		append(&v.bricks, Brick{})
		append(&v.coords, BRICK_FREE)
		append(&v.saved, 0)
		append(&v.pending, 0)
		append(&v.region, 0)
	}
	// A reused slot starts over: its stamps were another brick's.
	v.coords[slot] = bc
	v.saved[slot], v.pending[slot] = 0, 0
	table.bricks[at] = slot
	brick = &v.bricks[slot]
	slice.fill(brick.d[:], fill)
	return
}

// Turns brick `bc` into tile `tile`, freeing its values. Nothing if it is a tile already.
volume_brick_collapse :: proc(v: ^Volume, bc: [3]i32, tile: Tile) {
	assert(tile != .Brick, "collapse to a tile")
	table := volume_table_make(v, bc)
	at := brick_slot_in_chunk(bc)
	if s := table.bricks[at]; s != TILE_EMPTY && s != TILE_INSIDE {
		v.coords[s] = BRICK_FREE
		append(&v.free, s)
	}
	table.bricks[at] = TILE_INSIDE if tile == .Inside else TILE_EMPTY
}

// The tile a brick's values amount to, if they are all at a clamp: Brick otherwise.
brick_tile :: proc(b: ^Brick) -> Tile {
	lo, hi := b.d[0], b.d[0]
	for x in b.d {
		lo, hi = min(lo, x), max(hi, x)
	}
	if lo >= CLAMP do return .Empty
	if hi <= -CLAMP do return .Inside
	return .Brick
}

// The value at voxel `g`: the brick's, or its tile's.
volume_value :: proc(v: ^Volume, g: [3]i32) -> i16 {
	if g.x < 0 || g.y < 0 || g.z < 0 do return CLAMP
	tile, brick := volume_tile(v, shr3(g, 3)) // BRICK is 8
	if brick == nil do return tile_value(tile)
	l := and3(g, BRICK - 1)
	return brick.d[voxel_index(int(l.x), int(l.y), int(l.z))]
}

// The field at `p` (object space), trilinear between voxel centres, in voxels.
volume_sample :: proc(v: ^Volume, p: Vec3) -> f32 {
	g := voxel_coords(v, p)
	f := linalg.floor(g)
	i := [3]i32{i32(f.x), i32(f.y), i32(f.z)}
	t := g - f
	c: [8]f32
	for k in 0 ..< 8 {
		c[k] = f32(volume_value(v, i + {i32(k & 1), i32(k >> 1 & 1), i32(k >> 2 & 1)}))
	}
	x0 := math.lerp(c[0], c[1], t.x)
	x1 := math.lerp(c[2], c[3], t.x)
	x2 := math.lerp(c[4], c[5], t.x)
	x3 := math.lerp(c[6], c[7], t.x)
	y0 := math.lerp(x0, x1, t.y)
	y1 := math.lerp(x2, x3, t.y)
	return math.lerp(y0, y1, t.z) / SCALE
}

// The field's gradient at `p` (object space), unit length, pointing out of the volume;
// zero where the field is flat (deep inside a tile).
volume_gradient :: proc(v: ^Volume, p: Vec3) -> Vec3 {
	h := 0.5 * v.voxel
	g := Vec3 {
		volume_sample(v, p + {h, 0, 0}) - volume_sample(v, p - {h, 0, 0}),
		volume_sample(v, p + {0, h, 0}) - volume_sample(v, p - {0, h, 0}),
		volume_sample(v, p + {0, 0, h}) - volume_sample(v, p - {0, 0, h}),
	}
	return linalg.normalize0(g)
}

// The object-space box around every brick holding values; empty (lo > hi) without any.
volume_bounds :: proc(v: ^Volume) -> (b: geom.Aabb) {
	b = geom.AABB_EMPTY
	for c in v.coords {
		if c == BRICK_FREE do continue
		lo := v.origin + Vec3{f32(c.x), f32(c.y), f32(c.z)} * (BRICK * v.voxel) - 0.5 * v.voxel
		geom.aabb_grow(&b, lo)
		geom.aabb_grow(&b, lo + BRICK * v.voxel)
	}
	return
}

// The most steps a ray takes before it is called a miss: enough to cross the domain in
// steps of a quarter voxel.
@(private = "file")
RAYCAST_MAX_STEPS :: 4 * DOMAIN * 2

// Where the ray from `origin` along `dir` (object space, any length) first enters the
// volume, and the surface normal there. Empty tiles are skipped a brick at a time; inside
// bricks the ray advances by the field's value, so it never overshoots a surface, and the
// crossing is refined by bisection.
volume_raycast :: proc(v: ^Volume, origin, dir: Vec3) -> (hit, normal: Vec3, ok: bool) {
	d := linalg.normalize0(dir)
	if d == {} do return
	o := voxel_coords(v, origin)
	// Clip to the domain (voxel centres from 0 to DOMAIN - 1).
	t_enter, t_exit: f32 = 0, max(f32)
	for a in 0 ..< 3 {
		lo, hi := -0.5 - o[a], f32(DOMAIN) - 0.5 - o[a]
		if d[a] == 0 {
			if lo > 0 || hi < 0 do return
			continue
		}
		t0, t1 := lo / d[a], hi / d[a]
		if t0 > t1 do t0, t1 = t1, t0
		t_enter, t_exit = max(t_enter, t0), min(t_exit, t1)
	}
	if t_enter > t_exit do return
	t := t_enter
	prev_t := t_enter
	for _ in 0 ..< RAYCAST_MAX_STEPS {
		if t > t_exit do return
		g := o + d * t
		gi := [3]i32{i32(math.floor(g.x + 0.5)), i32(math.floor(g.y + 0.5)), i32(math.floor(g.z + 0.5))}
		bc := shr3(gi, 3)
		tile, brick := volume_tile(v, bc)
		if brick == nil {
			if tile == .Inside do break
			// Skip to where the ray leaves this brick's box.
			leave := max(f32)
			for a in 0 ..< 3 {
				if d[a] == 0 do continue
				edge := f32(bc[a] * BRICK) - 0.5 + (BRICK if d[a] > 0 else 0)
				leave = min(leave, (edge - o[a]) / d[a])
			}
			prev_t = t
			t = leave + 1e-3
			continue
		}
		s := volume_sample_voxels(v, g)
		if s <= 0 {
			// Bisect between the last outside sample and this one.
			lo, hi := prev_t, t
			for _ in 0 ..< 12 {
				mid := 0.5 * (lo + hi)
				if volume_sample_voxels(v, o + d * mid) <= 0 do hi = mid
				else do lo = mid
			}
			t = hi
			break
		}
		prev_t = t
		t += max(s * 0.9, 0.25)
	}
	if t > t_exit do return
	hit = v.origin + (o + d * t) * v.voxel
	normal = volume_gradient(v, hit)
	return hit, normal, true
}

// volume_sample with the point already in voxel coordinates.
@(private)
volume_sample_voxels :: proc(v: ^Volume, g: Vec3) -> f32 {
	return volume_sample(v, v.origin + g * v.voxel)
}

// The voxel-unit distance to a sphere of `radius` (object space) at `centre`, as a fixed-point
// value, clamped.
@(private)
sphere_value :: #force_inline proc(p, centre: Vec3, radius, voxel: f32) -> i16 {
	return quantize((linalg.length(p - centre) - radius) / voxel)
}

// A voxel-unit distance as the stored value, clamped to ±CLAMP.
quantize :: #force_inline proc(d: f32) -> i16 {
	return i16(clamp(d * SCALE, -f32(CLAMP), f32(CLAMP)))
}

// Fills the volume with a sphere of `radius` at `centre` (object space), replacing what
// was there. Bricks are allocated for the band only; the rest becomes tiles.
volume_fill_sphere :: proc(v: ^Volume, centre: Vec3, radius: f32, pool: ^jobs.Pool = nil) {
	for t in v.tables do free(t, v.allocator)
	clear(&v.tables)
	slice.zero(v.chunks)
	clear(&v.bricks)
	clear(&v.coords)
	clear(&v.saved)
	clear(&v.pending)
	clear(&v.region)
	clear(&v.free)
	r_vox := radius / v.voxel
	c := voxel_coords(v, centre)
	reach := r_vox + BAND + 2
	lo := brick_floor(c - reach)
	hi := brick_floor(c + reach)
	// A brick's box lies wholly in a tile when its farthest corner is on the band's one
	// side; HALF_DIAGONAL is the farthest a corner is from the centre.
	HALF_DIAGONAL :: BRICK * 0.8660254 // sqrt(3) / 2
	made := make([dynamic]u32, context.temp_allocator)
	for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
		bc := [3]i32{x, y, z}
		if !brick_in_domain(bc) do continue
		mid := Vec3{f32(x), f32(y), f32(z)} * BRICK + (BRICK - 1) * 0.5
		dist := linalg.length(mid - c) - r_vox
		if dist > HALF_DIAGONAL + BAND + 1 do continue
		if dist < -(HALF_DIAGONAL + BAND + 1) {
			table := volume_table_make(v, bc)
			table.bricks[brick_slot_in_chunk(bc)] = TILE_INSIDE
			continue
		}
		slot, _ := volume_brick_make(v, bc, CLAMP)
		append(&made, slot)
	}
	Fill :: struct {
		v:      ^Volume,
		slots:  []u32,
		centre: Vec3,
		radius: f32,
	}
	fill := Fill{v, made[:], centre, radius}
	jobs.parallel_for(pool, len(made), &fill, proc(data: rawptr, i: int) {
		f := cast(^Fill)data
		slot := f.slots[i]
		brick_fill_sphere(f.v, &f.v.bricks[slot], f.v.coords[slot], f.centre, f.radius)
	})
	// A brick the sphere only grazes may be all one clamp after all.
	for slot in made {
		if tile := brick_tile(&v.bricks[slot]); tile != .Brick do volume_brick_collapse(v, v.coords[slot], tile)
	}
}

@(private)
brick_fill_sphere :: proc(v: ^Volume, b: ^Brick, bc: [3]i32, centre: Vec3, radius: f32) {
	base := bc * BRICK
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		p := voxel_centre(v, base + {i32(x), i32(y), i32(z)})
		b.d[voxel_index(x, y, z)] = sphere_value(p, centre, radius, v.voxel)
	}
}

// The brick coordinate of the voxel coordinate `g` (floor), per axis.
brick_floor :: #force_inline proc(g: Vec3) -> [3]i32 {
	f := linalg.floor(g / BRICK)
	return {i32(f.x), i32(f.y), i32(f.z)}
}
