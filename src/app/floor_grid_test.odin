package main

import "core:testing"

import "../geom"

// The floor goes under the scene's box and each wall on the box's side away from the eye,
// whichever way the eye looks; the cells fit the box's size.
@(test)
floor_grid_sits_under_and_behind_the_scene :: proc(t: ^testing.T) {
	box := geom.Aabb{{-1, -2, -3}, {1, 2, 3}}
	f := FLOOR_DEFAULT
	f.planes = {true, true, true}
	g := floor_grid_place(box, {5, 5, 5}, f)
	testing.expect_value(t, g.at, [3]f32{-1, -2, -3})
	testing.expect_value(t, g.shown, [3]b32{true, true, true})
	// From the other side the walls swap over, and the floor stays under.
	g = floor_grid_place(box, {-5, -5, -5}, f)
	testing.expect_value(t, g.at, [3]f32{1, -2, 3})
	testing.expect_value(t, g.center, [3]f32{0, 0, 0})
	testing.expect(t, bool(g.axes))
	// The box is about 7.5 across: an eighth of that rounds to 1.
	testing.expect_value(t, g.cell, f32(1))
	f.fit, f.cell = false, 0.3
	testing.expect_value(t, floor_grid_place(box, {5, 5, 5}, f).cell, f32(0.3))
}

// An empty scene still gets a grid, round the origin.
@(test)
floor_grid_without_objects :: proc(t: ^testing.T) {
	g := floor_grid_place(geom.AABB_EMPTY, {0, 3, 3}, FLOOR_DEFAULT)
	testing.expect_value(t, g.at[1], f32(-1))
	testing.expect_value(t, g.shown, [3]b32{false, true, false})
	testing.expect(t, g.cell > 0 && g.radius > 0)
}

@(test)
floor_cells_are_round_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, floor_cell_fit(8), f32(1))
	testing.expect_value(t, floor_cell_fit(3.4), f32(0.5))
	testing.expect_value(t, floor_cell_fit(1.4), f32(0.2))
	testing.expect_value(t, floor_cell_fit(800), f32(100))
}
