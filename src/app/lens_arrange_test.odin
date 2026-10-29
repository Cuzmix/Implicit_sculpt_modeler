package main

import "core:strings"
import "core:testing"

import "../ui"

// The dial comes as it always was; each sector reads back from what the settings file
// writes, and a name this version does not know, or a command no bar may hold, is refused.
@(test)
dial_sectors_read_back :: proc(t: ^testing.T) {
	k: Kit_State
	k.dials = DIAL_DEFAULTS
	testing.expect(t, dial_is_default(&k, .Sculpt))
	testing.expect(t, dial_has(&k, .Smooth) && dial_has(&k, .Mask) && !dial_has(&k, .Hide))
	k.dials[.Sculpt][0] = Bar_Slot{.Frame_All, 0}
	k.dials[.Sculpt][3] = Modifier.Hide
	testing.expect(t, !dial_is_default(&k, .Sculpt))
	for s in k.dials[.Sculpt] {
		kind, _, name := strings.partition(dial_sector_text(s), " ")
		back, ok := dial_sector_parse(kind, name)
		testing.expectf(t, ok && back == s, "%v read back as %v", s, back)
	}
	_, ok := dial_sector_parse("modifier", "Squash")
	testing.expect(t, !ok)
	_, ok = dial_sector_parse("command", "Nothing_Like_This")
	testing.expect(t, !ok)
	_, ok = dial_sector_parse("sector", "Smooth")
	testing.expect(t, !ok)
}

// Only a modifier's sector claims a finger: a command's, as the pie's, is tapped.
@(test)
dial_command_sectors_are_not_held :: proc(t: ^testing.T) {
	c := [2]f32{100, 100}
	r := Modifier_Rail{center = c, outer = 132, hole = 44}
	sectors := DIAL_DEFAULTS[.Sculpt]
	sectors[0] = Bar_Slot{.Frame_All, 0}
	sectors[1] = Modifier.Mask
	_, ok := rail_hit(&r, sectors, {100, 50})
	testing.expect(t, !ok)
	m, mask := rail_hit(&r, sectors, {150, 100})
	testing.expect(t, mask && m == .Mask)
	// Two Mask sectors latch the one modifier.
	m2, _ := rail_hit(&r, sectors, {50, 100})
	rail_toggle(&r, m)
	testing.expect(t, m2 == .Mask && .Mask in r.latched)
}

// Reset zone puts back the zone picked and leaves the others: the dial's sectors, size
// and turn; the rail's buttons without the shelf's.
@(test)
reset_zone_resets_only_that_zone :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	k := &app.kit
	k.dials = DIAL_DEFAULTS
	bars_reset(k)
	k.dials[.Sculpt][2] = Modifier.Hide
	k.wheel_size, k.wheel_turn = .Large, 30
	arrange_zone_reset(&app, .Dial)
	testing.expect(t, dial_is_default(k, .Sculpt) && k.wheel_size == .Medium && k.wheel_turn == 0)

	rail := bar_list_k(k, .View_Rail)
	rail.count -= 1
	k.shelf.lists[.Sculpt].count -= 1
	arrange_zone_reset(&app, .Rail)
	testing.expect(t, !bar_changed(&app, .View_Rail))
	testing.expect(t, bar_changed(&app, shelf_which(.Sculpt)))
	arrange_zone_reset(&app, .Shelf)
	testing.expect(t, !bar_changed(&app, shelf_which(.Sculpt)))
	testing.expect_value(t, k.arrange.resets, 3)
	testing.expect(t, !arrange_zone_resettable(k, .Offhand))
	k.places[.Offhand] = {edge = .Float, at = {300, 200}}
	testing.expect(t, arrange_zone_resettable(k, .Offhand))
	arrange_zone_reset(&app, .Offhand)
	testing.expect_value(t, k.places[.Offhand], Bar_Place{})
}

// A drop over an edge puts the bar on it, snapped to the middle near it; at the bar's own
// default spot it is Default; elsewhere it floats where the outline was; mirrored, the
// screen's sides become the layout's; a bar dropped on the other's edge swaps with it.
@(test)
bars_drop_where_they_are_let_go :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	k := &app.kit
	ctx := &k.ctx
	ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	ui.frame_end(ctx)
	lo, hi := bar_place_room(&app, .Right)
	mid := lo + (hi - lo - 200) * 0.5
	p := bar_place_drop(&app, .Offhand, {1530, mid + 5, 60, 200}, {1560, mid + 20}, 300)
	testing.expect_value(t, p, Bar_Place{edge = .Right, along = 0.5})
	p = bar_place_drop(&app, .Offhand, {1530, lo, 60, 200}, {1560, lo + 20}, 300)
	testing.expect_value(t, p, Bar_Place{edge = .Right, along = 0})
	p = bar_place_drop(&app, .Offhand, {20, 300, 60, 200}, {40, 320}, 300)
	testing.expect_value(t, p, Bar_Place{})
	p = bar_place_drop(&app, .Offhand, {600.4, 300.6, 60, 200}, {620, 320}, 300)
	testing.expect_value(t, p, Bar_Place{edge = .Float, at = {600, 301}})
	ctx.mirror = true
	// The screen's left is the layout's right, the rail's own edge: at its top it is home.
	p = bar_place_drop(&app, .Rail, {20, lo, 60, 200}, {40, lo + 20}, TOP_BAR_H + 6)
	testing.expect_value(t, p, Bar_Place{})
	p = bar_place_drop(&app, .Rail, {20, lo + 300, 60, 200}, {40, lo + 320}, TOP_BAR_H + 6)
	testing.expect_value(t, p.edge, Bar_Edge.Right)
	p = bar_place_drop(&app, .Rail, {600, 300, 60, 200}, {620, 320}, TOP_BAR_H + 6)
	testing.expect_value(t, p, Bar_Place{edge = .Float, at = {940, 300}})
	ctx.mirror = false

	// The island onto the rail's edge: the rail takes the island's.
	bar_place_set(&app, .Offhand, {edge = .Right, along = 0.25})
	testing.expect_value(t, bar_place_edge(k, .Offhand), Bar_Edge.Right)
	testing.expect_value(t, bar_place_edge(k, .Rail), Bar_Edge.Left)
	// Their popovers open away from their edges.
	testing.expect_value(t, bar_side(&app, .View_Rail), ui.Side.Right)
	testing.expect_value(t, bar_side(&app, .Offhand), ui.Side.Left)
	// And back: each at home again.
	bar_place_set(&app, .Offhand, {})
	testing.expect_value(t, bar_place_edge(k, .Rail), Bar_Edge.Right)
	testing.expect_value(t, k.places[.Rail], Bar_Place{})
	free_all(context.temp_allocator)
}

// Places are the layout's: written as bar_place lines, read back, and a line this version
// cannot take (another bar, an edge, a number that is not one) leaves Default; a workspace
// built in keeps every bar at Default.
@(test)
bar_places_read_back :: proc(t: ^testing.T) {
	a: Kit_State
	a.places[.Offhand] = {edge = .Right, along = 0.25}
	a.places[.Rail] = {edge = .Float, at = {640, 120}}
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "bar_place offhand Right 0.25 0 0\n"), text)
	b: Kit_State
	kit_layout_put(&b, text)
	testing.expect_value(t, b.places, a.places)
	kit_layout_put(&b, "bar_place shelf Left 0.5 0 0\nbar_place rail Top 0.5 0 0\nbar_place offhand Left NaN 0 0\nbar_place offhand Float 0 inf 0\nbar_place offhand Default 0 0 0\n")
	testing.expect_value(t, b.places, [Place_Bar]Bar_Place{})
	testing.expect(t, !strings.contains(kit_layout_text(&b), "bar_place"))
	free_all(context.temp_allocator)
}
