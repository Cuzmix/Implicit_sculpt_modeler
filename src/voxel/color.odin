package voxel

import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../jobs"

// Colour on clay, as 3D-Coat's voxel paint and Medium's colour: a brick may carry a colour
// brick beside its mask brick, an sRGB colour and a painted weight a voxel (weight 0 is
// unpainted, where the object's material shows). The Paint brush moves the colour of the
// voxels under it towards its own and leaves the field alone, so a paint stroke needs no
// repair; each surface vertex samples the colour where it stands, weighted, and the app
// uploads it as a mesh's polypaint. A brick that collapses to a tile drops its colour, as it
// drops its mask: a tile lies a band or more from the surface, where no paint shows.

COLOR_NONE :: max(u32)

Color_Brick :: struct {
	c: [BRICK_VOXELS][4]u8, // sRGB, then the painted weight
}

// The brick slot `slot`'s colour, or nil when it has none.
color_of :: #force_inline proc(v: ^Volume, slot: u32) -> ^Color_Brick {
	if int(slot) >= len(v.colors) do return nil
	if k := v.colors[slot]; k != COLOR_NONE do return &v.color_bricks[k]
	return nil
}

// Brick slot `slot`'s colour, made unpainted if it had none.
color_make :: proc(v: ^Volume, slot: u32) -> ^Color_Brick {
	if c := color_of(v, slot); c != nil do return c
	k: u32
	if len(v.color_free) > 0 {
		k = pop(&v.color_free)
		v.color_bricks[k] = {}
	} else {
		k = u32(len(v.color_bricks))
		append(&v.color_bricks, Color_Brick{})
	}
	v.colors[slot] = k
	return &v.color_bricks[k]
}

// Drops brick slot `slot`'s colour, if it has one.
@(private)
color_drop :: proc(v: ^Volume, slot: u32) {
	if int(slot) >= len(v.colors) do return
	if k := v.colors[slot]; k != COLOR_NONE {
		append(&v.color_free, k)
		v.colors[slot] = COLOR_NONE
	}
}

// Whether any voxel of the clay is painted.
clay_has_color :: proc(c: ^Clay) -> bool {
	v := &c.volume
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		b := color_of(v, u32(slot))
		if b == nil do continue
		for x in b.c do if x[3] != 0 do return true
	}
	return false
}

// The colour at voxel `g`: its brick's, or unpainted on a tile and outside the domain.
color_value :: proc(v: ^Volume, g: [3]i32) -> [4]u8 {
	if g.x < 0 || g.y < 0 || g.z < 0 do return {}
	bc := shr3(g, 3) // BRICK is 8
	if !brick_in_domain(bc) do return {}
	slot := volume_slot(v, bc)
	if slot == TILE_EMPTY || slot == TILE_INSIDE do return {}
	b := color_of(v, slot)
	if b == nil do return {}
	l := and3(g, BRICK - 1)
	return b.c[voxel_index(int(l.x), int(l.y), int(l.z))]
}

// Whether the clay holds any colour brick (painted or since erased): a check of two counts,
// for the frame to tell whether the surface's colours need uploading.
clay_colored :: #force_inline proc(c: ^Clay) -> bool {
	return len(c.volume.color_bricks) > len(c.volume.color_free)
}

// Bytes the colours take: the colour bricks (free ones included) and the slot table.
color_bytes :: proc(v: ^Volume) -> int {
	return len(v.color_bricks) * size_of(Color_Brick) + len(v.colors) * size_of(u32)
}

// Applies a Paint dab to brick `bc`'s colour `b`: each voxel within the brush moves towards
// the brush's colour (inverted: its weight towards unpainted) by the falloff times the
// strength, less what the mask holds. The box is of every voxel that changed, since the
// colour shows wherever the surface passes.
dab_paint_brick :: proc(d: ^Dab, bc: [3]i32, b: ^Color_Brick, mask: ^Mask_Brick) -> (e: Dab_Effect) {
	e.lo, e.hi = {BRICK, BRICK, BRICK}, {-1, -1, -1}
	p0 := Vec3{f32(bc.x), f32(bc.y), f32(bc.z)} * BRICK
	inv_r2 := 1 / (d.radius * d.radius)
	want := [3]f32{f32(d.color.r), f32(d.color.g), f32(d.color.b)}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		p := p0 + {f32(x), f32(y), f32(z)}
		delta := p - d.centre
		w := falloff(linalg.dot(delta, delta) * inv_r2) * d.strength
		if w == 0 do continue
		i := voxel_index(x, y, z)
		if mask != nil do w *= 1 - f32(mask.m[i]) / 255
		if w <= 0 do continue
		was := b.c[i]
		now := was
		if d.invert {
			now[3] = u8(math.max(f32(was[3]) - 255 * w, 0) + 0.5)
		} else {
			// Unpainted voxels take the colour outright; painted ones blend towards it.
			from := [3]f32{f32(was.r), f32(was.g), f32(was.b)} if was[3] != 0 else want
			mixed := linalg.lerp(from, want, w)
			now = {u8(mixed.r + 0.5), u8(mixed.g + 0.5), u8(mixed.b + 0.5), u8(math.min(f32(was[3]) + 255 * w, 255) + 0.5)}
		}
		// An unpainted voxel holds no colour, so equal paint is equal bits (the file packs it so).
		if now[3] == 0 do now = {}
		if now == was do continue
		b.c[i] = now
		e.lo = linalg.min(e.lo, [3]i8{i8(x), i8(y), i8(z)})
		e.hi = linalg.max(e.hi, [3]i8{i8(x), i8(y), i8(z)})
		e.changed = true
	}
	return
}

// Copies the colours of the n³ voxels from `lo` into `out` (unpainted where a brick has
// none), as gather_mask_window does the mask.
@(private)
gather_color_window :: proc(v: ^Volume, lo: [3]i32, n: int, out: [][4]u8) {
	assert(len(out) == n * n * n, "window size")
	slice.zero(out)
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3)
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		if !brick_in_domain(bc) do continue
		slot := volume_slot(v, bc)
		if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
		m := color_of(v, slot)
		if m == nil do continue
		base := bc * BRICK
		l := linalg.max(lo - base, [3]i32{0, 0, 0})
		h := linalg.min(hi - base, [3]i32{BRICK - 1, BRICK - 1, BRICK - 1})
		if l.x > h.x || l.y > h.y || l.z > h.z do continue
		for z in l.z ..= h.z do for y in l.y ..= h.y {
			row := (int(base.z + z - lo.z) * n + int(base.y + y - lo.y)) * n + int(base.x - lo.x)
			src := voxel_index(int(l.x), int(y), int(z))
			copy(out[row + int(l.x):row + int(h.x) + 1], m.c[src:src + int(h.x - l.x) + 1])
		}
	}
}

// Whether any brick under the n³ voxels from `lo` has a colour.
@(private)
volume_colored_over :: proc(v: ^Volume, lo: [3]i32, n: int) -> bool {
	hi := lo + i32(n - 1)
	blo, bhi := shr3(lo, 3), shr3(hi, 3)
	for bz in blo.z ..= bhi.z do for by in blo.y ..= bhi.y do for bx in blo.x ..= bhi.x {
		bc := [3]i32{bx, by, bz}
		if !brick_in_domain(bc) do continue
		slot := volume_slot(v, bc)
		if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
		if color_of(v, slot) != nil do return true
	}
	return false
}

// The colour at a point between eight voxels (`corners` in x, then y, then z order, `t`
// the point's place in the cell): the painted ones' colour weighted by their weight, and
// the weight trilinear, so an unpainted corner thins the paint without greying it.
@(private)
color_trilinear :: proc(corners: [8][4]u8, t: Vec3) -> [4]u8 {
	sum: [3]f32
	weight, total: f32
	for k in 0 ..< 8 {
		wx := t.x if k & 1 != 0 else 1 - t.x
		wy := t.y if k >> 1 & 1 != 0 else 1 - t.y
		wz := t.z if k >> 2 & 1 != 0 else 1 - t.z
		a := f32(corners[k][3]) * wx * wy * wz
		sum += [3]f32{f32(corners[k].r), f32(corners[k].g), f32(corners[k].b)} * a
		weight += a
		total += wx * wy * wz
	}
	if weight <= 0 do return {}
	rgb := sum / weight
	return {u8(rgb.r + 0.5), u8(rgb.g + 0.5), u8(rgb.b + 0.5), u8(math.min(weight / total, 255) + 0.5)}
}

// The most bytes a packed colour's runs may take before the raw colour is written instead.
@(private)
COLOR_RAW :: size_of(Color_Brick)

// Appends the colour as runs (a count of 1 to 255, then the four bytes), or raw, after
// their byte count (0 for raw), as pack_mask does the mask. An unpainted voxel's colour is
// written as zeros, whatever it held, so it joins its neighbours' run.
pack_color :: proc(out: ^[dynamic]u8, b: ^Color_Brick) {
	start := len(out)
	geom.byte_put(out, u16(0))
	at :: proc(b: ^Color_Brick, i: int) -> [4]u8 {return b.c[i] if b.c[i][3] != 0 else {}}
	i := 0
	for i < BRICK_VOXELS && len(out) - start - 2 < COLOR_RAW {
		x := at(b, i)
		j := i + 1
		for j < BRICK_VOXELS && at(b, j) == x && j - i < 255 do j += 1
		append(out, u8(j - i), x[0], x[1], x[2], x[3])
		i = j
	}
	size := len(out) - start - 2
	if size >= COLOR_RAW {
		resize(out, start + 2)
		geom.byte_put_slice(out, b.c[:])
		return
	}
	out[start], out[start + 1] = u8(size), u8(size >> 8)
}

// Reads a colour written by pack_color into `b`; false when the bytes are not one.
unpack_color :: proc(r: ^geom.Byte_Reader, b: ^Color_Brick) -> bool {
	size := int(geom.byte_get(r, u16))
	if !r.ok do return false
	if size == 0 {
		geom.byte_get_slice(r, b.c[:])
		return r.ok
	}
	s := geom.byte_get_bytes(r, size)
	if s == nil || size % 5 != 0 do return false
	n := 0
	for at := 0; at < size; at += 5 {
		count := int(s[at])
		if count == 0 || n + count > BRICK_VOXELS do return false
		for _ in 0 ..< count {
			b.c[n] = {s[at + 1], s[at + 2], s[at + 3], s[at + 4]}
			n += 1
		}
	}
	return n == BRICK_VOXELS
}

// What clay_paint_command does to the whole clay's colour, as the mesh's Paint commands.
Paint_Op :: enum {
	Fill, // the colour everywhere the surface can show it
	Clear, // the paint off
	Gradient, // from the colour to the second one along an axis
}

// The bricks clay_paint_command works out at once before committing them: the colour
// scratch stays 2 MiB however large the clay.
@(private = "file")
PAINT_BATCH :: 1024

@(private = "file")
Paint_Run :: struct {
	c:             ^Clay,
	op:            Paint_Op,
	color, color2: [3]f32,
	axis:          Vec3,
	lo, span:      f32, // the gradient's start and length along the axis
}

// Fills the clay's band with `color`, or with a gradient from it to `color2` along the
// object-space direction `axis` (the colour where the clay is least along it), or takes the
// paint off, each voxel by its unmasked share, as one undo step. Only voxels within the
// band take paint, since no surface reaches the others. The bricks are worked out in
// parallel a batch at a time and committed serially, so any thread count gives the same
// colours. Returns whether anything changed.
clay_paint_command :: proc(c: ^Clay, op: Paint_Op, color, color2: [3]u8, axis: Vec3 = {}) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	v := &c.volume
	if op == .Clear && !clay_colored(c) do return false
	run := Paint_Run{c = c, op = op, color = {f32(color.r), f32(color.g), f32(color.b)}, color2 = {f32(color2.r), f32(color2.g), f32(color2.b)}, axis = axis}
	if op == .Gradient {
		// The gradient's span: the clay's extent along the axis.
		b := volume_bounds(v)
		run.lo = max(f32)
		hi := -max(f32)
		for k in 0 ..< 8 {
			corner := Vec3{b.lo.x if k & 1 == 0 else b.hi.x, b.lo.y if k & 2 == 0 else b.hi.y, b.lo.z if k & 4 == 0 else b.hi.z}
			run.lo, hi = min(run.lo, linalg.dot(corner, axis)), max(hi, linalg.dot(corner, axis))
		}
		run.span = max(hi - run.lo, 1e-6)
	}
	clay_stroke_begin(c)
	clear(&c.jobs)
	commit :: proc(c: ^Clay, run: ^Paint_Run) {
		resize(&c.color_scratch, len(c.jobs))
		jobs.parallel_for(c.pool, len(c.jobs), run, proc(data: rawptr, i: int) {
			r := cast(^Paint_Run)data
			job := &r.c.jobs[i]
			job.color_changed, job.color_painted = paint_op_brick(r, job.slot, &r.c.color_scratch[i])
		})
		v := &c.volume
		for job, i in c.jobs {
			if !job.color_changed do continue
			undo_record(&c.history, v, job.coord)
			if job.color_painted do color_make(v, job.slot)^ = c.color_scratch[i]
			else do color_drop(v, job.slot)
			surface_mark_brick(c, job.coord)
		}
		clear(&c.jobs)
	}
	for coord, slot in v.coords {
		if coord == BRICK_FREE do continue
		if op == .Clear && color_of(v, u32(slot)) == nil do continue
		append(&c.jobs, Dab_Job{slot = u32(slot), coord = coord})
		if len(c.jobs) == PAINT_BATCH do commit(c, &run)
	}
	commit(c, &run)
	c.in_stroke = false
	return undo_end(&c.history)
}

// Brick slot `slot`'s colour after clay_paint_command's op, into `out`: whether it differs
// from the brick's colour now and whether any of it is painted.
@(private = "file")
paint_op_brick :: proc(r: ^Paint_Run, slot: u32, out: ^Color_Brick) -> (changed, painted: bool) {
	LIMIT :: i16(BAND * SCALE)
	v := &r.c.volume
	coord := v.coords[slot]
	live := color_of(v, slot)
	mask := mask_of(v, slot)
	b := &v.bricks[slot]
	if live != nil do out^ = live^
	else do out^ = {}
	for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
		k := voxel_index(x, y, z)
		w: f32 = 1
		if mask != nil do w = 1 - f32(mask.m[k]) / 255
		if w <= 0 do continue
		was := out.c[k]
		if r.op == .Clear {
			now := was
			now[3] = u8(math.max(f32(was[3]) - 255 * w, 0) + 0.5)
			out.c[k] = now if now[3] != 0 else {}
			continue
		}
		if abs(b.d[k]) > LIMIT do continue
		want := r.color
		if r.op == .Gradient {
			t := clamp((linalg.dot(voxel_centre(v, coord * BRICK + {i32(x), i32(y), i32(z)}), r.axis) - r.lo) / r.span, 0, 1)
			want = linalg.lerp(want, r.color2, t)
		}
		from := [3]f32{f32(was.r), f32(was.g), f32(was.b)} if was[3] != 0 else want
		mixed := linalg.lerp(from, want, w)
		out.c[k] = {u8(mixed.r + 0.5), u8(mixed.g + 0.5), u8(mixed.b + 0.5), u8(math.min(f32(was[3]) + 255 * w, 255) + 0.5)}
	}
	for x in out.c do if x[3] != 0 {
		painted = true
		break
	}
	changed = live.c != out.c if live != nil else painted
	return
}

// Lays a mesh's per-vertex paint (`colors`, sRGB and a painted weight, as the clay's) onto
// clay made from it (clay_from_mesh, in the mesh's space): each voxel of the band near the
// surface takes the colour of the nearest of points laid a voxel apart over the mesh's
// triangles, each blended from its triangle's corners, so a coarse mesh's paint lands as
// smoothly as a dense one's. Triangles with paint go first and make colour bricks; the
// unpainted ones then only claim voxels in bricks that have one, so a painted edge stops
// where the mesh's paint does. Serial, so the same on any machine. No undo step: it is
// for clay just made. Returns whether any paint landed.
clay_paint_from_mesh :: proc(c: ^Clay, m: geom.Mesh, colors: [][4]u8) -> bool {
	assert(!c.in_stroke, "a stroke is running")
	if len(colors) != len(m.positions) do return false
	any_paint := false
	for x in colors do if x[3] != 0 {
		any_paint = true
		break
	}
	if !any_paint do return false
	v := &c.volume
	heap := runtime.heap_allocator()
	// The nearest sample's squared distance per voxel of each colour brick made here, by
	// brick slot (-1: none made here).
	near := make([]i32, len(v.bricks), heap)
	defer delete(near, heap)
	slice.fill(near, -1)
	dist := make([dynamic][BRICK_VOXELS]f32, heap)
	defer delete(dist)
	LIMIT :: i16(BAND * SCALE)
	for pass in 0 ..< 2 {
		for t := 0; t + 2 < len(m.indices); t += 3 {
			k := [3]u32{m.indices[t], m.indices[t + 1], m.indices[t + 2]}
			painted := colors[k[0]][3] != 0 || colors[k[1]][3] != 0 || colors[k[2]][3] != 0
			if painted != (pass == 0) do continue
			a := voxel_coords(v, m.positions[k[0]])
			b := voxel_coords(v, m.positions[k[1]])
			e := voxel_coords(v, m.positions[k[2]])
			// An unpainted triangle matters only next to the paint: is any brick its
			// samples reach a colour brick made here?
			if !painted {
				lo := brick_floor(linalg.min(a, linalg.min(b, e)) - 2)
				hi := brick_floor(linalg.max(a, linalg.max(b, e)) + 2)
				reaches := false
				for z in lo.z ..= hi.z do for y in lo.y ..= hi.y do for x in lo.x ..= hi.x {
					bc := [3]i32{x, y, z}
					if !brick_in_domain(bc) do continue
					slot := volume_slot(v, bc)
					if slot != TILE_EMPTY && slot != TILE_INSIDE && near[slot] >= 0 do reaches = true
				}
				if !reaches do continue
			}
			// A point a voxel apart, at most, along both edges from the first corner.
			n := max(int(math.ceil(max(linalg.length(b - a), linalg.length(e - a), linalg.length(e - b)))), 1)
			for i in 0 ..= n do for j in 0 ..= n - i {
				u, w := f32(i) / f32(n), f32(j) / f32(n)
				q := a + (b - a) * u + (e - a) * w
				bary := [3]f32{1 - u - w, u, w}
				col: [4]u8
				if painted {
					rgb: [3]f32
					weight: f32
					for corner in 0 ..< 3 {
						x := colors[k[corner]]
						s := f32(x[3]) * bary[corner]
						rgb += [3]f32{f32(x.r), f32(x.g), f32(x.b)} * s
						weight += s
					}
					if weight > 0 {
						rgb /= weight
						col = {u8(rgb.r + 0.5), u8(rgb.g + 0.5), u8(rgb.b + 0.5), u8(math.min(weight, 255) + 0.5)}
					}
				}
				r := linalg.round(q)
				centre := [3]i32{i32(r.x), i32(r.y), i32(r.z)}
				for dz in i32(-1) ..= 1 do for dy in i32(-1) ..= 1 do for dx in i32(-1) ..= 1 {
					g := centre + {dx, dy, dz}
					if g.x < 0 || g.y < 0 || g.z < 0 do continue
					bc := shr3(g, 3)
					if !brick_in_domain(bc) do continue
					slot := volume_slot(v, bc)
					if slot == TILE_EMPTY || slot == TILE_INSIDE do continue
					l := and3(g, BRICK - 1)
					vi := voxel_index(int(l.x), int(l.y), int(l.z))
					if abs(v.bricks[slot].d[vi]) > LIMIT do continue
					at := int(near[slot])
					if at < 0 {
						// Only painted samples start a colour brick.
						if pass == 1 || color_of(v, slot) != nil do continue
						at = len(dist)
						append(&dist, [BRICK_VOXELS]f32{})
						for &x in dist[at] do x = max(f32)
						near[slot] = i32(at)
						_ = color_make(v, slot)
					}
					d := linalg.length2(Vec3{f32(g.x), f32(g.y), f32(g.z)} - q)
					if d >= dist[at][vi] do continue
					dist[at][vi] = d
					color_of(v, slot).c[vi] = col
				}
			}
		}
	}
	surface_mark_all(c)
	return true
}

// The clay's colour at object-space point `p` (on its surface, as a raycast finds it), as a
// surface vertex there would show it: sRGB and the painted weight, zero where unpainted.
clay_color_at :: proc(c: ^Clay, p: Vec3) -> [4]u8 {
	if !clay_colored(c) do return {}
	v := &c.volume
	q := voxel_coords(v, p)
	f := linalg.floor(q)
	g := [3]i32{i32(f.x), i32(f.y), i32(f.z)}
	corners: [8][4]u8
	for k in 0 ..< 8 do corners[k] = color_value(v, g + {i32(k & 1), i32(k >> 1 & 1), i32(k >> 2 & 1)})
	return color_trilinear(corners, q - f)
}
