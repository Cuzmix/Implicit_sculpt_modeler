package main

import "core:math/linalg"
import "core:testing"

import "../gizmo"

// A snapped move keeps to what its handle allows: an arm moves only along it (its amount
// the distance along), a plane square only across its plane, the middle all the way.
@(test)
snap_move_keeps_to_the_handle :: proc(t: ^testing.T) {
	axes := [3]Vec3{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}
	from, target := Vec3{1, 2, 3}, Vec3{4, -1, 5}
	move, amount := snap_move(.X, from, target, axes)
	testing.expect_value(t, move, Vec3{3, 0, 0})
	testing.expect_value(t, amount, f32(3))
	move, _ = snap_move(.XZ, from, target, axes)
	testing.expect_value(t, move, Vec3{3, 0, 2})
	move, _ = snap_move(.View, from, target, axes)
	testing.expect_value(t, move, target - from)
	// Turned axes: along the turned arm, by the share of the move along it.
	turned := [3]Vec3{linalg.normalize(Vec3{1, 1, 0}), linalg.normalize(Vec3{-1, 1, 0}), {0, 0, 1}}
	move, amount = snap_move(gizmo.Handle.X, {}, {2, 0, 0}, turned)
	testing.expect(t, linalg.length(move - Vec3{1, 1, 0}) < 1e-5)
	testing.expect(t, abs(amount - linalg.sqrt(f32(2))) < 1e-5)
}

// Measure's label: the length, then the distance along each axis, however the ends lie.
@(test)
measure_text_gives_length_and_axes :: proc(t: ^testing.T) {
	testing.expect_value(t, measure_text({1, 2, 3}, {4, -2, 3}), "5.000 · X 3.000  Y 4.000  Z 0.000")
}
