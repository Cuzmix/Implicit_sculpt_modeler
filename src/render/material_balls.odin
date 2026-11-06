package render

import "core:log"
import "core:time"

import "../geom"
import "../gpu"

// The Material card's balls: a unit sphere drawn through the viewport's own shading (the
// layered variants for a material with layers, glass in the blended pass) under the scene's
// lights and environment, into one atlas of BALL_CELLS x BALL_CELLS cells the interface
// shows a cell at a time. Each ball is drawn into a scratch target cleared to transparent,
// then copied into its cell, as object pictures are (thumbs.odin); outside the ball the
// cell stays transparent, and a see-through ball's colour comes premultiplied by its
// coverage, as blending over a transparent target leaves it.
Material_Balls :: struct {
	atlas:   gpu.Texture,
	scratch: Viewport_Target,
	sphere:  Mesh_Buffers,
	failed:  bool, // the device refused a texture or buffer; no ball is drawn
	// What a ball of the last batch cost to record on the CPU, in milliseconds, and how
	// many balls were drawn in all.
	ms:      f64,
	drawn:   int,
}

// Each cell is BALL_PX pixels square, BALL_CELLS to a side: 160 pixels covers a 56 point
// ball on a screen of up to about three pixels a point.
BALL_PX :: 160
BALL_CELLS :: 8
BALL_SLOTS :: BALL_CELLS * BALL_CELLS

// The sphere's subdivision: 2562 vertices, round at 160 pixels.
BALL_SUBDIV :: 4

// What one ball shows: its cell and the per-draw material a Draw_Item carries.
Ball_Request :: struct {
	slot:     int,
	color:    [4]f32,
	material: [4]f32, // the classic shading's ambient, specular, power and wrap
	surface:  [2]f32, // metallic, roughness (0: the classic shading)
	layers:   geom.Material_Layers,
	matcap:   gpu.Texture, // 0 for none
}

material_balls_destroy :: proc(r: ^Renderer, b: ^Material_Balls) {
	if !r.has_device do return
	if b.atlas != 0 do gpu.release_texture(b.atlas)
	viewport_target_destroy(r, &b.scratch)
	mesh_buffers_destroy(r, &b.sphere)
	b^ = {}
}

// The atlas, made, cleared to transparent and given its sphere on first use; nil when the
// device refuses any of it.
material_balls_atlas :: proc(r: ^Renderer, b: ^Material_Balls, cmd: gpu.Cmd) -> gpu.Texture {
	if b.failed do return 0
	if b.atlas != 0 do return b.atlas
	SIZE :: BALL_PX * BALL_CELLS
	b.atlas = gpu.create_texture({
		type = .D2, format = VIEWPORT_COLOR_FORMAT, usage = {.Color_Target, .Sampled},
		width = SIZE, height = SIZE, layer_count_or_depth = 1, num_levels = 1,
	})
	sphere := geom.icosphere(BALL_SUBDIV)
	defer geom.mesh_destroy(&sphere)
	made: bool
	b.sphere, made = mesh_buffers_create(r, sphere)
	if b.atlas == 0 || !made || !viewport_target_resize(r, &b.scratch, BALL_PX, BALL_PX, transient_depth = true) {
		log.errorf("material ball textures: %s", gpu.last_error())
		b.failed = true
		return 0
	}
	color := gpu.Color_Target{texture = b.atlas, load_op = .Clear, store_op = .Store}
	pass := gpu.begin_render_pass(cmd, &color, 1, nil)
	gpu.end_render_pass(pass)
	return b.atlas
}

// Draws each request's ball into its cell, seen through `view` and `proj`, under `lights`
// with `look` (exposure, cavity, ridge) and `style`; the caller asks for a few a frame,
// while the view is still. Returns how many were drawn (0 without an atlas).
material_balls_draw :: proc(r: ^Renderer, b: ^Material_Balls, cmd: gpu.Cmd, requests: []Ball_Request, view, proj: Mat4, lights: Lights, look, style: [4]f32) -> (drawn: int) {
	if len(requests) == 0 do return 0
	debug_group(cmd, "Material balls", .Pictures)
	start := time.tick_now()
	defer if drawn > 0 do b.ms = time.duration_milliseconds(time.tick_since(start)) / f64(drawn)
	if material_balls_atlas(r, b, cmd) == 0 do return 0
	for q in requests {
		if q.slot < 0 || q.slot >= BALL_SLOTS do continue
		item := Draw_Item {
			mesh     = &b.sphere,
			model    = 1,
			color    = q.color,
			material = q.material,
			surface  = q.surface,
			layers   = q.layers,
			matcap   = q.matcap,
			lights   = lights,
			look     = {look.x, look.y, look.z, 0},
			style    = style,
			damage   = geom.AABB_EMPTY,
		}
		pass := begin_mesh_pass(r, cmd, &r.single, b.scratch.color, b.scratch.depth, load = false, keep_depth = false, background = {0, 0, 0, 0})
		draw_items(r, cmd, pass, &r.single, view, proj, {item}, nil, nil)
		draw_items(r, cmd, pass, &r.single, view, proj, {item}, nil, nil, see = true)
		gpu.end_render_pass(pass)
		copy_pass := gpu.begin_copy_pass(cmd)
		x, y := u32(q.slot % BALL_CELLS) * BALL_PX, u32(q.slot / BALL_CELLS) * BALL_PX
		gpu.copy_texture_to_texture(copy_pass, {texture = b.scratch.color}, {texture = b.atlas, x = x, y = y}, BALL_PX, BALL_PX, 1, cycle = false)
		gpu.end_copy_pass(copy_pass)
		drawn += 1
	}
	b.drawn += drawn
	return
}

// Where cell `slot` lies in the atlas, as texture coordinates from 0 to 1.
ball_uv :: proc(slot: int) -> (lo, hi: [2]f32) {
	step := 1 / f32(BALL_CELLS)
	lo = {f32(slot % BALL_CELLS) * step, f32(slot / BALL_CELLS) * step}
	return lo, lo + step
}
