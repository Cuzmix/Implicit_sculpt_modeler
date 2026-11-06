package main

import "core:os"
import "core:slice"
import "core:testing"

import "../sculpt"

@(private = "file")
spaces_app :: proc(follow := true) -> ^App {
	a := new(App)
	k := &a.kit
	bars_reset(k)
	panels_default(k)
	layouts_init(k)
	a.tool = .Brush
	a.brush.kind = .Clay
	if follow do space_follow(a)
	return a
}

@(private = "file")
spaces_app_free :: proc(a: ^App) {
	// What the layouts' steps and results kept, as the app frees them on exit.
	grid_undo_destroy(&a.kit.grid)
	results_destroy(a)
	layouts_destroy(&a.kit)
	free(a)
}

@(test)
the_tool_picks_its_space :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	testing.expect_value(t, k.spaces.current, Space.Sculpt)

	// The Model tool is Model; Move keeps the space it is picked in.
	model_pick_action(a, .Inset)
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Model)
	a.tool = .Move
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Model)

	// A brush is Sculpt again, and the shelf is back on a Sculpt page.
	command_run(a, .Brush, int(sculpt.Brush_Kind.Draw))
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Sculpt)
	testing.expect(t, k.shelf.page != .Model)
	testing.expect_value(t, k.spaces.switches, 2)
}

@(test)
a_tab_gives_the_space_its_tool_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	command_run(a, .Space_Switch, int(Space.Model))
	testing.expect_value(t, a.tool, Tool.Model)
	testing.expect_value(t, k.shelf.page, Shelf_Page.Model)
	model_pick_action(a, .Bridge)
	space_follow(a)
	command_run(a, .Space_Switch, int(Space.Sculpt))
	testing.expect_value(t, a.tool, Tool.Brush)
	testing.expect_value(t, a.brush.kind, sculpt.Brush_Kind.Clay)
	command_run(a, .Space_Switch, int(Space.Model))
	testing.expect_value(t, a.model.action, Model_Action.Bridge)

	// Render gives the Look tool; a brush picked there goes back to Sculpt with it, and
	// Sculpt's tab gives back the brush, never the Look tool.
	command_run(a, .Space_Switch, int(Space.Sculpt))
	command_run(a, .Space_Switch, int(Space.Render))
	testing.expect_value(t, a.tool, Tool.Look)
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Render)
	command_run(a, .Space_Switch, int(Space.Sculpt))
	testing.expect_value(t, a.tool, Tool.Brush)
	command_run(a, .Tool_Look, 0)
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Render)
	command_run(a, .Brush, int(sculpt.Brush_Kind.Clay))
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Sculpt)
	testing.expect_value(t, a.tool, Tool.Brush)

	// Adding a cage goes to Model.
	command_run(a, .Add_Cage, 0)
	testing.expect_value(t, k.spaces.current, Space.Model)
	testing.expect_value(t, a.tool, Tool.Model)
}

// Each space keeps its own layout: a change made in Model is kept when Sculpt is picked
// and comes back with Model, the tabs' dots say which spaces differ from how they ship,
// and Reset layout puts the current one back as it ships.
@(test)
each_space_comes_back_on_its_own_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	layouts_frame(k)
	for s in Space do testing.expect(t, !layout_changed(k, s), "every space starts as it ships")
	command_run(a, .Space_Switch, int(Space.Model))
	command_run(a, .Second_View, 0)
	layouts_frame(k)
	testing.expect(t, layout_changed(k, .Model))
	testing.expect(t, command_enabled(a, .Layout_Reset, 0))
	command_run(a, .Space_Switch, int(Space.Sculpt))
	layouts_frame(k)
	testing.expect_value(t, grid_panes(&k.grid), 1)
	testing.expect(t, !layout_changed(k, .Sculpt))
	testing.expect(t, layout_changed(k, .Model), "Model's dot stays while Sculpt is in front")
	command_run(a, .Space_Switch, int(Space.Model))
	layouts_frame(k)
	testing.expect(t, grid_panes(&k.grid) == 2, "Model's own layout did not come back")
	command_run(a, .Layout_Reset, 0)
	layouts_frame(k)
	testing.expect_value(t, grid_panes(&k.grid), 1)
	testing.expect(t, !layout_changed(k, .Model))
	testing.expect_value(t, k.layouts.resets, 1)
	testing.expect_value(t, k.spaces.current, Space.Model)
}

// Each space's layout round-trips through settings, as does the space in front.
@(test)
the_layouts_read_back :: proc(t: ^testing.T) {
	path := "build/layouts_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	command_run(a, .Space_Switch, int(Space.Model))
	command_run(a, .Second_View, 0)
	command_run(a, .Space_Switch, int(Space.Render))
	testing.expect(t, settings_save(a, path))
	b := spaces_app()
	defer spaces_app_free(b)
	settings_load(b, path)
	k := &b.kit
	layouts_frame(k)
	testing.expect_value(t, k.spaces.current, Space.Render)
	testing.expect(t, !layout_changed(k, .Render))
	testing.expect(t, layout_changed(k, .Model))
	command_run(b, .Space_Switch, int(Space.Model))
	testing.expect(t, grid_panes(&k.grid) == 2, "Model's layout read back")
}

// A run that starts in Render, with the Brush that start-up hands over (main.odin), holds
// the Look tool once its first frame has run, so a press there still turns the view; one
// that starts in Sculpt keeps the Brush.
@(test)
a_restart_into_render_holds_the_look_tool :: proc(t: ^testing.T) {
	path := "build/restart_render_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	command_run(a, .Space_Switch, int(Space.Render))
	testing.expect(t, settings_save(a, path))
	b := spaces_app(follow = false)
	defer spaces_app_free(b)
	settings_load(b, path)
	b.tool = .Brush
	space_follow(b)
	testing.expect_value(t, b.kit.spaces.current, Space.Render)
	testing.expect_value(t, b.tool, Tool.Look)
	testing.expect_value(t, b.kit.spaces.switches, 0)
	c := spaces_app(follow = false)
	defer spaces_app_free(c)
	space_follow(c)
	testing.expect_value(t, c.tool, Tool.Brush)
}

// Each kind of work has its own dial: switching space puts other hands to work with its
// tool and switches the sectors the rail reads, a latch the new dial holds no sector for
// is dropped, and Model names Smooth and Invert as the Model tool reads them.
@(test)
each_space_has_its_own_dial :: proc(t: ^testing.T) {
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	k.dials = DIAL_DEFAULTS
	for h in Hands do testing.expect(t, dial_is_default(k, h))
	testing.expect(t, dial_has(k, .Mask))
	r := Modifier_Rail{center = {100, 100}, outer = 200, hole = 60}
	m, ok := rail_hit(&r, dial_of(k)^, {50, 100})
	testing.expect(t, ok && m == .Mask, "Sculpt's left sector is Mask")
	a.rail.latched = {.Hide}
	space_switch(a, .Model)
	testing.expect_value(t, a.tool, Tool.Model)
	testing.expect(t, dial_of(k) == &k.dials[.Model])
	_, ok = rail_hit(&r, dial_of(k)^, {50, 100})
	testing.expect(t, !ok, "Model's left sector is the Select action, a command")
	testing.expect_value(t, a.rail.latched, Modifiers{})
	testing.expect_value(t, modifier_name(a, .Smooth), "Snap")
	testing.expect_value(t, modifier_name(a, .Invert), "Alt")
	a.rail.latched = {.Invert}
	space_switch(a, .Render)
	testing.expect_value(t, a.rail.latched, Modifiers{})
	_, ok = rail_hit(&r, dial_of(k)^, {100, 50})
	testing.expect(t, !ok, "Render's top sector is Place highlight, a command")
	space_switch(a, .Sculpt)
	testing.expect_value(t, modifier_name(a, .Smooth), "Smooth")
}

// The dials round-trip through settings as dial lines, each hands' written whole; a file
// with only Sculpt's dial changed leaves the others as they come.
@(test)
the_dials_read_back :: proc(t: ^testing.T) {
	path := "build/dials_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	a.kit.dials = DIAL_DEFAULTS
	a.kit.dials[.Sculpt][3] = Modifier.Hide
	testing.expect(t, settings_save(a, path))
	b := spaces_app()
	defer spaces_app_free(b)
	b.kit.dials = DIAL_DEFAULTS
	settings_load(b, path)
	testing.expect(t, b.kit.dials == a.kit.dials, "only Sculpt's dial changed")

	a.kit.dials[.Model][0] = Bar_Slot{.Frame_All, 0}
	a.kit.dials[.Look][2] = Modifier.Smooth
	testing.expect(t, settings_save(a, path))
	c := spaces_app()
	defer spaces_app_free(c)
	c.kit.dials = DIAL_DEFAULTS
	settings_load(c, path)
	testing.expect(t, c.kit.dials == a.kit.dials, "every dial read back")

}

// Render's shelf is a page of its own, with no tool strip: a fresh one holds the renders,
// looks and Exposure, and a changed one round-trips by its zone name.
@(test)
render_has_its_own_shelf_page :: proc(t: ^testing.T) {
	path := "build/render_shelf_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	testing.expect_value(t, shelf_which(.Render), Bar_Which.Shelf_Render)
	a := spaces_app()
	defer spaces_app_free(a)
	testing.expect_value(t, len(shelf_pages(&a.kit, .Render)), 1)
	testing.expect_value(t, shelf_pages(&a.kit, .Render)[0], Shelf_Page.Render)
	used := bar_used(a, .Shelf_Render)
	testing.expect_value(t, len(used), 12)
	testing.expect_value(t, used[0], Bar_Slot{.Studio_Render, 0})
	testing.expect(t, slice.contains(used, value_slot(.Exposure)))
	space_switch(a, .Render)
	testing.expect_value(t, a.kit.shelf.page, Shelf_Page.Render)
	bar_remove(a, .Shelf_Render, 0)
	testing.expect(t, bar_changed(a, .Shelf_Render))
	testing.expect(t, settings_save(a, path))
	b := spaces_app()
	defer spaces_app_free(b)
	settings_load(b, path)
	testing.expect_value(t, bar_names(b, .Shelf_Render), bar_names(a, .Shelf_Render))
}

// Place highlight from the dial works with the Lights section closed: turning it on opens
// the section, since a press is the lights' only while it shows, and with the switch on but
// the section closed the command opens the section rather than switching off.
@(test)
place_light_opens_the_lights :: proc(t: ^testing.T) {
	a := spaces_app()
	defer spaces_app_free(a)
	a.scene.lights.count = 1
	card_close(a, .Light)
	testing.expect(t, !lights_section_shown(a))
	command_run(a, .Place_Light)
	testing.expect(t, a.ui.light_place && lights_section_shown(a))
	testing.expect(t, command_checked(a, .Place_Light, 0))
	card_close(a, .Light)
	command_run(a, .Place_Light)
	testing.expect(t, a.ui.light_place && lights_section_shown(a), "the closed section opened again")
	command_run(a, .Place_Light)
	testing.expect(t, !a.ui.light_place)
}
