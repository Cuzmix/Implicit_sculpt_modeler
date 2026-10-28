package main

import "core:strings"
import "core:testing"

import "../render"
import "../ui"

@(test)
grid_cells_tile_the_room :: proc(t: ^testing.T) {
	room := ui.Rect{100, 0, 1000, 600}
	for preset in Grid_Preset {
		tree := grid_preset_tree(preset)
		cells, _ := grid_tree_cells(&tree, room)
		n := grid_count(preset)
		testing.expect_value(t, grid_tree_panes(&tree), n)
		area: f32 = 0
		for c, i in cells {
			if i >= n {
				testing.expectf(t, c == {}, "%v: pane %d past the count", preset, i)
				continue
			}
			testing.expectf(t, c.w > 0 && c.h > 0, "%v: pane %d is empty", preset, i)
			testing.expectf(t, c.x >= room.x && c.y >= room.y && c.x + c.w <= room.x + room.w + 0.01 && c.y + c.h <= room.y + room.h + 0.01, "%v: pane %d leaves the room", preset, i)
			area += c.w * c.h
			for d, j in cells[:n] {
				if j == i do continue
				apart := c.x + c.w <= d.x + 0.01 || d.x + d.w <= c.x + 0.01 || c.y + c.h <= d.y + 0.01 || d.y + d.h <= c.y + 0.01
				testing.expectf(t, apart, "%v: panes %d and %d overlap", preset, i, j)
			}
		}
		// The panes and their gaps fill it: no gap wider than GRID_GAP.
		testing.expectf(t, area > room.w * room.h * 0.99 - 2 * GRID_GAP * (room.w + room.h), "%v: the panes leave room unused (%v)", preset, area)
		// The main view is first: top left, the biggest in One plus two.
		testing.expectf(t, cells[0].x == room.x && cells[0].y == room.y, "%v: the main pane is not first", preset)
	}
	plus := grid_preset_tree(.One_Plus_Two)
	big, _ := grid_tree_cells(&plus, room)
	testing.expect(t, big[0].w * big[0].h > 2 * big[1].w * big[1].h, "One plus two's main pane is not the big one")
	across := grid_preset_tree(.Three_Across)
	thirds, _ := grid_tree_cells(&across, room)
	testing.expect(t, abs(thirds[0].w - thirds[1].w) <= GRID_GAP && abs(thirds[1].w - thirds[2].w) <= GRID_GAP, "three across is not in thirds")
}

// A divider keeps every pane a share of the room, and moving one keeps the dividers
// inside it where they were: three across's second stays put while the first moves.
@(test)
grid_dividers_stay_clear_and_keep_the_others :: proc(t: ^testing.T) {
	tree := grid_preset_tree(.Side_By_Side)
	grid_move_divider(&tree, 0, 0.01)
	testing.expect_value(t, tree.nodes[0].share, f32(GRID_PANE_MIN))
	across := grid_preset_tree(.Three_Across)
	_, rooms := grid_tree_unit(&across)
	second := grid_tree_line(&across, rooms, 2)
	grid_move_divider(&across, 0, 0.4)
	_, rooms = grid_tree_unit(&across)
	testing.expect(t, abs(grid_tree_line(&across, rooms, 0) - 0.4) < 1e-5, "the first divider did not move")
	testing.expect(t, abs(grid_tree_line(&across, rooms, 2) - second) < 1e-5, "the second divider moved with the first")
	// It cannot pass the one beyond it.
	grid_move_divider(&across, 0, 0.95)
	_, rooms = grid_tree_unit(&across)
	testing.expect(t, grid_tree_line(&across, rooms, 0) <= second - GRID_PANE_MIN + 1e-5, "the first divider passed the second")
	// A new preset's view panes are the partners: front beside, then the side, then the top.
	testing.expect_value(t, grid_views_default(.Side_By_Side)[0].camera, Second_Camera.Front)
	testing.expect_value(t, grid_views_default(.Four)[2].camera, Second_Camera.Top)
	testing.expect_value(t, grid_views_default(.Four)[1].pass, Second_Pass.Shaded)
}

@(test)
a_layout_keeps_its_grid_and_single_writes_none :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := new(Kit_State)
	defer free(k)
	bars_reset(k)
	panels_default(k)
	grid_reset(&k.grid)
	single := kit_layout_text(k)
	testing.expect(t, !strings.contains(single, "grid") && !strings.contains(single, "pane"), "Single writes grid lines")

	// A preset, a moved split and a pane's own camera and pass come back as they were,
	// and the text reads back to itself, so the modified dot clears.
	_, _ = grid_set(k, .One_Plus_Two)
	k.grid.tree.nodes[0].share = 0.6543
	k.grid.tree.nodes[2].share = 0.3
	k.grid.views[1] = {camera = .Top, pass = .Curvature}
	text := kit_layout_text(k)
	testing.expect(t, strings.contains(text, "panes v654 0 h300 1 2\npane 1 Front Shaded\npane 2 Top Curvature\n"), "the grid lines are not written")
	kit_layout_put(k, single)
	testing.expect_value(t, grid_panes(&k.grid), 1)
	kit_layout_put(k, text)
	testing.expect_value(t, grid_shape_name(&k.grid), "One_Plus_Two")
	testing.expect_value(t, k.grid.views[1].pass, Second_Pass.Curvature)
	testing.expect(t, kit_layout_text(k) == text, "the grid does not read back to itself")

	// A script's or a hand's lower case names it too; a grid line alone gives the partners.
	// An old layout's grid line reads as its preset's tree and is written as one.
	kit_layout_put(k, "grid four\n")
	testing.expect_value(t, grid_shape_name(&k.grid), "Four")
	testing.expect_value(t, k.grid.views[2].camera, Second_Camera.Top)
	kit_layout_put(k, "grid Three_Across 300 700\n")
	testing.expect(t, strings.contains(kit_layout_text(k), "panes v300 0 v571 1 2\n"), "three across's old splits do not read as its tree")
	testing.expect_value(t, grid_layout_upgrade("open Stats\ngrid Side_By_Side 400 500\npane 1 Top Shaded\n"), "open Stats\npanes v400 0 1\npane 1 Top Shaded\n")
	// What is no tree is passed over: a pane twice, no main view, a share out of range.
	for bad in ([]string{"panes v500 1 1", "panes v500 1 2", "panes v0 0 1", "panes h500 0", "panes v500 0 1 2"}) {
		kit_layout_put(k, bad)
		testing.expectf(t, grid_panes(&k.grid) == 1, "%s was read", bad)
	}

	// Inspect is the four panes: curvature, normals and a front silhouette.
	kit_layout_put(k, built_in_layout(.Inspect))
	testing.expect_value(t, grid_shape_name(&k.grid), "Four")
	testing.expect_value(t, k.grid.views[0].pass, Second_Pass.Curvature)
	testing.expect_value(t, k.grid.views[2], Second_View{camera = .Front, pass = .Silhouette})
	testing.expect(t, kit_layout_text(k) == built_in_layout(.Inspect), "Inspect does not read back to itself")
}

@(test)
the_main_pane_moves_the_pointer_and_the_safe_zone :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.kit.scale = 2
	app.kit.ctx.input.window = {800, 450}
	app.nav.edge_orbit, app.nav.edge_size = true, 20
	// Filling the window, the safe zone is the window's less its bands.
	app.kit.grid.main = {0, 0, 800, 450}
	lo, hi := edge_inner(app)
	testing.expect_value(t, lo, [2]f32{20, TOP_BAR_H + 20} * 2)
	testing.expect_value(t, hi, [2]f32{780, 430} * 2)
	// A main pane right of a column: points are the pane's, and so is its safe zone.
	app.kit.grid.main = {300, 0, 250, 450}
	app.ui.viewport_origin = {600, 0}
	testing.expect_value(t, viewport_point(app, {700, 100}), [2]f32{100, 100})
	lo, hi = edge_inner(app)
	testing.expect_value(t, lo, [2]f32{40, (TOP_BAR_H + 20) * 2})
	testing.expect_value(t, hi, [2]f32{460, 860})
	testing.expect(t, in_edge(app, {10, 400}) && !in_edge(app, {100, 400}), "the safe zone is not the pane's")
}

@(test)
a_lower_pane_has_no_top_bar_band :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	app.kit.scale = 1
	app.kit.ctx.input.window = {800, 450}
	app.nav.edge_orbit, app.nav.edge_size = true, 20
	// A view pane worked in at the bottom right starts its safe zone at its own top.
	app.kit.grid.main = {400, 225, 400, 225}
	app.ui.viewport_origin = {400, 225}
	lo, _ := edge_inner(app)
	testing.expect_value(t, lo, [2]f32{20, 20})
}

@(test)
a_layout_keeps_a_heavy_pane_pass :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	grid_reset(&k.grid)
	grid_layout_read(&k.grid, {"grid", "Four"})
	grid_layout_read(&k.grid, {"pane", "1", "Front", "Studio"})
	grid_layout_read(&k.grid, {"pane", "2", "Right", "Occlusion"})
	testing.expect_value(t, k.grid.views[0].pass, Second_Pass.Studio)
	testing.expect_value(t, k.grid.views[1].pass, Second_Pass.Occlusion)
	testing.expect(t, strings.contains(grid_layout_lines(k), "pane 1 Front Studio"), "the layout did not write the Studio pass")
	testing.expect_value(t, second_view_pass(.Occlusion), render.View_Pass.AO)
	testing.expect_value(t, second_view_pass(.Studio), render.View_Pass.Shaded)
}

@(test)
render_preview_splits_the_view_and_toggles_back :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	g := &app.kit.grid
	grid_reset(g)
	testing.expect_value(t, render_preview_pane(&app.kit), 0)
	// From a single view the grid goes side by side and its pane follows the main camera on Render.
	render_preview_toggle(app)
	testing.expect_value(t, grid_shape_name(g), "Side_By_Side")
	testing.expect_value(t, g.views[0].camera, Second_Camera.Follow)
	testing.expect_value(t, g.views[0].pass, Second_Pass.Render)
	// Splitting the view was a layout step.
	testing.expect_value(t, g.undo.back_n, 1)
	testing.expect_value(t, render_preview_pane(&app.kit), 1)
	// Again, the pane goes back to Shaded and the grid stays.
	render_preview_toggle(app)
	testing.expect_value(t, grid_shape_name(g), "Side_By_Side")
	testing.expect_value(t, g.views[0].pass, Second_Pass.Shaded)
	testing.expect_value(t, render_preview_pane(&app.kit), 0)
	// A grid that has panes keeps its preset, and a Render pane anywhere in it is the one found.
	g.tree = grid_preset_tree(.Four)
	g.views[2].pass = .Render
	testing.expect_value(t, render_preview_pane(&app.kit), 3)
	render_preview_toggle(app)
	testing.expect_value(t, grid_shape_name(g), "Four")
	testing.expect_value(t, render_preview_pane(&app.kit), 0)
}

@(test)
work_in_a_pane_lends_the_camera_and_gives_it_back :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	g := &app.kit.grid
	grid_reset(g)
	g.tree = grid_preset_tree(.Four)
	g.views = grid_views_default(.Four)
	main := app.camera
	main.yaw, main.distance = 0.6, 3.5
	app.camera = main
	// Working in the Front pane sees through its camera; the main camera is kept aside.
	grid_work_begin(app, 1)
	testing.expect_value(t, g.work, 1)
	testing.expect(t, app.camera.ortho && app.camera != main, "the main view does not see through the Front pane's camera")
	testing.expect(t, main_camera(app) == main, "the main camera was not kept aside")
	// A stroke that left the camera alone leaves the pane as it was.
	grid_work_end(app)
	testing.expect_value(t, g.work, 0)
	testing.expect_value(t, g.work_ended, 1)
	testing.expect(t, app.camera == main, "the main camera did not come back bit for bit")
	testing.expect_value(t, g.views[0].camera, Second_Camera.Front)
	// A turn while working leaves the Front pane Free at the view it was turned to.
	grid_work_begin(app, 1)
	app.camera.yaw += 0.3
	turned := app.camera
	grid_work_end(app)
	testing.expect_value(t, g.views[0].camera, Second_Camera.Free)
	testing.expect(t, g.views[0].orbit == turned, "the pane did not keep its turn")
	testing.expect(t, app.camera == main, "the main camera moved")
	// A linked pane's turn is the main camera's; a mirrored one's is the main camera's mirrored.
	g.views[1].camera = .Follow
	grid_work_begin(app, 2)
	app.camera.pitch += 0.2
	linked := app.camera
	grid_work_end(app)
	testing.expect(t, app.camera == linked, "a linked pane's turn did not move the main camera")
	g.views[2].camera = .Mirror
	before := app.camera
	grid_work_begin(app, 3)
	app.camera.yaw += 0.1
	grid_work_end(app)
	testing.expect(t, abs(app.camera.yaw - (before.yaw - 0.1)) < 1e-5, "a mirrored pane's turn did not turn the main camera the other way")
}

@(test)
linked_panes_share_the_main_cameras_colour :: proc(t: ^testing.T) {
	th := ui.THEME_LENS
	linked := Second_View{camera = .Follow}
	mirrored := Second_View{camera = .Mirror}
	front := Second_View{camera = .Front}
	c, ring := second_color(th, &linked, 2)
	testing.expect(t, c == th.camera[0] && !ring, "a linked pane's dot is not the main camera's")
	c, ring = second_color(th, &mirrored, 3)
	testing.expect(t, c == th.camera[0] && ring, "a mirrored pane's dot is not the main camera's ring")
	c, ring = second_color(th, &front, 2)
	testing.expect(t, c == th.camera[2] && !ring, "an independent pane's dot is not its own")

	// The link button links an independent pane, and lets a linked one go to Free where it looked.
	app := new(App)
	defer free(app)
	app.camera = {target = {0.2, 0, 0}, distance = 3, yaw = 0.5, pitch = 0.3, fov_y = 0.7, near = 0.01, far = 100}
	second_link_toggle(app, &front)
	testing.expect_value(t, front.camera, Second_Camera.Follow)
	second_link_toggle(app, &mirrored)
	testing.expect_value(t, mirrored.camera, Second_Camera.Free)
	testing.expect_value(t, second_orbit(app, &mirrored).yaw, -app.camera.yaw)
	testing.expect_value(t, second_orbit(app, &mirrored).target.x, -app.camera.target.x)
}

@(test)
a_mirrored_pane_reads_back :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k := new(Kit_State)
	defer free(k)
	bars_reset(k)
	panels_default(k)
	grid_reset(&k.grid)
	kit_layout_put(k, "grid Side_By_Side 500 500\npane 1 Mirror Normals\n")
	testing.expect_value(t, k.grid.views[0], Second_View{camera = .Mirror, pass = .Normals})
	testing.expect(t, strings.contains(kit_layout_text(k), "pane 1 Mirror Normals\n"), "a mirrored pane is not written")
}
