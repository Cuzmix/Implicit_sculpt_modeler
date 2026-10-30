package main

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "../sculpt"

@(private = "file")
spaces_app :: proc() -> ^App {
	a := new(App)
	k := &a.kit
	bars_reset(k)
	panels_default(k)
	k.inspector = true
	workspaces_init(k)
	a.tool = .Brush
	a.brush.kind = .Clay
	space_follow(a)
	return a
}

@(private = "file")
spaces_app_free :: proc(a: ^App) {
	workspaces_destroy(&a.kit)
	free(a)
}

@(test)
the_tool_picks_its_space :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	testing.expect_value(t, k.spaces.current, Space.Sculpt)

	// The Model tool is Model, with Model's layout; Move keeps the space it is picked in.
	model_pick_action(a, .Inset)
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Model)
	testing.expect_value(t, k.workspaces.current, int(Built_In.Model))
	a.tool = .Move
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Model)

	// A brush is Sculpt again, and the shelf is back on a Sculpt page.
	command_run(a, .Brush, int(sculpt.Brush_Kind.Draw))
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Sculpt)
	testing.expect_value(t, k.workspaces.current, int(Built_In.Sculpt))
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

	// Render keeps the tool in hand; a brush picked there, even the one in hand, goes back
	// to Sculpt.
	command_run(a, .Space_Switch, int(Space.Sculpt))
	command_run(a, .Space_Switch, int(Space.Render))
	testing.expect_value(t, a.tool, Tool.Brush)
	testing.expect_value(t, k.workspaces.current, int(Built_In.Render))
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Render)
	command_run(a, .Brush, int(sculpt.Brush_Kind.Clay))
	space_follow(a)
	testing.expect_value(t, k.spaces.current, Space.Sculpt)

	// Adding a cage goes to Model.
	command_run(a, .Add_Cage, 0)
	testing.expect_value(t, k.spaces.current, Space.Model)
	testing.expect_value(t, a.tool, Tool.Model)
}

@(test)
each_space_comes_back_on_its_own_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	command_run(a, .Space_Switch, int(Space.Model))
	k.stats = true
	testing.expect(t, workspace_save_as(k))
	mine := k.workspaces.current
	testing.expect_value(t, workspace_space(k, mine), Space.Model)
	command_run(a, .Space_Switch, int(Space.Sculpt))
	testing.expect(t, !k.stats)
	command_run(a, .Space_Switch, int(Space.Model))
	testing.expect_value(t, k.workspaces.current, mine)
	testing.expect(t, k.stats, "Model's own layout did not come back")
	// Deleting it leaves Model on its built-in.
	workspace_delete(k)
	testing.expect_value(t, k.workspaces.current, int(Built_In.Model))
	testing.expect_value(t, k.spaces.current, Space.Model)
}

@(test)
names_of_the_old_workspaces_still_read :: proc(t: ^testing.T) {
	id, arg, ok := command_from_name("Workspace:Studio")
	testing.expect(t, ok && id == .Workspace && arg == int(Built_In.Render))
	id, _, ok = command_from_name("Workspace:Focus")
	testing.expect(t, ok && id == .Focus_Mode)
	id, _, ok = command_from_name("Workspace:Inspect")
	testing.expect(t, ok && id == .Inspect_Mode)
	id, arg, ok = command_from_name(command_name(.Space_Switch, int(Space.Render)))
	testing.expect(t, ok && id == .Space_Switch && arg == int(Space.Render))
}

// A file from before spaces (version 3, and 4, the brush engine's spacing): four built-ins
// (Sculpt, Focus, Inspect, Studio) then the own ones. Studio's changes become Render's, the
// own ones move down a slot, a changed Focus becomes an own workspace, and Inspect current
// comes back as Sculpt with Inspect on.
@(test)
a_settings_file_from_before_spaces_moves_its_workspaces :: proc(t: ^testing.T) {
	path := "build/spaces_old_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	focus := "hidden Brush_Bar View_Bar\nopen Stats\n"
	studio := "open Thumbnail Stats\n"
	mine := "open Colors\n"
	for version in ([]string{"version 3\n", "version 4\n"}) {
		text := strings.concatenate({
			version,
			"workspace_saved 1 ", preset_escape(focus), "\n",
			"workspace_saved 3 ", preset_escape(studio), "\n",
			"workspace 4 Mine\n",
			"workspace_saved 4 ", preset_escape(mine), "\n",
			"workspace_current 2\n",
		}, context.temp_allocator)
		_ = os.write_entire_file(path, transmute([]u8)text)
		a := new(App)
		panels_default(&a.kit)
		workspaces_init(&a.kit)
		settings_load(a, path)
		k := &a.kit
		w := &k.workspaces
		testing.expect_value(t, workspace_name(k, len(Built_In)), "Mine")
		testing.expect(t, w.list[len(Built_In)].saved == mine)
		testing.expect(t, w.list[int(Built_In.Render)].saved == studio)
		testing.expect_value(t, workspace_name(k, len(Built_In) + 1), "Focus")
		testing.expect(t, w.list[len(Built_In) + 1].saved == focus)
		testing.expect_value(t, w.current, int(Built_In.Sculpt))
		testing.expect(t, k.inspect.on, "Inspect current did not come back as the view")
		testing.expect_value(t, k.spaces.current, Space.Sculpt)
		workspaces_destroy(k)
		free(a)
	}
}

// A script written before spaces names the old workspaces: Focus and Inspect turn their
// views on, Studio is Render's layout, and the new names read as they say.
@(test)
old_workspace_names_in_a_script_still_run :: proc(t: ^testing.T) {
	s := script_parse("workspace focus\nworkspace inspect\nworkspace studio\nspace_switch model\nfocus_mode off", "old")
	defer script_destroy(&s)
	testing.expect_value(t, len(s.errors), 0)
	if !testing.expect_value(t, len(s.statements), 5) do return
	st := s.statements
	testing.expect_value(t, st[0].command, Command_Id.Focus_Mode)
	testing.expect_value(t, st[0].toggle, Script_Toggle.On)
	testing.expect_value(t, st[1].command, Command_Id.Inspect_Mode)
	testing.expect_value(t, st[1].toggle, Script_Toggle.On)
	testing.expect_value(t, st[2].command, Command_Id.Workspace)
	testing.expect_value(t, st[2].arg, int(Built_In.Render))
	testing.expect_value(t, st[3].command, Command_Id.Space_Switch)
	testing.expect_value(t, Space(st[3].arg), Space.Model)
	testing.expect_value(t, st[4].command, Command_Id.Focus_Mode)
	testing.expect_value(t, st[4].toggle, Script_Toggle.Off)
}

// Each space has its own dial: switching space switches the sectors the rail reads, a
// latch the new dial holds no sector for is dropped, and Model names Smooth and Invert as
// the Model tool reads them.
@(test)
each_space_has_its_own_dial :: proc(t: ^testing.T) {
	a := spaces_app()
	defer spaces_app_free(a)
	k := &a.kit
	k.dials = DIAL_DEFAULTS
	for s in Space do testing.expect(t, dial_is_default(k, s))
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

// The dials round-trip through settings: Sculpt's as the dial_sector lines an older build
// reads, the others' as dial_space lines; a file of this version with only Sculpt's dial
// changed leaves the others as they come, and a file from before version 6, when one dial
// served every space, gives its changes to all three as far as they mean something there.
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
	a.kit.dials[.Render][2] = Modifier.Smooth
	testing.expect(t, settings_save(a, path))
	c := spaces_app()
	defer spaces_app_free(c)
	c.kit.dials = DIAL_DEFAULTS
	settings_load(c, path)
	testing.expect(t, c.kit.dials == a.kit.dials, "every dial read back")

	old := "version 5\ndial_sector 0 command Frame_All\ndial_sector 1 command Brush_Pie\ndial_sector 2 modifier Invert\ndial_sector 3 modifier Hide\n"
	testing.expect(t, os.write_entire_file(path, transmute([]u8)old) == nil)
	d := spaces_app()
	defer spaces_app_free(d)
	d.kit.dials = DIAL_DEFAULTS
	settings_load(d, path)
	dk := &d.kit
	testing.expect(t, dk.dials[.Sculpt][0] == Bar_Slot{.Frame_All, 0} && dk.dials[.Sculpt][3] == Modifier.Hide)
	testing.expect(t, dk.dials[.Model][0] == Bar_Slot{.Frame_All, 0} && dk.dials[.Model][3] == Modifier.Hide, "Model has the changed sectors")
	testing.expect(t, dk.dials[.Model][2] == DIAL_DEFAULTS[.Model][2], "an unchanged sector keeps Model's own")
	testing.expect(t, dk.dials[.Render][0] == Bar_Slot{.Frame_All, 0}, "Render has the changed command")
	testing.expect(t, dk.dials[.Render][3] == DIAL_DEFAULTS[.Render][3], "but not a modifier")
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
	a.kit.inspector = false
	testing.expect(t, !lights_section_shown(a))
	command_run(a, .Place_Light)
	testing.expect(t, a.ui.light_place && lights_section_shown(a))
	testing.expect(t, command_checked(a, .Place_Light, 0))
	a.kit.inspector = false
	command_run(a, .Place_Light)
	testing.expect(t, a.ui.light_place && lights_section_shown(a), "the closed section opened again")
	command_run(a, .Place_Light)
	testing.expect(t, !a.ui.light_place)
}
