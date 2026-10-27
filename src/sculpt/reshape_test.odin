package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

// A sphere with its bottom fully masked, reshaped by `r` (bounds filled in) as one pose
// left open; returns where it began.
@(private = "file")
reshape_on :: proc(t: ^testing.T, s: ^Sculptor, r: Reshape) -> []Vec3 {
	before := slice.clone(s.mesh.positions[:], context.temp_allocator)
	lo, hi, ok := sculptor_free_bounds(s)
	testing.expect(t, ok)
	r := r
	r.lo, r.hi = lo, hi
	testing.expect(t, sculptor_pose_begin(s))
	sculptor_pose_apply(s, {kind = .Reshape, reshape = r})
	return before
}

// An icosphere with each vertex's radius off by up to 2.5 %, by a hash of its index.
@(private = "file")
bumpy_sphere :: proc(level: int) -> geom.Mesh {
	m := geom.icosphere(level)
	for &p, v in m.positions {
		h := u32(v) * 2654435761
		h ~= h >> 15
		p *= 1 + 0.05 * (f32(h & 0xffff) / 0xffff - 0.5)
	}
	return m
}

@(private = "file")
masked_sphere :: proc(m: ^geom.Mesh, s: ^Sculptor, pool: ^jobs.Pool) {
	m^ = geom.icosphere(4)
	sculptor_init(s, m, pool, 64)
	sculptor_recompute_all(s)
	mask_ensure(s)
	for p, v in m.positions do if p.z < -0.5 do s.mask[v] = 255
}

// Every kind leaves the masked part exactly where it was, moves the free part, gives the
// same bits on one thread and several, and undoes to the bit; at 0 it moves nothing.
@(test)
reshape_kinds_keep_the_mask_and_agree_in_parallel :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	for kind in Reshape_Kind {
		axes := bit_set[Axis]{.Y} if reshape_one_axis(kind) else bit_set[Axis]{.X, .Y}
		r := Reshape{kind = kind, axes = axes, amount = 0.3}
		ms, mp: geom.Mesh
		ss, sp: Sculptor
		masked_sphere(&ms, &ss, nil)
		masked_sphere(&mp, &sp, &pool)
		before := reshape_on(t, &ss, r)
		_ = reshape_on(t, &sp, r)
		testing.expectf(t, slice.equal(ms.positions[:], mp.positions[:]), "%v: serial and parallel differ", kind)
		moved := false
		for p, v in ms.positions {
			if ss.mask[v] == 255 do testing.expectf(t, p == before[v], "%v moved a masked vertex", kind)
			moved ||= p != before[v]
		}
		testing.expectf(t, moved, "%v moved nothing", kind)
		testing.expect(t, sculptor_pose_end(&ss))
		testing.expect(t, sculptor_undo(&ss))
		testing.expectf(t, slice.equal(ms.positions[:], before), "%v: undo is not exact", kind)
		// At 0 nothing moves.
		r.amount = 0
		_ = reshape_on(t, &ss, r)
		testing.expectf(t, slice.equal(ms.positions[:], before), "%v moved at 0", kind)
		sculptor_pose_cancel(&ss)
		_ = sculptor_pose_end(&sp)
		sculptor_destroy(&ss)
		sculptor_destroy(&sp)
		geom.mesh_destroy(&ms)
		geom.mesh_destroy(&mp)
		free_all(context.temp_allocator)
	}
}

// Offset moves the whole sphere by the share of its size, Size doubles one side, and
// Spherize at 100 % puts every vertex of a rough sphere at one radius.
@(test)
reshape_offset_size_and_spherize_measure_up :: proc(t: ^testing.T) {
	near :: proc(a, b: f32) -> bool {return abs(a - b) < 1e-4}
	{
		m := geom.icosphere(3)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, nil, 64)
		defer sculptor_destroy(&s)
		before := reshape_on(t, &s, {kind = .Offset, axes = {.X, .Z}, amount = 0.25})
		for p, v in m.positions do testing.expect(t, near(p.x - before[v].x, 0.5) && near(p.z - before[v].z, 0.5) && p.y == before[v].y)
		sculptor_pose_cancel(&s)
		_ = reshape_on(t, &s, {kind = .Size, axes = {.X}, amount = 1})
		lo, hi := Vec3(math.F32_MAX), Vec3(-math.F32_MAX)
		for p in m.positions do lo, hi = linalg.min(lo, p), linalg.max(hi, p)
		testing.expectf(t, near(hi.x - lo.x, 4) && near(hi.y - lo.y, 2), "sized to %v", hi - lo)
		sculptor_pose_cancel(&s)
	}
	m := bumpy_sphere(4)
	defer geom.mesh_destroy(&m)
	s: Sculptor
	sculptor_init(&s, &m, nil, 64)
	defer sculptor_destroy(&s)
	_ = reshape_on(t, &s, {kind = .Spherize, amount = 1})
	lo, hi, _ := sculptor_free_bounds(&s)
	centre := (lo + hi) * 0.5
	lengths := make([]f32, len(m.positions), context.temp_allocator)
	for p, v in m.positions do lengths[v] = linalg.length(p - centre)
	least, most := slice.min(lengths), slice.max(lengths)
	testing.expectf(t, most - least < 0.02, "radii from %v to %v", least, most)
	sculptor_pose_cancel(&s)
	free_all(context.temp_allocator)
}

// Polish takes the roughness off nearly as Smooth does but keeps the volume, which
// Smooth shrinks; Relax keeps the surface where it is.
@(test)
polish_keeps_the_volume_and_relax_the_shape :: proc(t: ^testing.T) {
	volume_of :: proc(m: geom.Mesh) -> f64 {return geom.mesh_check(m).volume}
	run :: proc(mode: Smooth_Mode) -> (volume: f64, off_sphere: f32) {
		m := bumpy_sphere(4)
		defer geom.mesh_destroy(&m)
		s: Sculptor
		sculptor_init(&s, &m, nil, 64)
		defer sculptor_destroy(&s)
		changed, _ := sculptor_smooth_all(&s, 10, 1, mode = mode)
		assert(changed)
		for p in m.positions do off_sphere += abs(linalg.length(p) - 1)
		return volume_of(m), off_sphere / f32(len(m.positions))
	}
	start := bumpy_sphere(4)
	defer geom.mesh_destroy(&start)
	v0 := volume_of(start)
	smooth, _ := run(.Smooth)
	polish, _ := run(.Polish)
	_, relaxed := run(.Relax)
	testing.expectf(t, abs(polish - v0) / v0 < 0.01, "Polish changed the volume %.4f to %.4f (Smooth %.4f)", v0, polish, smooth)
	testing.expectf(t, (v0 - smooth) / v0 > 0.02, "Smooth kept the volume %.4f to %.4f", v0, smooth)
	testing.expectf(t, relaxed < 0.03, "Relax left the surface %v off the sphere", relaxed)
	free_all(context.temp_allocator)
}
