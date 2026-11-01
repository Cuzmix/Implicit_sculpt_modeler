package main

import "core:os"
import "core:testing"

// A rail with Symmetry, Lights and Tools after a fresh rail's Objects, Layers and Material.
@(private = "file")
rail_with_cards :: proc(app: ^App) {
	bars_reset(&app.kit)
	stack_default(&app.kit)
	rail_panel_toggle(app, .Symmetry)
	rail_panel_toggle(app, .Lights)
	rail_panel_toggle(app, .Tools)
}

// Material carried onto Layers makes a group of the two in Layers' place, Material shown;
// Symmetry joins it; a panel twice, or a command that is not a panel, is refused.
@(test)
rail_join_makes_and_grows_a_group :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	rail_with_cards(&app)
	testing.expect_value(t, bar_names(&app, .View_Rail), "Show_Panel:Scene,Show_Section:Layers,Show_Section:Material,Show_Panel:Symmetry,Show_Panel:Lights,Show_Panel:Tools")
	used := bar_used(&app, .View_Rail)
	testing.expect(t, rail_join(&app, used[2], 2, 1))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Show_Panel:Scene,Rail_Group:0,Show_Panel:Symmetry,Show_Panel:Lights,Show_Panel:Tools")
	testing.expect_value(t, rail_groups_text(&app.kit), "0:tabs:0:Layer_Settings+Material_Settings")
	testing.expect_value(t, app.kit.rail_groups[0].shown, 1)
	used = bar_used(&app, .View_Rail)
	testing.expect(t, rail_join(&app, used[2], 2, 1))
	testing.expect_value(t, rail_groups_text(&app.kit), "0:tabs:0:Layer_Settings+Material_Settings+Symmetry")
	// Lights' button carried from Search onto the group joins it too; a second Lights is refused.
	testing.expect(t, rail_join(&app, {.Show_Panel, int(Panel_Kind.Lights)}, -1, 1))
	testing.expect(t, !rail_join(&app, {.Show_Panel, int(Panel_Kind.Lights)}, -1, 1))
	testing.expect(t, !rail_join(&app, {.Floor_Grid, 0}, -1, 1))
	testing.expect_value(t, app.kit.rail_groups[0].count, 4)
	testing.expect(t, slot_joins(&app.kit, {.Rail_Group, 0}) && !slot_joins(&app.kit, {.Rail_Group, 5}))
}

// Take out gives a panel its own button after the group, and the last but one leaves the
// group a panel's button again; Ungroup splits a group in place; Remove takes it off.
@(test)
rail_group_take_out_ungroup_and_remove :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	rail_with_cards(&app)
	used := bar_used(&app, .View_Rail)
	testing.expect(t, rail_join(&app, used[2], 2, 1))
	testing.expect(t, rail_group_take_out(&app, 0, 0))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Show_Panel:Scene,Show_Section:Material,Show_Section:Layers,Show_Panel:Symmetry,Show_Panel:Lights,Show_Panel:Tools")
	testing.expect(t, !app.kit.rail_groups[0].used)

	used = bar_used(&app, .View_Rail)
	testing.expect(t, rail_join(&app, used[3], 3, 2))
	used = bar_used(&app, .View_Rail)
	testing.expect(t, rail_join(&app, used[3], 3, 2))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Show_Panel:Scene,Show_Section:Material,Rail_Group:0,Show_Panel:Tools")
	testing.expect(t, rail_ungroup(&app, 0))
	testing.expect_value(t, bar_names(&app, .View_Rail), "Show_Panel:Scene,Show_Section:Material,Show_Section:Layers,Show_Panel:Symmetry,Show_Panel:Lights,Show_Panel:Tools")

	used = bar_used(&app, .View_Rail)
	testing.expect(t, rail_join(&app, used[3], 3, 2))
	rail_group_remove(&app, 0)
	testing.expect_value(t, bar_names(&app, .View_Rail), "Show_Panel:Scene,Show_Section:Material,Show_Panel:Lights,Show_Panel:Tools")
	testing.expect_value(t, rail_groups_text(&app.kit), "none")
}

// Pinned, a group's panels are in the stack joined as tabs of the first (Stacked: one
// after another, not joined); unpinned, the one the pin brought in leaves again while a
// card the stack showed anyway stays.
@(test)
rail_group_pin_docks_it_in_the_stack :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	rail_with_cards(&app)
	s := &app.kit.stack
	testing.expect(t, .Lights in s.hidden && .Symmetry not_in s.hidden)
	used := bar_used(&app, .View_Rail)
	// Lights (slot 4) onto Symmetry (slot 3).
	testing.expect(t, rail_join(&app, used[4], 4, 3))
	rail_group_pin(&app, 0, true)
	testing.expect(t, .Lights not_in s.hidden && .Lights in s.joined && stack_host(s, .Lights) == .Symmetry)
	rail_group_set_stacked(&app, 0, true)
	testing.expect(t, .Lights not_in s.hidden && .Lights not_in s.joined)
	order := stack_text(&app.kit)
	testing.expectf(t, contains_in_order(order, "Symmetry", "Lights"), "Lights after Symmetry: %s", order)
	rail_group_pin(&app, 0, false)
	testing.expect(t, .Lights in s.hidden && .Symmetry not_in s.hidden)
	testing.expect(t, !app.kit.rail_groups[0].pinned)
}

@(private = "file")
contains_in_order :: proc(s, a, b: string) -> bool {
	ia, ib := -1, -1
	for i in 0 ..< len(s) {
		if ia < 0 && i + len(a) <= len(s) && s[i:i + len(a)] == a do ia = i
		if ib < 0 && i + len(b) <= len(s) && s[i:i + len(b)] == b do ib = i
	}
	return ia >= 0 && ib > ia
}

// The groups come back from the settings file and a workspace's layout with their name,
// colour, Stacked and shown tab; a damaged line is passed over, and a rail put back
// drops them.
@(test)
rail_groups_save_and_read :: proc(t: ^testing.T) {
	path := "build/rail_groups_test.txt"
	defer os.remove(path)
	a: App
	defer results_destroy(&a)
	rail_with_cards(&a)
	used := bar_used(&a, .View_Rail)
	testing.expect(t, rail_join(&a, used[2], 2, 1))
	g := &a.kit.rail_groups[0]
	g.stacked, g.colour, g.shown = true, 3, 0
	copy(g.name[:], "My look")
	testing.expect(t, settings_save(&a, path))

	b: App
	defer results_destroy(&b)
	bars_reset(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, bar_names(&b, .View_Rail), bar_names(&a, .View_Rail))
	testing.expect_value(t, rail_groups_text(&b.kit), "0:stacked:0:Layer_Settings+Material_Settings")
	testing.expect_value(t, rail_group_name(&b, 0), "My look")
	testing.expect_value(t, b.kit.rail_groups[0].colour, 3)

	c: App
	defer results_destroy(&c)
	bars_reset(&c.kit)
	kit_layout_put(&c.kit, kit_layout_text(&a.kit))
	testing.expect_value(t, rail_groups_text(&c.kit), rail_groups_text(&a.kit))
	kit_layout_put(&c.kit, "bars\n")
	testing.expect_value(t, rail_groups_text(&c.kit), "none")

	d: App
	defer results_destroy(&d)
	bars_reset(&d.kit)
	for line in ([?][]string{{"rail_group", "0"}, {"rail_group", "99", "tabs", "0", "0", "0", "card:Symmetry"}, {"rail_group", "1", "sideways", "0", "0", "0", "card:Symmetry"}, {"rail_group", "2", "tabs", "0", "0", "0", "card:Nothing"}}) {
		rail_group_read(&d.kit, line)
	}
	testing.expect_value(t, rail_groups_text(&d.kit), "none")
}
