package main

import "core:strings"
import "core:testing"

import "../ui"

@(test)
grid_cells_tile_the_room :: proc(t: ^testing.T) {
	room := ui.Rect{100, 0, 1000, 600}
	g: View_Grid
	for preset in Grid_Preset {
		cells := grid_cells(preset, grid_split(&g, preset), room)
		n := grid_count(preset)
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
	big := grid_cells(.One_Plus_Two, grid_split(&g, .One_Plus_Two), room)
	testing.expect(t, big[0].w * big[0].h > 2 * big[1].w * big[1].h, "One plus two's main pane is not the big one")
	thirds := grid_cells(.Three_Across, grid_split(&g, .Three_Across), room)
	testing.expect(t, abs(thirds[0].w - thirds[1].w) <= GRID_GAP && abs(thirds[1].w - thirds[2].w) <= GRID_GAP, "three across is not in thirds")
}

@(test)
grid_splits_stay_clear_of_the_edges :: proc(t: ^testing.T) {
	g: View_Grid
	g.split[.Side_By_Side] = {0.01, 0.99}
	testing.expect_value(t, grid_split(&g, .Side_By_Side), [2]f32{GRID_SPLIT_MIN, 1 - GRID_SPLIT_MIN})
	g.split[.Three_Across] = {0.6, 0.5}
	s := grid_split(&g, .Three_Across)
	testing.expect(t, s.y - s.x >= GRID_THIRDS_MIN - 0.001 && s.y <= 1 - GRID_THIRDS_MIN + 0.001, "three across lets its splits cross")
	// A new preset's view panes are the partners: front beside, then the side, then the top.
	grid_reset(&g)
	testing.expect_value(t, g.views[.Side_By_Side][0].camera, Second_Camera.Front)
	testing.expect_value(t, g.views[.Four][2].camera, Second_Camera.Top)
	testing.expect_value(t, g.views[.Four][1].pass, Second_Pass.Shaded)
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
	grid_set(k, .One_Plus_Two)
	k.grid.split[.One_Plus_Two] = {0.6543, 0.3}
	k.grid.views[.One_Plus_Two][1] = {camera = .Top, pass = .Curvature}
	text := kit_layout_text(k)
	testing.expect(t, strings.contains(text, "grid One_Plus_Two 654 300\npane 1 Front Shaded\npane 2 Top Curvature\n"), "the grid lines are not written")
	kit_layout_put(k, single)
	testing.expect_value(t, k.grid.preset, Grid_Preset.Single)
	kit_layout_put(k, text)
	testing.expect_value(t, k.grid.preset, Grid_Preset.One_Plus_Two)
	testing.expect_value(t, k.grid.views[.One_Plus_Two][1].pass, Second_Pass.Curvature)
	testing.expect(t, kit_layout_text(k) == text, "the grid does not read back to itself")

	// A script's or a hand's lower case names it too; a grid line alone gives the partners.
	kit_layout_put(k, "grid four\n")
	testing.expect_value(t, k.grid.preset, Grid_Preset.Four)
	testing.expect_value(t, k.grid.views[.Four][2].camera, Second_Camera.Top)

	// Inspect is the four panes: curvature, normals and a front silhouette.
	kit_layout_put(k, built_in_layout(.Inspect))
	testing.expect_value(t, k.grid.preset, Grid_Preset.Four)
	testing.expect_value(t, k.grid.views[.Four][0].pass, Second_Pass.Curvature)
	testing.expect_value(t, k.grid.views[.Four][2], Second_View{camera = .Front, pass = .Silhouette})
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
work_in_a_pane_lends_the_camera_and_gives_it_back :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	g := &app.kit.grid
	grid_reset(g)
	g.preset = .Four
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
	testing.expect_value(t, g.views[.Four][0].camera, Second_Camera.Front)
	// A turn while working leaves the Front pane Free at the view it was turned to.
	grid_work_begin(app, 1)
	app.camera.yaw += 0.3
	turned := app.camera
	grid_work_end(app)
	testing.expect_value(t, g.views[.Four][0].camera, Second_Camera.Free)
	testing.expect(t, g.views[.Four][0].orbit == turned, "the pane did not keep its turn")
	testing.expect(t, app.camera == main, "the main camera moved")
	// A linked pane's turn is the main camera's; a mirrored one's is the main camera's mirrored.
	g.views[.Four][1].camera = .Follow
	grid_work_begin(app, 2)
	app.camera.pitch += 0.2
	linked := app.camera
	grid_work_end(app)
	testing.expect(t, app.camera == linked, "a linked pane's turn did not move the main camera")
	g.views[.Four][2].camera = .Mirror
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
	testing.expect_value(t, k.grid.views[.Side_By_Side][0], Second_View{camera = .Mirror, pass = .Normals})
	testing.expect(t, strings.contains(kit_layout_text(k), "pane 1 Mirror Normals\n"), "a mirrored pane is not written")
}
