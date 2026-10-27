package main

import "core:os"
import "core:testing"
import "../ui"

@(test)
built_in_workspaces_read_back_as_written :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	for b in Built_In {
		text := built_in_layout(b)
		s: Kit_State
		kit_layout_put(&s, text)
		testing.expectf(t, kit_layout_text(&s) == text, "%v does not read back as written:\n%s", b, text)
	}
	// Sculpt is the layout as it starts: the tray docked on the right, open, and nothing else.
	k: Kit_State
	panels_default(&k)
	k.inspector = true
	testing.expect(t, kit_layout_text(&k) == built_in_layout(.Sculpt), "Sculpt is not the starting layout")
}

@(test)
switching_workspaces_keeps_what_was_left :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	panels_default(k)
	k.inspector = true
	workspaces_init(k)
	defer workspaces_destroy(k)
	w := &k.workspaces
	workspaces_frame(k)
	testing.expect(t, !w.modified, "the starting layout reads as changed")

	// A change lights the dot; Focus hides the bars; back on Sculpt the change is there.
	k.stats = true
	workspaces_frame(k)
	testing.expect(t, w.modified, "opening Stats is no change")
	workspace_switch(k, int(Built_In.Focus))
	testing.expect(t, .Brush_Bar in k.hidden && .View_Bar in k.hidden && !k.inspector && !k.stats, "Focus is not in place")
	testing.expect_value(t, rail_shown(k), k.rail_side)
	workspace_switch(k, int(Built_In.Sculpt))
	workspaces_frame(k)
	testing.expect(t, k.stats && k.hidden == {} && w.modified, "Sculpt lost its change")

	// Revert drops it; Save keeps the next one.
	workspace_revert(k)
	workspaces_frame(k)
	testing.expect(t, !k.stats && !w.modified, "Revert left the change")
	panel_pin_toggle(&a, .Layers)
	workspace_save(k)
	workspaces_frame(k)
	testing.expect(t, !w.modified, "Save left the dot")
	testing.expect(t, command_enabled(&a, .Workspace_Reset), "a changed built-in cannot be reset")
	workspace_reset(k)
	testing.expect(t, !k.panels.pins[.Layers].on && !command_enabled(&a, .Workspace_Reset), "Reset left the pin")

	// Save as new: an own workspace, current, named; the one it came from as saved.
	k.thumbnail = true
	testing.expect(t, workspace_save_as(k), "Save as new found no room")
	testing.expect_value(t, w.current, len(Built_In))
	testing.expect_value(t, workspace_name(k, w.current), "Workspace 1")
	testing.expect(t, w.list[int(Built_In.Sculpt)].live == "", "Save as new left Sculpt changed")
	workspace_rename(k, w.current, "Detail pass")
	testing.expect_value(t, workspace_name(k, w.current), "Detail pass")
	workspace_rename(k, int(Built_In.Focus), "Mine")
	testing.expect_value(t, workspace_name(k, int(Built_In.Focus)), "Focus")

	// Delete goes to Sculpt as saved and frees the slot, which the next Save as new takes.
	workspace_delete(k)
	testing.expect_value(t, w.current, int(Built_In.Sculpt))
	testing.expect(t, !w.list[len(Built_In)].used && !k.thumbnail, "Delete left the workspace or its layout")
	workspace_delete(k)
	testing.expect(t, w.list[int(Built_In.Sculpt)].used, "a built-in was deleted")
}

@(test)
a_workspace_reads_the_same_with_either_hand :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k: Kit_State
	panels_default(&k)
	k.stats = true
	k.windows[.Stats] = {moved = true, x = .Start, offset = {40, 200}}
	right := kit_layout_text(&k)
	// The same place, seen left-handed: on the other side, written as before.
	k.ctx.mirror = true
	window_mirror(&k.windows[.Stats])
	testing.expect(t, kit_layout_text(&k) == right, "a left-handed layout is written differently")
	kit_layout_put(&k, right)
	testing.expect_value(t, k.windows[.Stats].x, ui.Anchor.End)
}

@(test)
workspaces_read_back_what_they_wrote :: proc(t: ^testing.T) {
	path := "build/workspaces_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	a: App
	panels_default(&a.kit)
	a.kit.inspector = true
	workspaces_init(&a.kit)
	defer workspaces_destroy(&a.kit)
	// An own workspace, then Studio changed and left, then the own one changed and current.
	a.kit.stats = true
	_ = workspace_save_as(&a.kit)
	workspace_rename(&a.kit, len(Built_In), "Two words")
	workspace_switch(&a.kit, int(Built_In.Studio))
	a.kit.thumbnail = false
	workspace_switch(&a.kit, len(Built_In))
	a.kit.colors_card = true
	testing.expect(t, settings_save(&a, path))

	b: App
	panels_default(&b.kit)
	workspaces_init(&b.kit)
	defer workspaces_destroy(&b.kit)
	settings_load(&b, path)
	w := &b.kit.workspaces
	testing.expect_value(t, w.current, len(Built_In))
	testing.expect_value(t, workspace_name(&b.kit, w.current), "Two words")
	testing.expect(t, b.kit.stats && b.kit.colors_card, "the current layout came back without its changes")
	workspaces_frame(&b.kit)
	testing.expect(t, w.modified, "the current workspace's changes came back as saved")
	workspace_switch(&b.kit, int(Built_In.Studio))
	testing.expect(t, !b.kit.thumbnail && b.kit.panels.pins[.Lights].on, "Studio came back without how it was left")
}

@(test)
an_older_settings_file_keeps_its_layout_as_sculpt :: proc(t: ^testing.T) {
	path := "build/workspaces_old_test.txt"
	defer os.remove(path)
	defer free_all(context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]u8)string("stats 1\nwindow Stats 1 Start Start 616 264 0\n"))
	a: App
	panels_default(&a.kit)
	a.kit.inspector = true
	workspaces_init(&a.kit)
	defer workspaces_destroy(&a.kit)
	settings_load(&a, path)
	workspaces_frame(&a.kit)
	testing.expect(t, a.kit.stats && !a.kit.workspaces.modified, "an older file's layout shows as a change")
	testing.expect_value(t, a.kit.workspaces.current, int(Built_In.Sculpt))
}
