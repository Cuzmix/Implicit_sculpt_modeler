package main

import "core:strings"

// The views Focus and Inspect: they change what shows, never the layout, so the tab's dot
// stays as it was, and a workspace switch or a layout put in place ends them.

FOCUS_ZONES :: bit_set[Zone]{.Brush_Bar, .View_Bar, .Action_Bar}
INSPECT_ZONES :: bit_set[Zone]{.Brush_Bar, .Dock}
// Inspect's panes, as round 2's Inspect view had them (its inspect2 screen): the
// main view shaded, then curvature, normals and a front silhouette.
INSPECT_PANES :: "panes h500 v500 0 1 v500 2 3\npane 1 Follow Curvature\npane 2 Follow Normals\npane 3 Front Silhouette\n"

Inspect_View :: struct {
	on:     bool,
	before: string, // the grid's layout lines as Inspect found them (heap), put back after
}

// Turns Focus and Inspect off, as a workspace switch or a layout put in place does.
view_toggles_off :: proc(k: ^Kit_State) {
	k.focus_mode = false
	inspect_set(k, false)
}

// Turns Inspect on or off: on, the panes show the form four ways and the brush bar and
// dock stand aside; off, the grid goes back to what it was.
inspect_set :: proc(k: ^Kit_State, on: bool) {
	iv := &k.inspect
	if on == iv.on do return
	if on {
		delete(iv.before)
		iv.before = strings.clone(grid_layout_lines(k))
		grid_lines_put(k, INSPECT_PANES)
	} else {
		grid_lines_put(k, iv.before)
		delete(iv.before)
		iv.before = ""
	}
	iv.on = on
}

// Puts the grid that `text`'s panes, grid and pane lines describe in place (one view for
// none), as a layout does.
@(private = "file")
grid_lines_put :: proc(k: ^Kit_State, text: string) {
	k.grid.tree, k.grid.maximised = grid_preset_tree(.Single), 0
	k.grid.serial += 1
	grid_undo_clear(&k.grid)
	for line in strings.split_lines(text, context.temp_allocator) {
		f := strings.fields(line, context.temp_allocator)
		if len(f) > 0 do grid_layout_read(k, f)
	}
}

views_destroy :: proc(k: ^Kit_State) {
	delete(k.inspect.before)
	k.inspect = {}
}
