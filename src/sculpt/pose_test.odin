package sculpt

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
Pose_Sphere :: struct {
	mesh:     geom.Mesh,
	sculptor: Sculptor,
}

// An icosphere masked below y = 0, half masked up to y = 0.2 and free above.
@(private = "file")
pose_sphere :: proc(pool: ^jobs.Pool = nil) -> ^Pose_Sphere {
	sp := new(Pose_Sphere)
	sp.mesh = geom.icosphere(3)
	sculptor_init(&sp.sculptor, &sp.mesh, pool, 64)
	s := &sp.sculptor
	values := make([]u8, len(sp.mesh.positions), context.temp_allocator)
	for p, v in sp.mesh.positions do values[v] = 255 if p.y < 0 else (128 if p.y < 0.2 else 0)
	assert(sculptor_mask_values(s, values, .Replace))
	return sp
}

@(private = "file")
pose_sphere_free :: proc(sp: ^Pose_Sphere) {
	sculptor_destroy(&sp.sculptor)
	geom.mesh_destroy(&sp.mesh)
	free(sp)
}

// A turn moves the free part rigidly, turns a half-masked vertex through half the angle
// at its own distance from the pivot, leaves the masked part, and is one undo step that
// undoes and redoes exactly.
@(test)
pose_turn_bends_the_free_part :: proc(t: ^testing.T) {
	sp := pose_sphere()
	defer pose_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	before := slice.clone(m.positions[:], context.temp_allocator)
	pivot := Vec3{0, 0.1, 0}
	testing.expect(t, sculptor_pose_begin(s))
	pose := Pose{kind = .Turn, pivot = pivot, axis = {0, 0, 1}, angle = math.PI / 2}
	sculptor_pose_apply(s, pose)
	whole := linalg.matrix3_rotate_f32(math.PI / 2, {0, 0, 1})
	half := linalg.matrix3_rotate_f32(math.PI / 2 * f32(127) / 255, {0, 0, 1})
	worst: f32
	for a, v in before {
		b := m.positions[v]
		want := a
		switch s.mask[v] {
		case 0:   want = pivot + whole * (a - pivot)
		case 128: want = pivot + half * (a - pivot)
		}
		worst = max(worst, linalg.length(b - want))
		if s.mask[v] == 128 do testing.expect(t, abs(linalg.length(b - pivot) - linalg.length(a - pivot)) < 1e-5)
	}
	testing.expectf(t, worst < 1e-5, "posed %v away", worst)
	posed := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_pose_end(s))
	testing.expect(t, sculptor_undo(s))
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect(t, sculptor_redo(s))
	testing.expect(t, slice.equal(m.positions[:], posed))
}

// Moves and scales blend by how free a vertex is; each apply starts from where the pose
// began, so the last one alone counts.
@(test)
pose_move_and_scale_blend :: proc(t: ^testing.T) {
	sp := pose_sphere()
	defer pose_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_pose_begin(s))
	sculptor_pose_apply(s, {kind = .Scale, pivot = {}, factor = 3})
	sculptor_pose_apply(s, {kind = .Move, delta = {0, 1, 0}})
	worst: f32
	for a, v in before {
		w := f32(255 - s.mask[v]) / 255
		worst = max(worst, linalg.length(m.positions[v] - (a + w * Vec3{0, 1, 0})))
	}
	testing.expectf(t, worst < 1e-6, "moved %v wrongly", worst)
	sculptor_pose_apply(s, {kind = .Scale, pivot = {0, 1, 0}, factor = 2})
	worst = 0
	for a, v in before {
		w := f32(255 - s.mask[v]) / 255
		worst = max(worst, linalg.length(m.positions[v] - (Vec3{0, 1, 0} + (a - {0, 1, 0}) * (1 + w))))
	}
	testing.expectf(t, worst < 1e-5, "scaled %v wrongly", worst)
	testing.expect(t, sculptor_pose_end(s))
}

// Cancelling puts every vertex back exactly and leaves no undo step; a pose that never
// applied leaves none either.
@(test)
pose_cancel_leaves_nothing :: proc(t: ^testing.T) {
	sp := pose_sphere()
	defer pose_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	steps := len(s.history.done)
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_pose_begin(s))
	sculptor_pose_apply(s, {kind = .Turn, pivot = {}, axis = {1, 0, 0}, angle = 1})
	sculptor_pose_cancel(s)
	testing.expect(t, slice.equal(m.positions[:], before))
	testing.expect_value(t, len(s.history.done), steps)
	testing.expect(t, !sculptor_posing(s))
	testing.expect(t, sculptor_pose_begin(s))
	testing.expect(t, !sculptor_pose_end(s))
	testing.expect_value(t, len(s.history.done), steps)
}

// Hidden vertices stay, everything masked leaves nothing to pose, and dynamic topology
// refuses.
@(test)
pose_leaves_hidden_and_refuses :: proc(t: ^testing.T) {
	sp := pose_sphere()
	defer pose_sphere_free(sp)
	s := &sp.sculptor
	m := &sp.mesh
	rect := [][2]f32{{-0.3, 0.3}, {0.3, 0.3}, {0.3, 2}, {-0.3, 2}}
	testing.expect(t, sculptor_hide_shape(s, 1, rect, .Hide))
	before := slice.clone(m.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_pose_begin(s))
	sculptor_pose_apply(s, {kind = .Move, delta = {1, 0, 0}})
	hidden := 0
	for v in 0 ..< len(before) {
		if !vertex_hidden(s, u32(v)) do continue
		hidden += 1
		testing.expect(t, m.positions[v] == before[v])
	}
	testing.expect(t, hidden > 0)
	testing.expect(t, sculptor_pose_end(s))
	testing.expect(t, sculptor_hide_command(s, .Show_All))
	testing.expect(t, sculptor_mask_command(s, .Fill))
	testing.expect(t, !sculptor_pose_begin(s))
	testing.expect(t, sculptor_mask_command(s, .Clear))
	testing.expect(t, sculptor_dyn_enable(s))
	defer sculptor_dyn_disable(s)
	testing.expect(t, !sculptor_pose_begin(s))
}

// Serial and threaded poses give the same positions.
@(test)
pose_parallel_matches_serial :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	a := pose_sphere()
	defer pose_sphere_free(a)
	b := pose_sphere(&pool)
	defer pose_sphere_free(b)
	for sp in ([2]^Pose_Sphere{a, b}) {
		testing.expect(t, sculptor_pose_begin(&sp.sculptor))
		sculptor_pose_apply(&sp.sculptor, {kind = .Turn, pivot = {0, 0.1, 0}, axis = linalg.normalize(Vec3{1, 0, 1}), angle = 0.7})
		testing.expect(t, sculptor_pose_end(&sp.sculptor))
	}
	testing.expect(t, slice.equal(a.mesh.positions[:], b.mesh.positions[:]))
}

// The pivot a pose of the mask would take: the middle of the soft edge.
@(test)
mask_centroid_finds_the_soft_edge :: proc(t: ^testing.T) {
	sp := pose_sphere()
	defer pose_sphere_free(sp)
	c, ok := sculptor_mask_centroid(&sp.sculptor)
	testing.expect(t, ok)
	testing.expectf(t, c.y >= 0 && c.y < 0.2 && abs(c.x) < 0.05 && abs(c.z) < 0.05, "centroid %v", c)
}

// The look at a mask finds something free until all that is shown is fully masked, and
// its checksum follows the mask through undo.
@(test)
mask_look_sees_what_is_free :: proc(t: ^testing.T) {
	sp := pose_sphere()
	defer pose_sphere_free(sp)
	s := &sp.sculptor
	a := sculptor_mask_look(s)
	testing.expect(t, a.free)
	testing.expect(t, sculptor_mask_command(s, .Fill))
	b := sculptor_mask_look(s)
	testing.expect(t, !b.free)
	testing.expect(t, a.sum != b.sum)
	testing.expect(t, sculptor_undo(s))
	testing.expect_value(t, sculptor_mask_look(s), a)
	// A hard edge with the free part hidden leaves nothing free.
	values := make([]u8, len(sp.mesh.positions), context.temp_allocator)
	for p, v in sp.mesh.positions do values[v] = 255 if p.y < 0 else 0
	testing.expect(t, sculptor_mask_values(s, values, .Replace))
	testing.expect(t, sculptor_hide_command(s, .Unmasked))
	testing.expect(t, !sculptor_mask_look(s).free)
	testing.expect(t, !sculptor_pose_begin(s))
}
