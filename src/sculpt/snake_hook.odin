package sculpt

import "core:math"
import "core:math/linalg"

import "../geom"

// One hit leaf of a Snake hook dab: what lies under the brush is dragged by Brush.drag
// times its falloff (or with the Elastic tip, by the Kelvinlet out to its reach), then
// pinched toward the line the hook is pulled along and turned with the hook's rake, as
// Blender's snake hook does.
@(private)
job_snake_hook :: proc(data: rawptr, i: int) {
	d := cast(^Dab)data
	s := d.s
	m := s.mesh
	b := &d.brush
	first, last := owned(s, s.hit[i])
	fade, mask := s.fade, s.mask
	rake := b.hook_rake * b.rake_angle
	moved: u32
	bounds := geom.AABB_EMPTY
	for v in first ..< last {
		p := m.positions[v]
		delta := p - d.center
		d2 := linalg.dot(delta, delta)
		if d2 < d.r2 {
			// The falloff, which pinch and rake take too; the Elastic tip reaches past the
			// ring, where it has none.
			move: Vec3
			w: f32
			if b.hook_elastic {
				guard := shield(fade, mask, v) * facing_weight(d, m.normals[:], v)
				if guard > 0 do move = kelvinlet_follow(&d.kelvin, delta) * b.drag * guard
				if d2 * d.inv_r2 < 1 do w = dab_weight(d, delta, d2) * guard
			} else {
				w = dab_weight(d, delta, d2) * shield(fade, mask, v) * facing_weight(d, m.normals[:], v)
				if w > 0 do move = b.drag * w
			}
			if w > 0 && d.pinch != 0 {
				// Measured from where the hook has got to, across the way it pulls.
				across := delta + b.drag
				across -= d.drag_dir * linalg.dot(across, d.drag_dir)
				k := d.pinch * w
				// Drawn in less the nearer the line, so the tip never pinches to nothing.
				if k > 0 do k *= math.pow(min(1, linalg.length(across) / b.radius), 2)
				move -= across * k
			}
			if w > 0 && rake != 0 do move += rotate_about(delta, b.rake_axis, rake * w) - delta
			if w > 0 || move != {} {
				p += move
				m.positions[v] = p
				moved += 1
			}
		}
		geom.aabb_grow(&bounds, p)
	}
	s.partials[i].moved = moved
	s.partials[i].bounds = bounds
}

// `v` turned by `angle` radians about the unit `axis` (Rodrigues' formula).
@(private)
rotate_about :: #force_inline proc(v, axis: Vec3, angle: f32) -> Vec3 {
	c, sn := math.cos(angle), math.sin(angle)
	return v * c + linalg.cross(axis, v) * sn + axis * (linalg.dot(axis, v) * (1 - c))
}
