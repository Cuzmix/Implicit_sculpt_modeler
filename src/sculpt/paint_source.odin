package sculpt

import "core:math/linalg"

import "../geom"
import "../jobs"

// Where the Paint brush's colour comes from (Brush.source), after Photoshop's and
// Substance Painter's smudge and clone tools and ZBrush's Spotlight: the brush's own
// colour, as always; the colours under it dragged along the stroke (Smudge); the
// surface a fixed way off (Clone); or the picture laid over the view, seen through the
// screen onto the surface (Stencil). Each paints colour alone, on the vertices or on a
// texture layer: roughness, metal and height stay as they are. The inverted brush still
// erases and Shift still blurs, whatever the source.
//
// Every source reads first and writes after, as Blur does: a dab finds what each vertex
// or texel moves toward from the paint as it was before the dab, then lays it, so no
// part of a dab reads what another part already changed and the result is the same on
// any number of threads.
Paint_Source :: enum u8 {
	Color,
	Smudge,
	Clone,
	Stencil,
}

// Smudge: the share of the colour under a dab the carried colour takes up after the dab,
// so a stroke drags paint a few radii before it runs out, as a finger does.
SMUDGE_PICKUP :: 0.35

// A picture seen through the view, for Stencil: where each point of the mesh shows on the
// screen (`clip`, the mesh's space to clip space), where that lands on the picture
// (`to_uv`, normalised device x and y and 1 to the picture's u and v, 0 to 1 across, v
// down), and the picture's pixels (RGBA, rows top down), taken grey when `grey`. A pixel's
// alpha times `opacity` is how much of it the dab lays.
Paint_Stencil :: struct {
	clip:    matrix[4, 4]f32,
	to_uv:   [2][3]f32,
	pixels:  []u8,
	size:    [2]int,
	grey:    bool,
	opacity: f32,
}

// The picture's colour where mesh point `p` shows, bilinear, and how much of it to lay (0
// to 1); false off the picture or behind the eye.
stencil_sample :: proc(st: ^Paint_Stencil, p: Vec3) -> (rgb: [3]f32, a: f32, ok: bool) {
	if st == nil || st.size.x <= 0 || st.size.y <= 0 || len(st.pixels) < st.size.x * st.size.y * 4 do return
	c := st.clip * [4]f32{p.x, p.y, p.z, 1}
	if c.w <= 1e-6 do return
	x, y := c.x / c.w, c.y / c.w
	u := st.to_uv[0][0] * x + st.to_uv[0][1] * y + st.to_uv[0][2]
	v := st.to_uv[1][0] * x + st.to_uv[1][1] * y + st.to_uv[1][2]
	if u < 0 || u >= 1 || v < 0 || v >= 1 do return
	fx, fy := u * f32(st.size.x) - 0.5, v * f32(st.size.y) - 0.5
	x0, y0 := int(linalg.floor(fx)), int(linalg.floor(fy))
	tx, ty := fx - f32(x0), fy - f32(y0)
	sum: [4]f32
	for dy in 0 ..= 1 do for dx in 0 ..= 1 {
		px, py := clamp(x0 + dx, 0, st.size.x - 1), clamp(y0 + dy, 0, st.size.y - 1)
		w := (tx if dx == 1 else 1 - tx) * (ty if dy == 1 else 1 - ty)
		q := st.pixels[(py * st.size.x + px) * 4:][:4]
		al := f32(q[3]) * w
		sum += {f32(q[0]) * al, f32(q[1]) * al, f32(q[2]) * al, al}
	}
	if sum.a <= 0 do return
	rgb = sum.rgb / sum.a
	if st.grey do rgb = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
	return rgb, clamp(sum.a / 255 * st.opacity, 0, 1), true
}

// Whether a Paint dab of `brush` lays a source's colour rather than its own.
@(private)
paint_sourced :: #force_inline proc(brush: Brush) -> bool {
	return brush.kind == .Paint && brush.source != .Color && !brush.blur && !brush.invert
}

// What one vertex or texel of a dab moves toward under a source: `color`, all four values
// (Smudge, Clone), or `color`'s rgb laid by `color.a` of the weight (Stencil). `ok` false
// leaves it as it is.
@(private)
Source_Target :: struct {
	color: [4]f32,
	ok:    bool,
}

// One dab's colour from a source, laid over colour `c` with weight `w`.
@(private)
source_lay :: #force_inline proc(c: Color, target: [4]f32, w: f32, stencil: bool) -> Color {
	if stencil do return paint_mix(c, {u8(clamp(target.r + 0.5, 0, 255)), u8(clamp(target.g + 0.5, 0, 255)), u8(clamp(target.b + 0.5, 0, 255))}, w * target.a, false)
	// Bare clay as the target takes coverage off and keeps the colour, as Erase does, so
	// the paint thins out with no dark fringe.
	target := target
	if target.a < 0.5 do target.rgb = {f32(c.r), f32(c.g), f32(c.b)}
	next: Color
	for k in 0 ..< 4 do next[k] = paint_toward(c[k], u8(clamp(target[k] + 0.5, 0, 255)), f32(c[k]) + (target[k] - f32(c[k])) * w)
	return next
}

// Clone's colour at the surface nearest `q` (the vertex's place moved by the offset),
// facing the way `n` does so a thin part reads its own side: the picked layer's colours
// at that triangle's corners, blended.
@(private)
clone_vertex_color :: proc(s: ^Sculptor, q, n: Vec3, reach: f32, hint: u32) -> (c: [4]f32, tri: u32, ok: bool) {
	bary: [3]f32
	tri, bary, _, ok = geom.bvh_closest(s.bvh, s.mesh^, q, reach, hint, n)
	if !ok do return
	idx := s.mesh.indices[3 * tri:][:3]
	for k in 0 ..< 3 {
		x := s.color[idx[k]]
		c += [4]f32{f32(x.r), f32(x.g), f32(x.b), f32(x.a)} * bary[k]
	}
	return
}

// Where a dab's image `brush` finds the stencil: the vertex's place turned back to the dab
// it mirrors, so each image lays the picture the stroke's own dab sees.
@(private)
stencil_point :: #force_inline proc(brush: Brush, p: Vec3) -> Vec3 {
	return brush.sym_center + brush.image_back * (p - brush.sym_center)
}

// One sourced Paint dab on the vertices (paint_dab): every vertex in reach finds its
// target first (a Smudge dab also sums the colours under it), then each is laid. Leaves
// each leaf's count of changed vertices in the partials, as job_paint does.
@(private)
paint_source_dab :: proc(s: ^Sculptor, d: ^Dab, pool: ^jobs.Pool) {
	for &p in s.partials do p.moved = 0
	resize(&s.offsets, len(s.hit))
	total: u32
	for leaf, i in s.hit {
		s.offsets[i] = total
		total += s.nodes[s.node_of[leaf]].vert_count
	}
	Job :: struct {
		s:       ^Sculptor,
		d:       ^Dab,
		targets: []Source_Target,
		sums:    [][5]f32, // Smudge, per leaf: rgb·a·w, a·w, w
		carry:   [4]f32,
	}
	job := Job{s = s, d = d, targets = make([]Source_Target, int(total), context.temp_allocator), sums = make([][5]f32, len(s.hit), context.temp_allocator)}
	jobs.parallel_for(pool, len(s.hit), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		s, d := job.s, job.d
		m := s.mesh
		first, last := owned(s, s.hit[i])
		out := job.targets[job.d.s.offsets[i]:]
		hint := geom.BVH_NONE
		reach := 2 * linalg.sqrt(d.r2) + linalg.length(d.brush.clone_offset)
		sum: [5]f32
		for v in first ..< last {
			delta := m.positions[v] - d.center
			d2 := linalg.dot(delta, delta)
			if d2 >= d.r2 do continue
			w := d.brush.strength * dab_weight(d, delta, d2) * facing_weight(d, m.normals[:], v) * shield(s.fade, s.mask, v)
			if w <= 0 do continue
			t := &out[v - first]
			switch d.brush.source {
			case .Color:
			case .Smudge:
				c := s.color[v]
				a := f32(c.a) * w
				sum += {f32(c.r) * a, f32(c.g) * a, f32(c.b) * a, a, w}
				t.ok = true
			case .Clone:
				tri: u32
				t.color, tri, t.ok = clone_vertex_color(s, m.positions[v] + d.brush.clone_offset, m.normals[v], reach, hint)
				if t.ok do hint = tri
			case .Stencil:
				rgb, a, ok := stencil_sample(d.brush.stencil, stencil_point(d.brush, m.positions[v]))
				t.color, t.ok = {rgb.r, rgb.g, rgb.b, a}, ok
			}
		}
		job.sums[i] = sum
	})
	if d.brush.source == .Smudge {
		if !smudge_carry(s, d.brush.image, job.sums) do return
		job.carry = s.smudge[d.brush.image]
	}
	jobs.parallel_for(pool, len(s.hit), &job, proc(data: rawptr, i: int) {
		job := cast(^Job)data
		s, d := job.s, job.d
		m := s.mesh
		first, last := owned(s, s.hit[i])
		targets := job.targets[s.offsets[i]:]
		painted: u32
		for v in first ..< last {
			t := targets[v - first]
			if !t.ok do continue
			delta := m.positions[v] - d.center
			d2 := linalg.dot(delta, delta)
			w := d.brush.strength * dab_weight(d, delta, d2) * facing_weight(d, m.normals[:], v) * shield(s.fade, s.mask, v)
			target := job.carry if d.brush.source == .Smudge else t.color
			next := source_lay(s.color[v], target, clamp(w, 0, 1), d.brush.source == .Stencil)
			if next == s.color[v] do continue
			s.color[v] = next
			painted += 1
		}
		s.partials[i].moved = painted
	})
	if d.brush.source == .Smudge do smudge_pick_up(s, d.brush.image, job.sums)
}

// The colour a Smudge stroke drags for dab image `image`: the first dab of a stroke picks
// up the colour under it and lays nothing (false). Partial sums are added in leaf order,
// so the carry is the same on any number of threads.
@(private)
smudge_carry :: proc(s: ^Sculptor, image: int, sums: [][5]f32) -> bool {
	if image < 0 || image >= len(s.smudge) do return false
	if s.smudge_stroke[image] == s.layer_stroke do return true
	under, ok := smudge_under(sums)
	if !ok do return false
	s.smudge[image], s.smudge_stroke[image] = under, s.layer_stroke
	return false
}

// After a Smudge dab, its carried colour takes up SMUDGE_PICKUP of what was under it.
@(private)
smudge_pick_up :: proc(s: ^Sculptor, image: int, sums: [][5]f32) {
	under, ok := smudge_under(sums)
	if !ok || image < 0 || image >= len(s.smudge) do return
	s.smudge[image] += (under - s.smudge[image]) * SMUDGE_PICKUP
}

// The colour under a dab from its partial sums: rgb as far as each covers, the coverage
// averaged over the dab's weight, so bare clay picks up as clearness.
@(private)
smudge_under :: proc(sums: [][5]f32) -> (c: [4]f32, ok: bool) {
	total: [5]f32
	for x in sums do total += x
	if total[4] <= 0 do return
	c.a = total[3] / total[4]
	if total[3] > 0 do c.rgb = [3]f32{total[0], total[1], total[2]} / total[3]
	return c, true
}
