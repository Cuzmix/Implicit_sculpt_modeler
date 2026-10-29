package main

import "core:testing"

import "../sculpt"

// Recent keeps the last BRUSH_RECENT picks, most recent first, and a pick already in it
// moves to the front instead of showing twice.
@(test)
brush_recent_moves_a_repeat_to_the_front :: proc(t: ^testing.T) {
	p: Brush_Palette
	names := [?]string{"brush/Draw", "brush/Clay", "brush/Smooth", "brush/Grab", "brush/Mask", "brush/Paint", "brush/Cloth", "brush/Layer", "brush/Pinch", "brush/Crease", "brush/Inflate", "brush/Flatten", "brush/Morph", "brush/History"}
	for n in names do brush_recent_push(&p, n)
	testing.expect_value(t, p.recent_count, BRUSH_RECENT)
	testing.expect_value(t, brush_key_text(&p.recent[0]), "brush/History")
	testing.expect_value(t, brush_key_text(&p.recent[BRUSH_RECENT - 1]), "brush/Smooth")
	brush_recent_push(&p, "brush/Layer")
	testing.expect_value(t, p.recent_count, BRUSH_RECENT)
	testing.expect_value(t, brush_key_text(&p.recent[0]), "brush/Layer")
	testing.expect_value(t, brush_key_text(&p.recent[1]), "brush/History")
	seen := 0
	for &k in p.recent do if brush_key_text(&k) == "brush/Layer" do seen += 1
	testing.expect_value(t, seen, 1)
}

// The heart adds the current brush to Favorites and takes it out again, keeping the
// others in the order they were added.
@(test)
brush_favorites_toggle :: proc(t: ^testing.T) {
	p: Brush_Palette
	brush_favorite_toggle(&p, "brush/Clay")
	brush_favorite_toggle(&p, "library/Trim")
	brush_favorite_toggle(&p, "tool/Curve")
	brush_favorite_toggle(&p, "library/Trim")
	testing.expect_value(t, p.favorite_count, 2)
	testing.expect_value(t, brush_key_text(&p.favorites[1]), "tool/Curve")
	_, on := brush_favorite(&p, "library/Trim")
	testing.expect(t, !on)
}

// Every built-in brush, library preset, tool and mask, hide or cut tool is in All once
// and in exactly one category; categories list alphabetically, Recent in the order
// picked; a search finds names containing it, in any case; and a pick made anywhere
// (here a key's command) reaches Recent, the brush the app starts on not.
@(test)
brush_palette_lists_categories :: proc(t: ^testing.T) {
	app: App
	app.tool = .Brush
	all := brush_items_all(&app)
	testing.expect_value(t, len(all), len(sculpt.Brush_Kind) + len(BUILT_IN_PRESETS) + 3 + len(Mask_Shape_Kind) + len(Gesture_Tool))
	in_some := 0
	for c in BRUSH_CATEGORY_ORDER {
		if c == .Recent || c == .Favorites || c == .All do continue
		app.kit.brushes.category = c
		list := brush_palette_list(&app, all[:])
		in_some += len(list)
		for i in 1 ..< len(list) do testing.expectf(t, list[i - 1].low <= list[i].low, "%v: %s before %s", c, list[i - 1].name, list[i].name)
	}
	testing.expect_value(t, in_some, len(all))
	app.kit.brushes.category = .Smooth
	smooth := brush_palette_list(&app, all[:])
	testing.expect_value(t, smooth[0].name, "Fill")

	brush_recent_track(&app)
	testing.expect_value(t, app.kit.brushes.recent_count, 0)
	app.brush.kind = .Crease
	brush_recent_track(&app)
	brush_item_pick(&app, {what = .Tool, tool = .Curve})
	app.kit.brushes.category = .Recent
	recent := brush_palette_list(&app, all[:])
	testing.expect_value(t, len(recent), 2)
	testing.expect_value(t, recent[0].name, "Curve")
	testing.expect_value(t, recent[1].name, "Crease")

	app.kit.brushes.searching = true
	copy(app.kit.brushes.search[:], "SMOOTH")
	found := brush_palette_list(&app, all[:])
	testing.expect_value(t, len(found), 4)
	for l in found do testing.expectf(t, l.low[:6] == "smooth", "search found %s", l.name)
	free_all(context.temp_allocator)
}
