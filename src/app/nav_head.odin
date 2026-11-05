package main

import "core:math"
import "core:math/linalg"

import "../camera"
import "../geom"
import "../render"
import "../ui"

// The view gizmo's Model style (view_gizmo.odin): a small head, or the person's own model,
// that turns with the camera, so the view's turn reads at a glance (the face is the front,
// +Z). Tapping a side of it looks at the scene from that side (View_Axis). The renderer
// draws it into a texture of its own (render.Nav_Head), which the kit shows as
// KIT_NAV_HEAD_IMAGE, redrawn only when the view turns.

// Its size in points: no wider than the view bar under it and the gap beside that, so
// the palette tray, which opens left of the view bar, never covers it.
NAV_HEAD_W :: 56
NAV_HEAD_H :: 64

// The clay the head is shaded in, linear like every Draw_Item colour.
NAV_HEAD_COLOR :: [4]f32{0.36, 0.36, 0.37, 1}

// The axes' colours in the small triad by the head: X red, Y green, Z blue, as every
// 3D app has them.
NAV_AXIS_COLORS := [3]ui.Color{{226, 72, 72, 255}, {98, 196, 86, 255}, {76, 128, 236, 255}}

// A head made from a sphere: a skull longer front to back than across, a jaw narrowing
// to the chin, a nose, brow, eye sockets, cheekbones, a mouth, ears and the start of
// the neck, so that each of the six sides looks different from the others. Facing +Z with +Y up, about a unit across.
nav_head_mesh :: proc(allocator := context.allocator) -> geom.Mesh {
	m := geom.icosphere(4, 1, allocator)
	// Gaussian bumps at `c` on the sphere, `r` across along each axis; a plateau is one
	// with a flatter top and a quicker edge, for the ears, which a bump makes pointed.
	bump :: proc(p, c, r: geom.Vec3) -> f32 {
		d := (p - c) / r
		return math.exp(-linalg.dot(d, d))
	}
	plateau :: proc(p, c, r: geom.Vec3) -> f32 {
		d := (p - c) / r
		dd := linalg.dot(d, d)
		return math.exp(-dd * dd)
	}
	for &q in m.positions {
		p := q
		jaw := math.smoothstep(f32(0.05), -0.9, p.y) // 0 over the cheeks, 1 at the chin
		q.x *= 0.8 * (1 - 0.2 * jaw)
		q.z *= 0.9 * (1 - 0.1 * jaw)
		q.y *= 1.06
		side: f32 = 1 if p.x >= 0 else -1
		q.z += 0.22 * bump(p, {0, -0.12, 1}, {0.08, 0.2, 0.4})                    // nose
		q.z += 0.07 * bump(p, {0, 0.1, 1}, {0.06, 0.16, 0.4})                     // its bridge
		q.z += 0.06 * bump(p, {0, 0.27, 0.96}, {0.4, 0.07, 0.4})                  // brow
		q -= 0.1 * p * bump(p, {side * 0.3, 0.12, 0.95}, {0.12, 0.08, 0.4})       // eye socket
		q.z -= 0.03 * bump(p, {0, -0.46, 0.9}, {0.18, 0.025, 0.4})                // mouth
		q += 0.04 * p * bump(p, {side * 0.55, -0.1, 0.8}, {0.18, 0.15, 0.3})      // cheekbone
		q += 0.06 * p * bump(p, {0, -0.82, 0.55}, {0.22, 0.16, 0.3})              // chin
		q += 0.06 * p * bump(p, {0, 0.2, -1}, {0.6, 0.5, 0.4})                    // back of the skull
		q.x += side * 0.1 * plateau(p, {side, 0, -0.1}, {0.3, 0.28, 0.17})        // ear
		q.y -= 0.16 * bump(p, {0, -1, -0.2}, {0.4, 0.4, 0.4})                     // the neck's start
	}
	geom.mesh_recompute_normals(&m)
	return m
}

// The side of the head under `at`, which runs -1 to 1 across the head's picture left to
// right and bottom to top (render.NAV_HEAD_HALF_HEIGHT units each way up and down, times
// `aspect`, its width over its height, across), seen turned as `rotation` (the camera's
// right, up and back in world space, as its columns): the axis view looking from that
// side. False off the head.
nav_head_side :: proc(rotation: matrix[3, 3]f32, at: [2]f32, aspect: f32) -> (side: camera.Axis_View, ok: bool) {
	// In view units: the head is about a unit sphere.
	v := [2]f32{at.x * aspect, at.y} * render.NAV_HEAD_HALF_HEIGHT
	r := linalg.length(v)
	if r > 1.15 do return
	// On the sphere toward the eye; just past its rim, on the rim.
	n := geom.Vec3{v.x, v.y, math.sqrt(max(1 - r * r, 0))}
	n = linalg.normalize(n)
	world := rotation * n
	axis := 0
	for i in 1 ..< 3 do if abs(world[i]) > abs(world[axis]) do axis = i
	plus := world[axis] > 0
	switch axis {
	case 0: side = .Right if plus else .Left
	case 1: side = .Top if plus else .Bottom
	case:   side = .Front if plus else .Back
	}
	return side, true
}

// The head's state between frames: its size as drawn, for the renderer, and a press on
// it, which becomes a turn once it moves past the slop and is a tap otherwise.
Nav_State :: struct {
	size:   [2]u32, // physical pixels; zero while it is not laid out
	placed: bool, // laid out this frame
	from:   [2]f32, // where the press went down, in points
	last:   [2]f32, // where the pointer was the frame before, in points
	turned: bool, // the press became a drag that turns the view
	taps:   int, // views snapped to with a tap, for the exit stats
}

// Draws the Model style's model for this frame on `cmd`, once the kit has laid it out,
// uploading the head or the person's own model when it is not the one on the GPU; the
// interface shows what it drew (KIT_NAV_HEAD_IMAGE).
nav_head_frame :: proc(app: ^App, cmd: render.Cmd) {
	app.nav_shown = 0
	nh := &app.nav_head
	size := app.kit.nav.size
	if !app.kit.nav.placed || size.x == 0 || size.y == 0 || nh.failed do return
	// 0 is the head; the own model's serial names each one taken.
	want := 0
	if app.nav.gizmo_model == .Own && len(app.view_model.indices) > 0 do want = app.view_model_serial + 1
	if nh.mesh.positions != 0 && app.view_model_on != want do render.nav_head_destroy(&app.renderer, nh)
	if nh.mesh.positions == 0 {
		if want == 0 {
			m := nav_head_mesh()
			defer geom.mesh_destroy(&m)
			if !render.nav_head_init(&app.renderer, nh, m) do return
		} else if !render.nav_head_init(&app.renderer, nh, app.view_model) {
			return
		}
		app.view_model_on = want
	}
	app.nav_shown = render.nav_head_draw(&app.renderer, nh, cmd, size, camera.orbit_rotation(app.camera), NAV_HEAD_COLOR)
}
