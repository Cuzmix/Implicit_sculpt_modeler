package voxel

import "core:math"
import "core:math/linalg"
import "core:testing"

import "../geom"

// A planted saddle face (two inside corners on a diagonal) is resolved with one flip, of
// the inside corner nearer the surface, to a hair outside; the pass then finds nothing.
@(test)
a_planted_saddle_is_flipped_once_at_the_nearer_corner :: proc(t: ^testing.T) {
	c: Clay
	clay_init(&c, 0.01, {}, nil)
	defer clay_destroy(&c)
	bc := [3]i32{300, 300, 300}
	slot, b := volume_brick_make(&c.volume, bc, CLAMP)
	b.d[voxel_index(3, 3, 3)] = -SCALE
	b.d[voxel_index(4, 4, 3)] = -SCALE / 2
	slots := [1]u32{slot}
	testing.expect_value(t, resolve_saddles(&c, slots[:], false), 1)
	testing.expect_value(t, b.d[voxel_index(3, 3, 3)], -SCALE)
	testing.expect_value(t, b.d[voxel_index(4, 4, 3)], SADDLE_FLIP)
	testing.expect_value(t, resolve_saddles(&c, slots[:], false), 0)
	// The brick waits for the band repair and its nodes for the mesh.
	testing.expect_value(t, len(c.pending), 1)
	testing.expect(t, len(c.surface.dirty) > 0, "no node marked")
	// A tie goes to the lower coordinate.
	b.d[voxel_index(3, 3, 3)] = -SCALE
	b.d[voxel_index(4, 4, 3)] = -SCALE
	testing.expect_value(t, resolve_saddles(&c, slots[:], false), 1)
	testing.expect_value(t, b.d[voxel_index(3, 3, 3)], SADDLE_FLIP)
	testing.expect_value(t, b.d[voxel_index(4, 4, 3)], -SCALE)
}

// A sheet under a voxel thick on a diagonal is a saddle on every face it crosses; the pass
// dissolves what it must and what is left meshes closed with no non-manifold edge.
@(test)
a_thin_diagonal_sheet_meshes_without_a_non_manifold_edge :: proc(t: ^testing.T) {
	c: Clay
	clay_init(&c, 0.01, {}, nil)
	defer clay_destroy(&c)
	// The sheet |x + y − 4100| / √2 < 0.4 voxels through (2050, 2050), x and y within 9 of
	// it, z within 7 of 2048, with its ends and sides capped by the box.
	for bz in 255 ..= 256 do for by in 254 ..= 257 do for bx in 254 ..= 257 {
		bc := [3]i32{i32(bx), i32(by), i32(bz)}
		_, b := volume_brick_make(&c.volume, bc, CLAMP)
		for z in 0 ..< BRICK do for y in 0 ..< BRICK do for x in 0 ..< BRICK {
			g := bc * BRICK + {i32(x), i32(y), i32(z)}
			sheet := abs(f32(g.x + g.y) - 4100) / math.SQRT_TWO - 0.4
			box := max(abs(f32(g.x) - 2050) - 9, abs(f32(g.y) - 2050) - 9, abs(f32(g.z) - 2048) - 7)
			b.d[voxel_index(x, y, z)] = quantize(max(sheet, box))
		}
	}
	flips := resolve_saddles(&c, volume_slots(&c.volume, context.temp_allocator), false)
	testing.expect(t, flips > 0, "a diagonal sheet planted no saddle")
	band_repair(&c)
	surface_mark_all(&c)
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.non_manifold_edges == 0 && r.boundary_edges == 0 && r.inconsistent_edges == 0, "%v", r)
}

// Strokes of every brush, strong and overlapping, leave a surface that is closed and
// manifold: every edge in two triangles, run once each way.
@(test)
strokes_of_every_brush_keep_the_surface_manifold :: proc(t: ^testing.T) {
	c: Clay
	clay_init(&c, 2.0 / 96, {}, nil)
	defer clay_destroy(&c)
	clay_fill_sphere(&c, {}, 1)
	for kind in Brush_Kind {
		for invert in ([2]bool{false, true}) {
			clay_stroke_begin(&c)
			for i in 0 ..< 24 {
				a := f32(i) * 0.7
				at := Vec3{math.cos(a), math.sin(a) * 0.6, math.sin(a * 1.3)}
				at = linalg.normalize(at) * (1 + 0.08 * math.sin(a * 2.1))
				_ = clay_dab(&c, {kind = kind, radius = 0.18, strength = 1, invert = invert, normal = linalg.normalize(at)}, at)
			}
			_ = clay_stroke_end(&c)
		}
	}
	m := clay_to_mesh(&c)
	defer geom.mesh_destroy(&m)
	r := geom.mesh_check(m)
	testing.expectf(t, r.closed && r.non_manifold_edges == 0 && r.inconsistent_edges == 0 && !r.inverted, "%v", r)
}
