package main

import "core:testing"

// A second tap counts while it lands within the gap after the first lifted and within
// reach of it; later, further, before it, or after no first tap at all, it does not.
@(test)
double_tap_needs_the_gap_and_the_reach :: proc(t: ^testing.T) {
	first := Double_Tap{valid = true, at = 10, pos = {100, 100}}
	testing.expect(t, double_tap_follows(first, 10.1, {120, 110}, DOUBLE_TAP_REACH))
	testing.expect(t, double_tap_follows(first, 10 + DOUBLE_TAP_GAP - 1e-6, {100, 100}, DOUBLE_TAP_REACH))
	testing.expect(t, !double_tap_follows(first, 10 + DOUBLE_TAP_GAP + 0.01, {100, 100}, DOUBLE_TAP_REACH))
	testing.expect(t, double_tap_follows(first, 10.1, {100 + DOUBLE_TAP_REACH, 100}, DOUBLE_TAP_REACH))
	testing.expect(t, !double_tap_follows(first, 10.1, {100 + DOUBLE_TAP_REACH + 1, 100}, DOUBLE_TAP_REACH))
	testing.expect(t, !double_tap_follows(first, 9.9, {100, 100}, DOUBLE_TAP_REACH))
	// The reach grows with the interface's scale, as the caller passes it.
	testing.expect(t, double_tap_follows(first, 10.1, {100 + DOUBLE_TAP_REACH * 1.5, 100}, DOUBLE_TAP_REACH * 2))
	first.valid = false
	testing.expect(t, !double_tap_follows(first, 10.1, {100, 100}, DOUBLE_TAP_REACH))
}

// A hold is due nothing before the long press, one step at it, and one more every
// HOLD_REPEAT after.
@(test)
hold_repeats_after_the_long_press :: proc(t: ^testing.T) {
	LONG :: HOLD_LONG
	testing.expect_value(t, hold_due(0, LONG, HOLD_REPEAT), 0)
	testing.expect_value(t, hold_due(LONG - 0.01, LONG, HOLD_REPEAT), 0)
	testing.expect_value(t, hold_due(LONG, LONG, HOLD_REPEAT), 1)
	testing.expect_value(t, hold_due(LONG + HOLD_REPEAT - 0.001, LONG, HOLD_REPEAT), 1)
	testing.expect_value(t, hold_due(LONG + HOLD_REPEAT + 0.001, LONG, HOLD_REPEAT), 2)
	testing.expect_value(t, hold_due(LONG + 10 * HOLD_REPEAT + 0.001, LONG, HOLD_REPEAT), 11)
}

// The turntable's roll holds level within ROLL_LEVEL of it, catches up without a jump by
// twice that, and is itself beyond; the start of a twist reads what is shown back.
@(test)
roll_holds_level_near_level_without_a_jump :: proc(t: ^testing.T) {
	L :: ROLL_LEVEL
	testing.expect_value(t, roll_level_detent(0), 0)
	testing.expect_value(t, roll_level_detent(L * 0.9), 0)
	testing.expect_value(t, roll_level_detent(-L * 0.9), 0)
	testing.expect(t, abs(roll_level_detent(L * 1.5) - L) < 1e-6)
	testing.expect_value(t, roll_level_detent(-2 * L), -2 * L)
	testing.expect_value(t, roll_level_detent(1.2), 1.2)
	// No jump: small steps of the twist move what is shown by small steps.
	prev := roll_level_detent(-3 * L)
	for i in 1 ..= 600 {
		r := roll_level_detent(-3 * L + f32(i) * L / 100)
		testing.expect(t, abs(r - prev) <= 2 * L / 100 + 1e-6, "the detent jumped")
		prev = r
	}
	for shown in ([]f32{0, L * 0.5, -L * 1.7, 2 * L, -1}) {
		testing.expect(t, abs(roll_level_detent(roll_level_undetent(shown)) - shown) < 1e-6, "the start of a twist moved the view")
	}
}
