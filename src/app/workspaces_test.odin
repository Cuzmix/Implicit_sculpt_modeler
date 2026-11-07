package main

import "core:os"
import "core:slice"
import "core:testing"

import "../sculpt"

// The starting workspaces' slots.
SLOT_SCULPT :: 0
SLOT_MODEL :: 1
SLOT_RENDER :: 2

@(private = "file")
workspaces_app :: proc(follow := true) -> ^App {
	a := new(App)
	k := &a.kit
	bars_reset(k)
	panels_default(k)
	layouts_init(k)
	a.tool = .Brush
	a.brush.kind = .Clay
	if follow do workspace_follow(a)
	return a
}

@(private = "file")
workspaces_app_free :: proc(a: ^App) {
	// What the layouts' steps and results kept, as the app frees them on exit.
	grid_undo_destroy(&a.kit.grid)
	results_destroy(a)
	layouts_destroy(&a.kit)
	free(a)
}

@(test)
the_tool_picks_its_space :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)

	// The Model tool is Model; Move keeps the space it is picked in.
	model_pick_action(a, .Inset)
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)
	a.tool = .Move
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)

	// A brush is Sculpt again, and the shelf is back on a Sculpt page.
	command_run(a, .Brush, int(sculpt.Brush_Kind.Draw))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	testing.expect(t, k.shelf.page != .Model)
	testing.expect_value(t, k.workspaces.switches, 2)
}

@(test)
a_tab_gives_the_workspace_its_tool_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	command_run(a, .Workspace_Switch, SLOT_MODEL)
	testing.expect_value(t, a.tool, Tool.Model)
	testing.expect_value(t, k.shelf.page, Shelf_Page.Model)
	model_pick_action(a, .Bridge)
	workspace_follow(a)
	command_run(a, .Workspace_Switch, SLOT_SCULPT)
	testing.expect_value(t, a.tool, Tool.Brush)
	testing.expect_value(t, a.brush.kind, sculpt.Brush_Kind.Clay)
	command_run(a, .Workspace_Switch, SLOT_MODEL)
	testing.expect_value(t, a.model.action, Model_Action.Bridge)

	// Render gives the Look tool; a brush picked there goes back to Sculpt with it, and
	// Sculpt's tab gives back the brush, never the Look tool.
	command_run(a, .Workspace_Switch, SLOT_SCULPT)
	command_run(a, .Workspace_Switch, SLOT_RENDER)
	testing.expect_value(t, a.tool, Tool.Look)
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_RENDER)
	command_run(a, .Workspace_Switch, SLOT_SCULPT)
	testing.expect_value(t, a.tool, Tool.Brush)
	command_run(a, .Tool_Look, 0)
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_RENDER)
	command_run(a, .Brush, int(sculpt.Brush_Kind.Clay))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	testing.expect_value(t, a.tool, Tool.Brush)

	// Adding a cage puts the Model tool in hand, and Model follows.
	command_run(a, .Add_Cage, 0)
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)
	testing.expect_value(t, a.tool, Tool.Model)
}

// Each space keeps its own layout: a change made in Model is kept when Sculpt is picked
// and comes back with Model, the tabs' dots say which spaces differ from how they ship,
// and Reset layout puts the current one back as it ships.
@(test)
each_space_comes_back_on_its_own_layout :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	layouts_frame(k)
	for slot in workspace_tabs(k) do testing.expect(t, !layout_changed(k, slot), "every workspace starts as it ships")
	command_run(a, .Workspace_Switch, SLOT_MODEL)
	command_run(a, .Second_View, 0)
	layouts_frame(k)
	testing.expect(t, layout_changed(k, SLOT_MODEL))
	testing.expect(t, command_enabled(a, .Layout_Reset, 0))
	command_run(a, .Workspace_Switch, SLOT_SCULPT)
	layouts_frame(k)
	testing.expect_value(t, grid_panes(&k.grid), 1)
	testing.expect(t, !layout_changed(k, SLOT_SCULPT))
	testing.expect(t, layout_changed(k, SLOT_MODEL), "Model's dot stays while Sculpt is in front")
	command_run(a, .Workspace_Switch, SLOT_MODEL)
	layouts_frame(k)
	testing.expect(t, grid_panes(&k.grid) == 2, "Model's own layout did not come back")
	command_run(a, .Layout_Reset, 0)
	layouts_frame(k)
	testing.expect_value(t, grid_panes(&k.grid), 1)
	testing.expect(t, !layout_changed(k, SLOT_MODEL))
	testing.expect_value(t, k.layouts.resets, 1)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)
}

// Each space's layout round-trips through settings, as does the space in front.
@(test)
the_layouts_read_back :: proc(t: ^testing.T) {
	path := "build/layouts_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	command_run(a, .Workspace_Switch, SLOT_MODEL)
	command_run(a, .Second_View, 0)
	command_run(a, .Workspace_Switch, SLOT_RENDER)
	testing.expect(t, settings_save(a, path))
	b := workspaces_app()
	defer workspaces_app_free(b)
	settings_load(b, path)
	k := &b.kit
	layouts_frame(k)
	testing.expect_value(t, k.workspaces.current, SLOT_RENDER)
	testing.expect(t, !layout_changed(k, SLOT_RENDER))
	testing.expect(t, layout_changed(k, SLOT_MODEL))
	command_run(b, .Workspace_Switch, SLOT_MODEL)
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
	a := workspaces_app()
	defer workspaces_app_free(a)
	command_run(a, .Workspace_Switch, SLOT_RENDER)
	testing.expect(t, settings_save(a, path))
	b := workspaces_app(follow = false)
	defer workspaces_app_free(b)
	settings_load(b, path)
	b.tool = .Brush
	workspace_follow(b)
	testing.expect_value(t, b.kit.workspaces.current, SLOT_RENDER)
	testing.expect_value(t, b.tool, Tool.Look)
	testing.expect_value(t, b.kit.workspaces.switches, 0)
	c := workspaces_app(follow = false)
	defer workspaces_app_free(c)
	workspace_follow(c)
	testing.expect_value(t, c.tool, Tool.Brush)
}

// Each kind of work has its own dial: switching space puts other hands to work with its
// tool and switches the sectors the rail reads, a latch the new dial holds no sector for
// is dropped, and Model names Smooth and Invert as the Model tool reads them.
@(test)
each_space_has_its_own_dial :: proc(t: ^testing.T) {
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	k.dials = DIAL_DEFAULTS
	for h in Hands do testing.expect(t, dial_is_default(k, h))
	testing.expect(t, dial_has(k, .Mask))
	r := Modifier_Rail{center = {100, 100}, outer = 200, hole = 60}
	m, ok := rail_hit(&r, dial_of(k)^, {50, 100})
	testing.expect(t, ok && m == .Mask, "Sculpt's left sector is Mask")
	a.rail.latched = {.Hide}
	workspace_switch(a, SLOT_MODEL)
	testing.expect_value(t, a.tool, Tool.Model)
	testing.expect(t, dial_of(k) == &k.dials[.Model])
	_, ok = rail_hit(&r, dial_of(k)^, {50, 100})
	testing.expect(t, !ok, "Model's left sector is the Select action, a command")
	testing.expect_value(t, a.rail.latched, Modifiers{})
	testing.expect_value(t, modifier_name(a, .Smooth), "Snap")
	testing.expect_value(t, modifier_name(a, .Invert), "Alt")
	a.rail.latched = {.Invert}
	workspace_switch(a, SLOT_RENDER)
	testing.expect_value(t, a.rail.latched, Modifiers{})
	_, ok = rail_hit(&r, dial_of(k)^, {100, 50})
	testing.expect(t, !ok, "Render's top sector is Place highlight, a command")
	workspace_switch(a, SLOT_SCULPT)
	testing.expect_value(t, modifier_name(a, .Smooth), "Smooth")
}

// The dials round-trip through settings as dial lines, each hands' written whole; a file
// with only Sculpt's dial changed leaves the others as they come.
@(test)
the_dials_read_back :: proc(t: ^testing.T) {
	path := "build/dials_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	a.kit.dials = DIAL_DEFAULTS
	a.kit.dials[.Sculpt][3] = Modifier.Hide
	testing.expect(t, settings_save(a, path))
	b := workspaces_app()
	defer workspaces_app_free(b)
	b.kit.dials = DIAL_DEFAULTS
	settings_load(b, path)
	testing.expect(t, b.kit.dials == a.kit.dials, "only Sculpt's dial changed")

	a.kit.dials[.Model][0] = Bar_Slot{.Frame_All, 0}
	a.kit.dials[.Look][2] = Modifier.Smooth
	testing.expect(t, settings_save(a, path))
	c := workspaces_app()
	defer workspaces_app_free(c)
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
	a := workspaces_app()
	defer workspaces_app_free(a)
	testing.expect_value(t, len(shelf_pages(&a.kit)), 3)
	command_run(a, .Workspace_Switch, SLOT_RENDER)
	testing.expect_value(t, len(shelf_pages(&a.kit)), 1)
	testing.expect_value(t, shelf_pages(&a.kit)[0], Shelf_Page.Render)
	command_run(a, .Workspace_Switch, SLOT_SCULPT)
	used := bar_used(a, .Shelf_Render)
	testing.expect_value(t, len(used), 12)
	testing.expect_value(t, used[0], Bar_Slot{.Studio_Render, 0})
	testing.expect(t, slice.contains(used, value_slot(.Exposure)))
	workspace_switch(a, SLOT_RENDER)
	testing.expect_value(t, a.kit.shelf.page, Shelf_Page.Render)
	bar_remove(a, .Shelf_Render, 0)
	testing.expect(t, bar_changed(a, .Shelf_Render))
	testing.expect(t, settings_save(a, path))
	b := workspaces_app()
	defer workspaces_app_free(b)
	settings_load(b, path)
	testing.expect_value(t, bar_names(b, .Shelf_Render), bar_names(a, .Shelf_Render))
}

// Place highlight from the dial works with the Lights section closed: turning it on opens
// the section, since a press is the lights' only while it shows, and with the switch on but
// the section closed the command opens the section rather than switching off.
@(test)
place_light_opens_the_lights :: proc(t: ^testing.T) {
	a := workspaces_app()
	defer workspaces_app_free(a)
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

// Loads settings text `text` into a fresh app, as a file of that text would be read.
@(private = "file")
workspaces_from_text :: proc(t: ^testing.T, text: string, path: string) -> ^App {
	testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
	a := workspaces_app(follow = false)
	settings_load(a, path)
	workspace_follow(a)
	return a
}

// The workspaces round-trip through settings: a workspace of the person's own (its name,
// colour, tie, base and changed layout), the order of the tabs and the one in front; a
// deleted starter stays deleted.
@(test)
workspaces_read_back :: proc(t: ^testing.T) {
	path := "build/workspaces_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	text := "workspace 1 Sculpt 0 Sculpt Brushes,Curve,Insert\n" +
		"workspace 5 Big%20view 3 None Model\n" +
		"workspace_base 5 Desktop hidden%20Brush_Bar%0Ashelf%20Model%0Abars%0A\n" +
		"workspace_base 5 Tablet hidden%20Brush_Bar%0Ashelf%20Model%0Abars%0A\n" +
		"workspace_layout 5 Desktop hidden%20Brush_Bar%20View_Bar%0Ashelf%20Model%0Abars%0A\n" +
		"workspace_order 5 1\n" +
		"workspace_current 5\n"
	a := workspaces_from_text(t, text, path)
	defer workspaces_app_free(a)
	k := &a.kit
	testing.expect(t, slice.equal(workspace_tabs(k), []int{4, 0}), "the order read back, Model and Render gone")
	testing.expect_value(t, k.workspaces.current, 4)
	w := workspace_now(k)
	testing.expect_value(t, w.name, "Big view")
	testing.expect_value(t, w.tint, 3)
	testing.expect_value(t, w.ties, bit_set[Tie]{.Model})
	testing.expect(t, .View_Bar in k.hidden, "its changed layout is in place")
	layouts_frame(k)
	testing.expect(t, layout_changed(k, 4), "it differs from its base")
	testing.expect_value(t, a.tool, Tool.Model)
	testing.expect(t, settings_save(a, path))
	b := workspaces_from_text(t, string(os.read_entire_file(path, context.temp_allocator) or_else nil), "build/workspaces_test_b.txt")
	defer os.remove("build/workspaces_test_b.txt")
	defer workspaces_app_free(b)
	testing.expect(t, slice.equal(workspace_tabs(&b.kit), []int{4, 0}))
	testing.expect_value(t, workspace_now(&b.kit).base, w.base)
	testing.expect(t, .View_Bar in b.kit.hidden)
}

// A file whose workspace lines are all refused keeps the starters; one line of each kind of
// fault is passed over alone; an order naming a free slot or one twice is cut, a workspace
// it leaves out goes at the end, and a free slot in front gives way to the first tab.
@(test)
workspace_lines_refused_and_repaired :: proc(t: ^testing.T) {
	path := "build/workspaces_refused_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	bad := "workspace 0 Zero 0 None -\n" +
		"workspace 13 Thirteen 0 None -\n" +
		"workspace 2 %20 0 None -\n" +
		"workspace 3 Odd 0 Painting -\n" +
		"workspace 4 Odd 0 None Strokes\n" +
		"workspace 6 Two##ids 0 None -\n"
	a := workspaces_from_text(t, bad, path)
	defer workspaces_app_free(a)
	testing.expect(t, slice.equal(workspace_tabs(&a.kit), []int{0, 1, 3, 2}), "the starters, Paint before Render")

	fixable := "workspace 2 Sculpt 0 Sculpt Brushes,Curve,Insert\n" +
		"workspace 3 sculpt 1 None -\n" +
		"workspace 4 Look 2 Render Look,Brushes\n" +
		"workspace 6 Second 2 Render Look\n" +
		"workspace_layout 9 Desktop hidden%20Dock%0A\n" +
		"workspace_order 6 6 9\n" +
		"workspace_current 9\n"
	b := workspaces_from_text(t, fixable, path)
	defer workspaces_app_free(b)
	k := &b.kit
	testing.expect(t, slice.equal(workspace_tabs(k), []int{5, 1}), "the order cut and the rest after it")
	testing.expect(t, !workspace_used(k, 2), "a name taken in another case")
	testing.expect(t, !workspace_used(k, 3), "a tie another holds")
	testing.expect_value(t, k.workspaces.current, 5)
	testing.expect_value(t, workspace_now(k).ties, bit_set[Tie]{.Look})
}

// Picking tools follows the ties: a brush in a workspace tied to nothing stays there, as do
// Move, Mask and Smooth anywhere; the Model tool goes to the workspace that holds its tie,
// and a brush then goes back to Sculpt, the tie having changed.
@(test)
ties_bring_their_workspace :: proc(t: ^testing.T) {
	path := "build/workspaces_ties_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	text := "workspace 1 Sculpt 0 Sculpt Brushes,Curve,Insert\n" +
		"workspace 2 Model 1 Model Model\n" +
		"workspace 4 Mine 3 None -\n" +
		"workspace_order 1 2 4\n" +
		"workspace_current 1\n"
	a := workspaces_from_text(t, text, path)
	defer workspaces_app_free(a)
	k := &a.kit
	command_run(a, .Workspace_Switch, 3)
	testing.expect_value(t, a.tool, Tool.Brush)
	for kind in ([]sculpt.Brush_Kind{.Draw, .Smooth, .Mask, .Inflate}) {
		command_run(a, .Brush, int(kind))
		workspace_follow(a)
		testing.expect_value(t, k.workspaces.current, 3)
	}
	command_run(a, .Tool_Move, 0)
	workspace_follow(a)
	command_run(a, .Brush, int(sculpt.Brush_Kind.Clay))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, 3)
	command_run(a, .Tool_Model, 0)
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)
	command_run(a, .Brush, int(sculpt.Brush_Kind.Smooth))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)
	command_run(a, .Brush, int(sculpt.Brush_Kind.Draw))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	// Nothing switches while a stroke goes on: the switch waits for its end.
	a.stroke.active = true
	command_run(a, .Tool_Model, 0)
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	a.stroke.active = false
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_MODEL)
}

// The Paint brush brings Paint, on its shelf's Paint page; Smooth and Mask in Paint keep it
// there, and a sculpting brush goes back to Sculpt. Paint's tab gives back the Paint brush.
@(test)
the_paint_brush_brings_paint :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	slot_paint := workspace_tabs(k)[2]
	testing.expect_value(t, k.workspaces.list[slot_paint].name, "Paint")
	command_run(a, .Brush, int(sculpt.Brush_Kind.Paint))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, slot_paint)
	testing.expect_value(t, k.shelf.page, Shelf_Page.Paint)
	for kind in ([]sculpt.Brush_Kind{.Smooth, .Mask, .Paint}) {
		command_run(a, .Brush, int(kind))
		workspace_follow(a)
		testing.expect_value(t, k.workspaces.current, slot_paint)
	}
	command_run(a, .Brush, int(sculpt.Brush_Kind.Clay))
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	command_run(a, .Workspace_Switch, slot_paint)
	testing.expect_value(t, a.tool, Tool.Brush)
	testing.expect_value(t, a.brush.kind, sculpt.Brush_Kind.Paint)
}

// Each workspace keeps a desktop and a tablet layout apart: a change made under one class is
// not in the other, Layouts for switches between them as a workspace switch would, and both
// round-trip through settings.
@(test)
desktop_and_tablet_layouts_are_kept_apart :: proc(t: ^testing.T) {
	path := "build/workspaces_class_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	testing.expect_value(t, k.workspaces.class, Layout_Class.Desktop)
	command_run(a, .Second_View, 0)
	layouts_frame(k)
	testing.expect(t, layout_changed(k, SLOT_SCULPT))
	k.layouts_for = .Tablet
	workspace_follow(a)
	testing.expect_value(t, k.workspaces.class, Layout_Class.Tablet)
	testing.expect(t, grid_panes(&k.grid) == 1, "the tablet layout has one view")
	layouts_frame(k)
	testing.expect(t, !layout_changed(k, SLOT_SCULPT))
	testing.expect(t, settings_save(a, path))
	k.layouts_for = .Desktop
	workspace_follow(a)
	testing.expect(t, grid_panes(&k.grid) == 2, "the desktop layout keeps its two views")
	b := workspaces_from_text(t, string(os.read_entire_file(path, context.temp_allocator) or_else nil), "build/workspaces_class_b.txt")
	defer os.remove("build/workspaces_class_b.txt")
	defer workspaces_app_free(b)
	testing.expect_value(t, b.kit.workspaces.class, Layout_Class.Tablet)
	testing.expect(t, grid_panes(&b.kit.grid) == 1)
	b.kit.layouts_for = .Desktop
	workspace_follow(b)
	testing.expect(t, grid_panes(&b.kit.grid) == 2, "the desktop layout read back")
}

// A new workspace copies the layout in front and is tied to nothing; one from a starter
// takes the starter's ties no other holds, so a deleted Model comes back as it was; renames
// refuse a taken name; Delete gives the one in front's place to its left neighbour, its
// Undo puts it back (not in front), and the last workspace stays.
@(test)
workspaces_made_renamed_and_deleted :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a := workspaces_app()
	defer workspaces_app_free(a)
	k := &a.kit
	command_run(a, .Second_View, 0)
	testing.expect(t, workspace_new(a, "", .None))
	mine := k.workspaces.current
	testing.expect_value(t, k.workspaces.list[mine].name, "Workspace 5")
	testing.expect(t, slice.equal(workspace_tabs(k)[:2], []int{SLOT_SCULPT, mine}), "after the tab in front")
	testing.expect_value(t, k.workspaces.list[mine].ties, bit_set[Tie]{})
	testing.expect(t, grid_panes(&k.grid) == 2, "a copy of the layout in front")
	layouts_frame(k)
	testing.expect(t, !layout_changed(k, mine), "its base is the copy")
	testing.expect(t, !workspace_new(a, "sculpt", .None), "a name taken")
	testing.expect(t, !workspace_rename(a, mine, "MODEL"))
	testing.expect(t, !workspace_rename(a, mine, "Two##ids"))
	testing.expect(t, workspace_rename(a, mine, "  Big view "))
	testing.expect_value(t, k.workspaces.list[mine].name, "Big view")

	// Model goes, its tie with it; a new one from Model brings it back with the tie.
	workspace_delete(a, SLOT_MODEL)
	testing.expect_value(t, workspace_holding(k, .Model), -1)
	testing.expect(t, workspace_new(a, "Model", .Model))
	model := k.workspaces.current
	testing.expect_value(t, workspace_holding(k, .Model), model)
	testing.expect_value(t, a.tool, Tool.Model)
	// A tie ticked elsewhere moves.
	workspace_tie_toggle(a, mine, .Model)
	testing.expect_value(t, workspace_holding(k, .Model), mine)
	testing.expect_value(t, k.workspaces.list[model].ties, bit_set[Tie]{})

	// Deleting the one in front shows its left neighbour; Undo puts it back where it was.
	workspace_switch(a, mine)
	before := slice.clone(workspace_tabs(k), context.temp_allocator)
	workspace_delete(a, mine)
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	testing.expect(t, !workspace_used(k, mine))
	workspace_undo(a)
	testing.expect(t, slice.equal(workspace_tabs(k), before), "back in its place")
	testing.expect_value(t, k.workspaces.current, SLOT_SCULPT)
	testing.expect_value(t, workspace_holding(k, .Model), mine)
	// An Undo whose name was taken meanwhile is refused.
	workspace_delete(a, mine)
	testing.expect(t, workspace_new(a, "Big view", .None))
	workspace_undo(a)
	testing.expect_value(t, len(workspace_tabs(k)), len(before))
	// The last one stays.
	for len(workspace_tabs(k)) > 1 do workspace_delete(a, workspace_tabs(k)[0])
	last := workspace_tabs(k)[0]
	workspace_delete(a, last)
	testing.expect(t, workspace_used(k, last))
}
