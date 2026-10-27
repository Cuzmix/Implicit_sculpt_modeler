package main

import "core:hash"
import "core:math"
import "core:slice"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"

// The floor grid (the right bar's Floor grid, a long press for its settings): grid lines on
// up to three planes square to the world's axes, round what the scene shows. The floor
// lies under the scene and the two walls behind it as the camera sees it, so the grid never
// stands between the eye and the model; the lines fade out a little way round the scene.

// What the Floor grid settings choose: whether it shows; per axis, whether the plane across
// it does (Y is the floor, Z the back wall, X the side wall); whether the axes' own lines
// show in their colours; and the side of a cell, fitted to the scene's size or `cell`.
Floor_Settings :: struct {
	on:     bool,
	planes: [3]bool,
	axes:   bool,
	fit:    bool,
	cell:   f32,
}

FLOOR_DEFAULT :: Floor_Settings{planes = {false, true, false}, axes = true, fit = true, cell = 0.25}

// The range of a cell's side the slider offers, in scene units.
FLOOR_CELL_MIN :: 0.01
FLOOR_CELL_MAX :: 100

// How far the lines reach round the scene, in the scene box's diagonals from its middle,
// and how big the scene is taken to be when it shows nothing.
FLOOR_REACH :: 2.5
FLOOR_EMPTY_SIZE :: 2

// The scene's box the grid stands round, kept from frame to frame and taken again only
// when the work, an object's place or what shows changes (Floor_State.key), and never
// mid-stroke or mid-drag, so the floor holds still while the model is worked on.
Floor_State :: struct {
	bounds: geom.Aabb,
	key:    u64,
}

// The grid the viewport draws this frame: off unless it is on and some plane shows.
floor_grid_frame :: proc(app: ^App) -> render.Floor_Grid {
	f := app.floor
	if !f.on || f.planes == {} do return {}
	busy := app.stroke.active || app.move.drag.handle != .None || app.ui.transform_drag.active
	if key := floor_scene_key(app); key != app.floor_state.key && !busy {
		app.floor_state = {floor_scene_bounds(app), key}
	}
	return floor_grid_place(app.floor_state.bounds, camera.orbit_eye(app.camera), f)
}

// Where the planes of `f` go round a scene in `bounds` (empty: a small one at the origin)
// seen from `eye`: the floor at its bottom, the walls on its far sides.
floor_grid_place :: proc(bounds: geom.Aabb, eye: Vec3, f: Floor_Settings) -> (g: render.Floor_Grid) {
	b := bounds
	if b.lo.x > b.hi.x do b = {-FLOOR_EMPTY_SIZE / 2, FLOOR_EMPTY_SIZE / 2}
	mid := (b.lo + b.hi) / 2
	size := b.hi - b.lo
	diagonal := max(math.sqrt(size.x * size.x + size.y * size.y + size.z * size.z), 1e-3)
	for axis in 0 ..< 3 {
		g.shown[axis] = b32(f.planes[axis])
		// The floor is always the bottom; a wall is on whichever side faces away from the eye.
		g.at[axis] = b.lo[axis] if axis == 1 || eye[axis] > mid[axis] else b.hi[axis]
	}
	g.center = mid
	g.cell = floor_cell_fit(diagonal) if f.fit else clamp(f.cell, FLOOR_CELL_MIN, FLOOR_CELL_MAX)
	g.radius = diagonal * FLOOR_REACH
	g.axes = b32(f.axes)
	return
}

// A cell's side for a scene `diagonal` across: a round 1, 2 or 5 times a power of ten
// near an eighth of it, so a scene spans about eight cells whatever its size.
floor_cell_fit :: proc(diagonal: f32) -> f32 {
	want := max(diagonal / 8, 1e-4)
	ten := math.pow(10, math.floor(math.log10(want)))
	best := ten
	for step in ([3]f32{2, 5, 10}) do if abs(math.log10(ten * step / want)) < abs(math.log10(best / want)) do best = ten * step
	return best
}

// A hash of what moves the scene's box: the work (the history's serial), and each object's
// id, place, shown level and whether it shows.
@(private = "file")
floor_scene_key :: proc(app: ^App) -> u64 {
	Keyed :: struct {
		id:        int,
		transform: Transform,
		level:     int,
		shown:     b32,
	}
	h := hash.fnv64a(slice.bytes_from_ptr(&app.history.serial, size_of(app.history.serial)))
	for obj in app.scene.objects {
		k := Keyed{obj.id, obj.transform, obj.levels.current, b32(object_shown(app, obj))}
		h = hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k)), h)
	}
	return max(h, 1)
}

// The world box round every shown object's shown surface: a mesh object's current level
// (never an HD window, which is part of it), a voxel object's clay.
@(private = "file")
floor_scene_bounds :: proc(app: ^App) -> geom.Aabb {
	world := geom.AABB_EMPTY
	for obj in app.scene.objects {
		if !object_shown(app, obj) do continue
		chunks := obj.voxel.clay.surface.chunks[:] if obj.voxel != nil else sculpt.levels_current(&obj.levels).sculptor.chunks
		model := transform_matrix(obj.transform)
		for c in chunks {
			b := c.bounds
			if b.lo.x > b.hi.x do continue
			for corner in 0 ..< 8 {
				p := Vec3{b.hi.x if corner & 1 != 0 else b.lo.x, b.hi.y if corner & 2 != 0 else b.lo.y, b.hi.z if corner & 4 != 0 else b.lo.z}
				q := model * [4]f32{p.x, p.y, p.z, 1}
				geom.aabb_grow(&world, q.xyz)
			}
		}
	}
	return world
}
