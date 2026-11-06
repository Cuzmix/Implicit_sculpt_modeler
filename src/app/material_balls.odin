package main

import "../camera"
import "../render"

// The Material card's balls (render/material_balls.odin), for the card to ask for: a
// ball a material, drawn into the atlas the kit shows as KIT_MATERIAL_BALLS_IMAGE, a cell
// at a time (render.ball_uv). The card says which materials want drawing each frame;
// material_balls_frame draws at most MATERIAL_BALLS_A_FRAME of them, and only while the
// view is still and no stroke is under way, so nothing shows in sculpting's frame time.

// The image id the kit shows the balls' atlas by, after the last other one.
KIT_MATERIAL_BALLS_IMAGE :: KIT_BRUSH_ICONS_IMAGE + 1

// The most balls drawn in one frame: each is one small draw of a 2562-vertex sphere.
MATERIAL_BALLS_A_FRAME :: 4

// What ball `slot` of the atlas shows for material `m`: its colour, classic shading,
// metal and roughness, layers and MatCap, as the viewport draws an object of it.
material_ball_request :: proc(app: ^App, slot: int, m: Material) -> render.Ball_Request {
	return {
		slot     = slot,
		color    = m.selected,
		material = m.shading,
		surface  = {m.metallic, m.roughness},
		layers   = material_layers_drawn(m),
		matcap   = material_matcap(app, m),
	}
}

// The balls' camera: straight on, in parallel projection, the unit sphere filling its
// cell with a small margin, so every ball reads the same size.
material_ball_camera :: proc() -> (view, proj: render.Mat4) {
	view = camera.look_at({0, 0, 3}, {0, 0, 0}, {0, 1, 0})
	proj = camera.orthographic(1.04, 1, 0.5, 5.5)
	return
}

// Draws the first MATERIAL_BALLS_A_FRAME of `requests` on `cmd` under the viewport's lights,
// environment and look, unless a stroke is under way or the view moves; returns how many
// it drew, which the caller marks drawn.
material_balls_frame :: proc(app: ^App, cmd: render.Cmd, requests: []render.Ball_Request) -> int {
	if len(requests) == 0 || app.stroke.active || !view_settled(app) do return 0
	view, proj := material_ball_camera()
	batch := requests[:min(len(requests), MATERIAL_BALLS_A_FRAME)]
	return render.material_balls_draw(&app.renderer, &app.material_balls, cmd, batch, view, proj, viewport_lights(app), viewport_look(app), viewport_style(app))
}

// --dump-balls: every preset material's ball, a few a frame from the first, so a run
// shows what the card's balls look like without the card.
material_balls_dump_frame :: proc(app: ^App, cmd: render.Cmd) {
	if app.opts_dump_balls == "" || app.dump_balls_next >= len(MATERIALS) do return
	requests := make([dynamic]render.Ball_Request, context.temp_allocator)
	for k in app.dump_balls_next ..< min(len(MATERIALS), render.BALL_SLOTS) do append(&requests, material_ball_request(app, k, MATERIALS[k]))
	app.dump_balls_next += material_balls_frame(app, cmd, requests[:])
}

// Writes the atlas as an image with its transparency (--dump-balls).
material_balls_save :: proc(app: ^App, path: string) -> bool {
	b := &app.material_balls
	if b.atlas == 0 do return false
	size := u32(render.BALL_PX * render.BALL_CELLS)
	pixels := render.texture_download(&app.renderer, b.atlas, size, size, context.temp_allocator)
	if pixels == nil do return false
	return image_save(app, path, pixels, int(size), int(size), alpha = true)
}
