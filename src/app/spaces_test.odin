package main

import "core:os"
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

// A file from before spaces: four built-ins (Sculpt, Focus, Inspect, Studio) then the own
// ones. Studio's changes become Render's, the own ones move down a slot, a changed Focus
// becomes an own workspace, and Inspect current comes back as Sculpt with Inspect on.
@(test)
a_settings_file_from_before_spaces_moves_its_workspaces :: proc(t: ^testing.T) {
	path := "build/spaces_old_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	focus := "hidden Brush_Bar View_Bar\nopen Stats\n"
	studio := "open Thumbnail Stats\n"
	mine := "open Colors\n"
	text := strings.concatenate({
		"version 3\n",
		"workspace_saved 1 ", preset_escape(focus), "\n",
		"workspace_saved 3 ", preset_escape(studio), "\n",
		"workspace 4 Mine\n",
		"workspace_saved 4 ", preset_escape(mine), "\n",
		"workspace_current 2\n",
	}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)text)
	a := new(App)
	defer free(a)
	panels_default(&a.kit)
	workspaces_init(&a.kit)
	defer workspaces_destroy(&a.kit)
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
