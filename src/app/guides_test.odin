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
	rec := geom.record_of(out[:])
	back, ok := guides_get(&rec)
	testing.expect(t, ok, "a written record was refused")
	testing.expect_value(t, back, g)

	// A flag no version wrote, a height that is not a number, or a field of the wrong size
	// are refused; a record with nothing in it is hidden guides.
	bad := make([]u8, len(out))
	defer delete(bad)
	copy(bad, out[:])
	rb := geom.record_of(bad)
	shown, _ := geom.rec_find(&rb, Guides_Tag.Shown)
	shown[0] = 2
	_, flags_ok := guides_get(&rb)
	testing.expect(t, !flags_ok, "an unknown flag was read")
	nan: [dynamic]u8
	defer delete(nan)
	guides_put(&nan, Guides{heights = {.Brow = math.nan_f32(), .Nose_Base = 0, .Chin = 0}})
	rn := geom.record_of(nan[:])
	_, nan_ok := guides_get(&rn)
	testing.expect(t, !nan_ok, "a height that is not a number was read")
	short: [dynamic]u8
	defer delete(short)
	geom.rec_put(&short, Guides_Tag.Heights, [2]f32{1, 2})
	rs := geom.record_of(short[:])
	_, short_ok := guides_get(&rs)
	testing.expect(t, !short_ok, "a field of the wrong size was read")
	empty := geom.record_of(nil)
	none, none_ok := guides_get(&empty)
	testing.expect(t, none_ok && none == Guides{}, "a record without guides was not hidden guides")
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
