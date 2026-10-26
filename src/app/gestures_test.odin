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
	LONG :: 0.45
	testing.expect_value(t, hold_due(0, LONG, HOLD_REPEAT), 0)
	testing.expect_value(t, hold_due(LONG - 0.01, LONG, HOLD_REPEAT), 0)
	testing.expect_value(t, hold_due(LONG, LONG, HOLD_REPEAT), 1)
	testing.expect_value(t, hold_due(LONG + HOLD_REPEAT - 0.001, LONG, HOLD_REPEAT), 1)
	testing.expect_value(t, hold_due(LONG + HOLD_REPEAT + 0.001, LONG, HOLD_REPEAT), 2)
	testing.expect_value(t, hold_due(LONG + 10 * HOLD_REPEAT + 0.001, LONG, HOLD_REPEAT), 11)
}
