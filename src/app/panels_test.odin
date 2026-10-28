package main

import "core:fmt"
import "core:os"
import "core:testing"
import "../ui"

@(test)
a_column_shares_its_height_by_what_each_panel_wants :: proc(t: ^testing.T) {
	out: [4]f32
	// Room for all: each gets what it wants.
	panel_water_fill({100, 200, 50}, 1000, out[:3])
	testing.expect_value(t, out[0], 100)
	testing.expect_value(t, out[1], 200)
	testing.expect_value(t, out[2], 50)
	// Short of room: the small want is met, the two large split what is left evenly.
	panel_water_fill({600, 100, 900}, 700, out[:3])
	testing.expect_value(t, out[1], 100)
	testing.expect_value(t, out[0], 300)
	testing.expect_value(t, out[2], 300)
	// One that wants less than an even share gives the rest to the others.
	panel_water_fill({1000, 1000, 1000, 40}, 640, out[:4])
	testing.expect_value(t, out[3], 40)
	testing.expect_value(t, out[0], 200)
	testing.expect_value(t, out[0] + out[1] + out[2] + out[3], 640)
}

@(test)
panels_dock_float_and_move_within_their_columns :: proc(t: ^testing.T) {
	a: App
	defer free_all(context.temp_allocator)
	k := &a.kit
	panels_default(k)
	testing.expect_value(t, len(k.panels.columns[.Right]), 1)

	// Pinned sections go to the bottom of the right column, open; again, they go away.
	panel_pin_toggle(&a, .Layers)
	panel_pin_toggle(&a, .Camera)
	right := k.panels.columns[.Right]
	testing.expect_value(t, len(right), 3)
	testing.expect(t, right[1] == Panel_Ref(Kit_Section.Layers) && right[2] == Panel_Ref(Kit_Section.Camera), "pinned in the wrong order")
	testing.expect(t, panel_open(&a, Kit_Section.Camera), "a pinned section is not shown")

	// Up, then to the left column, ahead of what is there.
	panel_shift(&a, Kit_Section.Camera, -1)
	testing.expect(t, k.panels.columns[.Right][1] == Panel_Ref(Kit_Section.Camera), "Move up did not move it")
	panel_dock(&a, Kit_Window.Stats, .Left, 0)
	panel_dock(&a, Kit_Section.Camera, .Left, 0)
	side, index, docked := panel_docked(k, Kit_Section.Camera)
	testing.expect(t, docked && side == .Left && index == 0, "not docked first on the left")
	testing.expect_value(t, len(k.panels.columns[.Right]), 2)
	// Within its own column, after the one below it.
	panel_dock(&a, Kit_Section.Camera, .Left, 2)
	_, index, _ = panel_docked(k, Kit_Section.Camera)
	testing.expect_value(t, index, 1)

	// Floating takes it out of every column; Unpin hides it but keeps its place.
	panel_float(&a, Kit_Window.Stats)
	_, _, docked = panel_docked(k, Kit_Window.Stats)
	testing.expect(t, !docked, "Float left it docked")
	panel_pin_toggle(&a, .Layers)
	testing.expect(t, !panel_open(&a, Kit_Section.Layers), "Unpin left it shown")
	_, _, docked = panel_docked(k, Kit_Section.Layers)
	testing.expect(t, docked, "Unpin forgot where it was")

	// Reset panels puts everything back.
	windows_reset(k)
	testing.expect_value(t, len(k.panels.columns[.Left]), 0)
	testing.expect_value(t, len(k.panels.columns[.Right]), 1)
	testing.expect(t, !k.panels.pins[.Camera].on, "Reset left a pin")
	testing.expect(t, panel_pinnable(.Layers) && !panel_pinnable(.Objects) && !panel_pinnable(.Frame), "the wrong sections pin")
}

@(test)
panels_read_back_what_they_wrote :: proc(t: ^testing.T) {
	path := "build/panels_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a: App
	panels_default(&a.kit)
	panel_pin_toggle(&a, .Lights)
	panel_dock(&a, Kit_Window.History, .Left, 0)
	panel_dock(&a, Kit_Section.Lights, .Left, 0)
	a.kit.panels.pins[.Lights].window.minimized = true
	panel_pin_toggle(&a, .Mask)
	panel_take_for_test(&a.kit, Kit_Section.Mask)
	a.kit.panels.pins[.Mask].window = {moved = true, x = .End, y = .Start, offset = {30, 120}}
	testing.expect(t, settings_save(&a, path))

	b: App
	panels_default(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, len(b.kit.panels.columns[.Left]), 2)
	testing.expect(t, b.kit.panels.columns[.Left][0] == Panel_Ref(Kit_Section.Lights) && b.kit.panels.columns[.Left][1] == Panel_Ref(Kit_Window.History), "the left column came back wrong")
	testing.expect_value(t, len(b.kit.panels.columns[.Right]), 1)
	testing.expect(t, b.kit.panels.pins[.Lights].on && b.kit.panels.pins[.Lights].window.minimized, "a folded pin came back open")
	testing.expect_value(t, b.kit.panels.pins[.Mask].window, a.kit.panels.pins[.Mask].window)
	_, _, docked := panel_docked(&b.kit, Kit_Section.Mask)
	testing.expect(t, !docked, "a floating pin came back docked")

	// Words that name nothing, and a panel named twice, are passed over.
	c: App
	panels_default(&c.kit)
	panels_load_line(&c.kit, {"column", "right", "Inspector", "section:Nothing", "Settings", "inspector", "section:Objects", "Stats"})
	testing.expect_value(t, len(c.kit.panels.columns[.Right]), 2)
	testing.expect(t, c.kit.panels.columns[.Right][1] == Panel_Ref(Kit_Window.Stats), "a word that names no panel was read")
}

// Takes a panel out of its column, as Float does without a laid-out place to float from.
@(private = "file")
panel_take_for_test :: proc(k: ^Kit_State, ref: Panel_Ref) {
	if side, i, ok := panel_docked(k, ref); ok do ordered_remove(&k.panels.columns[side], i)
}

@(test)
a_pinned_panel_changes_sides_with_the_hand :: proc(t: ^testing.T) {
	a: App
	k := &a.kit
	panels_default(k)
	k.panels.pins[.Lights].window = {moved = true, x = .End, offset = {30, 120}}
	k.panels.pins[.Mask].window = {moved = true, x = .Center}
	k.ctx.mirror = true
	kit_mirror(k)
	testing.expect_value(t, k.panels.pins[.Lights].window.x, ui.Anchor.Start)
	// A centred offset of 0 stays 0, not -0, so the settings line reads the same.
	testing.expect_value(t, fmt.tprint(k.panels.pins[.Mask].window.offset.x), "0")
	free_all(context.temp_allocator)
}

@(test)
every_panel_has_its_own_bit :: proc(t: ^testing.T) {
	seen: u64
	for w in Kit_Window {
		b := panel_bit(w)
		testing.expectf(t, b != 0 && seen & b == 0, "%v shares a bit", w)
		seen |= b
	}
	for s in 0 ..< TRAY_SECTIONS {
		b := panel_bit(Kit_Section(s))
		testing.expectf(t, b != 0 && seen & b == 0, "%v shares a bit", Kit_Section(s))
		seen |= b
	}
}
