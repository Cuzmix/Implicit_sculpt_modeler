package main

import "core:math"
import "core:testing"

import "../geom"

@(test)
guides_are_kept_and_a_damaged_record_is_refused :: proc(t: ^testing.T) {
	g := Guides{shown = true, seeded = true, heights = {.Brow = 0.8, .Nose_Base = 0.1, .Chin = -0.6}}
	out: [dynamic]u8
	defer delete(out)
	guides_put(&out, g)
	testing.expect_value(t, len(out), GUIDES_BYTES)
	r := geom.byte_reader(out[:])
	back, ok := guides_get(&r)
	testing.expect(t, ok, "a written record was refused")
	testing.expect_value(t, back, g)

	// Flags no version wrote, a height that is not a number, or a short record are refused.
	bad := make([]u8, len(out))
	defer delete(bad)
	copy(bad, out[:])
	bad[0] = 4
	rb := geom.byte_reader(bad)
	_, flags_ok := guides_get(&rb)
	testing.expect(t, !flags_ok, "unknown flags were read")
	nan: [dynamic]u8
	defer delete(nan)
	guides_put(&nan, Guides{heights = {.Brow = math.nan_f32(), .Nose_Base = 0, .Chin = 0}})
	rn := geom.byte_reader(nan[:])
	_, nan_ok := guides_get(&rn)
	testing.expect(t, !nan_ok, "a height that is not a number was read")
	rs := geom.byte_reader(out[:len(out) - 1])
	_, short_ok := guides_get(&rs)
	testing.expect(t, !short_ok, "a short record was read")
}

@(test)
guides_seed_by_thirds_once :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	// With nothing in the scene they seed over a unit box about the origin.
	guides_toggle(app)
	g := app.scene.guides
	testing.expect(t, g.shown && g.seeded, "showing the guides did not seed them")
	testing.expect(t, abs(g.heights[.Chin] + 1) < 1e-5 && abs(g.heights[.Nose_Base] + 1.0 / 3) < 1e-5 && abs(g.heights[.Brow] - 1.0 / 3) < 1e-5, "the guides are not at the box's thirds")
	testing.expect_value(t, app.view_edits, u64(1))
	// A moved guide stays where it was put when they are hidden and shown again.
	app.scene.guides.heights[.Brow] = 0.9
	guides_toggle(app)
	guides_toggle(app)
	testing.expect_value(t, app.scene.guides.heights[.Brow], f32(0.9))
	// Reset seeds them again.
	guides_reset(app)
	testing.expect(t, abs(app.scene.guides.heights[.Brow] - 1.0 / 3) < 1e-5 && app.scene.guides.shown, "Reset guides did not put them back")
}
