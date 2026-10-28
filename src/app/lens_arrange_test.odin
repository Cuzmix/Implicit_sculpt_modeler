package main

import "core:strings"
import "core:testing"

// The dial comes as it always was; each sector reads back from what the settings file
// writes, and a name this version does not know, or a command no bar may hold, is refused.
@(test)
dial_sectors_read_back :: proc(t: ^testing.T) {
	k: Kit_State
	k.dial = DIAL_DEFAULT
	testing.expect(t, dial_is_default(&k))
	testing.expect(t, dial_has(&k, .Smooth) && dial_has(&k, .Mask) && !dial_has(&k, .Hide))
	k.dial[0] = Bar_Slot{.Frame_All, 0}
	k.dial[3] = Modifier.Hide
	testing.expect(t, !dial_is_default(&k))
	for s in k.dial {
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
	sectors := DIAL_DEFAULT
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
	k.dial = DIAL_DEFAULT
	bars_reset(k)
	k.dial[2] = Modifier.Hide
	k.wheel_size, k.wheel_turn = .Large, 30
	arrange_zone_reset(&app, .Dial)
	testing.expect(t, dial_is_default(k) && k.wheel_size == .Medium && k.wheel_turn == 0)

	rail := bar_list_k(k, .View_Rail)
	rail.count -= 1
	k.shelf.lists[.Sculpt].count -= 1
	arrange_zone_reset(&app, .Rail)
	testing.expect(t, !bar_changed(&app, .View_Rail))
	testing.expect(t, bar_changed(&app, shelf_which(.Sculpt)))
	arrange_zone_reset(&app, .Shelf)
	testing.expect(t, !bar_changed(&app, shelf_which(.Sculpt)))
	testing.expect_value(t, k.arrange.resets, 3)
	testing.expect(t, !arrange_zone_resettable(.Offhand))
}
