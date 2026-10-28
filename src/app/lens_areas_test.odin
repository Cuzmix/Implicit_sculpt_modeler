package main

import "core:testing"
import "core:time"

// Every pane gesture keeps the tree whole: the panes shown are 0 to n-1, the main view is
// never closed, and the panes not touched keep their numbers, and so their colours.
@(test)
pane_gestures_keep_the_tree_whole :: proc(t: ^testing.T) {
	g: View_Grid
	grid_reset(&g)
	whole :: proc(t: ^testing.T, g: ^View_Grid, n: int, loc := #caller_location) {
		testing.expect_value(t, grid_panes(g), n, loc = loc)
		for p in 0 ..< n do testing.expectf(t, grid_tree_leaf(&g.tree, p) >= 0, "pane %d is missing", p, loc = loc)
	}
	// A corner drag on the main view splits it; the new pane is numbered after the others.
	testing.expect_value(t, grid_split_pane(&g, 0, true, 0.6, false, {camera = .Front, pass = .Normals}), 1)
	whole(t, &g, 2)
	testing.expect_value(t, grid_shape_name(&g), "Side_By_Side")
	testing.expect_value(t, g.views[0].pass, Second_Pass.Normals)
	// Split the view pane top and bottom, then the main view again: four, and a fifth is refused.
	testing.expect_value(t, grid_split_pane(&g, 1, false, 0.5, true, {camera = .Top}), 2)
	testing.expect_value(t, grid_split_pane(&g, 0, false, 0.5, false, {camera = .Right}), 3)
	whole(t, &g, 4)
	testing.expect_value(t, grid_split_pane(&g, 2, true, 0.5, false, {}), 0)
	// The main view never closes into another; a pane that does not line up does not join.
	testing.expect(t, !grid_joinable(&g, 1, 0))
	testing.expect(t, !grid_join(&g, 3, 2), "panes that share no edge joined")
	// Pane 1 (bottom right) grows over pane 2 (top right): pane 3, the last, takes the
	// number left free with its view, and pane 1 keeps its own.
	testing.expect(t, grid_join(&g, 1, 2))
	whole(t, &g, 3)
	testing.expect_value(t, g.views[1].camera, Second_Camera.Right)
	testing.expect_value(t, g.views[0].camera, Second_Camera.Front)
	// Swap the main view with pane 1: they trade places and views stay with their panes.
	main_before := grid_tree_leaf(&g.tree, 0)
	testing.expect(t, grid_swap(&g, 0, 1))
	testing.expect(t, grid_tree_leaf(&g.tree, 1) == main_before, "pane 1 is not where the main view was")
	testing.expect_value(t, g.views[0].camera, Second_Camera.Front)
	// Dock pane 2 on the left of pane 1: still three, and pane 2 is left of pane 1.
	testing.expect(t, grid_dock(&g, 2, 1, .Left))
	whole(t, &g, 3)
	cells, _ := grid_tree_unit(&g.tree)
	testing.expect(t, cells[2].x + cells[2].w <= cells[1].x + 1e-4, "the docked pane is not left of its target")
	testing.expect(t, abs(cells[2].w - cells[1].w) < 1e-4, "the docked pane does not take half")
	// Closing the side without the main view takes its panes; the main view's side never closes.
	testing.expect(t, !(grid_side_closes(&g.tree, 0, true) && grid_side_closes(&g.tree, 0, false)), "both sides of the main view's split close")
	root := g.tree.nodes[0]
	main_in_b := grid_tree_holds(&g.tree, int(root.b), grid_tree_leaf(&g.tree, 0))
	testing.expect(t, grid_close_side(&g, 0, !main_in_b))
	testing.expect(t, !grid_close_side(&g, 0, main_in_b) || grid_panes(&g) == 1)
	whole(t, &g, grid_panes(&g))
}

// Joining a pane of four lined-up panes into the one below it rebuilds the tree round the
// column it leaves, and an even out gives three across its thirds.
@(test)
a_join_across_rows_and_an_even_out :: proc(t: ^testing.T) {
	g: View_Grid
	grid_reset(&g)
	g.tree = grid_preset_tree(.Four)
	g.views = grid_views_default(.Four)
	// Pane 1 (top right) and pane 3 (bottom right) line up: 1 grows down over 3.
	testing.expect(t, grid_joinable(&g, 1, 3))
	testing.expect(t, grid_join(&g, 1, 3))
	testing.expect_value(t, grid_panes(&g), 3)
	testing.expect_value(t, grid_shape_name(&g), "Custom")
	cells, _ := grid_tree_unit(&g.tree)
	testing.expect(t, abs(cells[1].h - 1) < 1e-4, "the kept pane does not fill the column")
	across := View_Grid{tree = grid_preset_tree(.Three_Across)}
	grid_move_divider(&across.tree, 0, 0.2)
	grid_even(&across, 0)
	cells, _ = grid_tree_unit(&across.tree)
	for i in 0 ..< 3 do testing.expect(t, abs(cells[i].w - 1.0 / 3) < 1e-4, "three across did not even out to thirds")
}

// Undo takes back the layout's steps and the scene's in the order they were made, and Redo
// does them again in that order; a new scene step ends the layout's redo.
@(test)
layout_steps_undo_in_order_with_the_scene :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer delete(app.history.done)
	defer delete(app.history.undone)
	g := &app.kit.grid
	grid_reset(g)
	at := time.tick_now()
	later :: proc(t: time.Tick, ns: i64) -> time.Tick {return {t._nsec + ns}}
	// A stroke, then a split, then another stroke.
	append(&app.history.done, History_Entry{kind = .Stroke, at = later(at, 1)})
	step := grid_step_now(g)
	step.at = later(at, 2)
	_ = grid_split_pane(g, 0, true, 0.5, false, {})
	grid_step_push(g, step)
	append(&app.history.done, History_Entry{kind = .Stroke, at = later(at, 3)})
	// Undo: the stroke first, then the split.
	testing.expect(t, !grid_undo_first(app), "the split went before the stroke made after it")
	append(&app.history.undone, pop(&app.history.done))
	testing.expect(t, grid_undo_first(app), "the split did not come next")
	grid_undo(app)
	testing.expect_value(t, grid_panes(g), 1)
	testing.expect(t, !grid_undo_first(app), "a layout step is left to undo")
	// Redo: the split first (made before the stroke undone), then the stroke.
	testing.expect(t, grid_redo_first(app), "the split was not the first to redo")
	grid_redo(app)
	testing.expect_value(t, grid_panes(g), 2)
	testing.expect(t, !grid_redo_first(app))
	// Undo the split again, then a new layout step: the split can no longer be redone.
	grid_undo(app)
	testing.expect_value(t, g.undo.ahead_n, 1)
	grid_step_push(g, grid_step_now(g))
	testing.expect_value(t, g.undo.ahead_n, 0)
}
