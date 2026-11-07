package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:path/filepath"
import "core:strings"

import "../camera"
import "../render"

// Render image: the main view rendered at a size of its own, not the viewport's, in Full
// render or Fast (the studio render), up to RENDER_IMAGE_MAX a side, then written as a PNG.
// It is drawn a tile at a time, each at most RENDER_TILE_MAX a side, through the view's
// projection narrowed to the tile, into an offscreen target, its samples gathered over the
// frames that follow; each finished tile is copied into the picture on the CPU, so the
// device holds one tile's sums however large the picture.
//
// With `transparent` the background, floor and the environment's picture are left out, so
// the alpha is what the scene covers; with `catcher` (Full) the floor grid's level plane
// shows only the shadows the scene casts on it (render.Shadow_Catcher); with `passes` the
// view's own passes at the same size are written beside it, NAME_albedo.png and so on:
// albedo, normal, depth, ambient occlusion, curvature, silhouette and the object and
// polygroup IDs. The scripts start it (render_image); the interface may call
// render_image_start.
Render_Image :: struct {
	on:          bool,
	path:        string, // owned
	width:       u32,
	height:      u32,
	samples:     int,
	fast:        bool, // the studio render's Fast quality instead of Full
	transparent: bool,
	passes:      bool,
	catcher:     bool,
	// The tiles across and down, the one being drawn, and whether its first frame ran
	// (each tile starts the render over) and its samples are all in, when it is read back
	// at the start of the next frame, once the commands that drew it are submitted.
	tiles:       [2]u32,
	tile:        u32,
	started:     bool,
	ready:       bool,
	canvas:      []u8, // the picture so far, RGBA8 rows top to bottom
	target:      render.Viewport_Target,
	path_render: render.Path_Render,
	studio:      render.Studio,
	live_ao:     render.Live_AO,
	// For the exit stats: pictures written and refused.
	written:     int,
	failed:      int,
}

// The largest side a picture may have, and a tile's: Full render keeps two 16-byte sums a
// pixel on the device, 512 MB for a 4096 x 4096 tile; the picture itself, 256 MB at 8192
// x 8192, stays on the CPU.
RENDER_IMAGE_MAX :: 8192
RENDER_TILE_MAX :: 4096

// Starts rendering a picture of `width` x `height` with `samples` samples to `path`; a
// second start before it is written replaces the first. Says why when it cannot.
render_image_start :: proc(app: ^App, width, height, samples: int, path: string, transparent := false, passes := false, catcher := false, fast := false) -> string {
	if width < 16 || height < 16 || width > RENDER_IMAGE_MAX || height > RENDER_IMAGE_MAX do return fmt.tprintf("a picture is 16 to %d pixels a side", RENDER_IMAGE_MAX)
	if samples < 1 || samples > render.RENDER_SAMPLES_MAX do return fmt.tprintf("a picture takes 1 to %d samples", render.RENDER_SAMPLES_MAX)
	if strings.to_lower(filepath.ext(path), context.temp_allocator) != ".png" do return "a picture is written as .png"
	if catcher && fast do return "the shadow catcher is Full render's"
	render_image_drop(app)
	ri := &app.render_image
	ri.path = strings.clone(path)
	ri.width, ri.height, ri.samples = u32(width), u32(height), samples
	ri.fast, ri.transparent, ri.passes, ri.catcher = fast, transparent, passes, catcher
	ri.tiles = {(ri.width + RENDER_TILE_MAX - 1) / RENDER_TILE_MAX, (ri.height + RENDER_TILE_MAX - 1) / RENDER_TILE_MAX}
	ri.tile, ri.started, ri.ready = 0, false, false
	ri.canvas = make([]u8, int(ri.width) * int(ri.height) * 4)
	ri.on = true
	return ""
}

render_image_destroy :: proc(app: ^App) {
	render_image_drop(app)
	app.render_image = {}
}

// Lets the picture under way go, and what the device holds for it.
@(private = "file")
render_image_drop :: proc(app: ^App) {
	ri := &app.render_image
	r := &app.renderer
	render.path_render_destroy(r, &ri.path_render)
	render.studio_destroy(r, &ri.studio)
	render.live_ao_destroy(r, &ri.live_ao)
	render.viewport_target_destroy(r, &ri.target)
	delete(ri.path)
	delete(ri.canvas)
	ri.path, ri.canvas, ri.on = "", nil, false
}

// Tile `t`'s pixel rectangle in the picture.
@(private = "file")
tile_rect :: proc(ri: ^Render_Image, t: u32) -> (x, y, w, h: u32) {
	tx, ty := t % ri.tiles.x, t / ri.tiles.x
	x, y = tx * RENDER_TILE_MAX, ty * RENDER_TILE_MAX
	return x, y, min(RENDER_TILE_MAX, ri.width - x), min(RENDER_TILE_MAX, ri.height - y)
}

// The view's projection for the whole picture narrowed to tile `t`, as History's pictures
// narrow it to a step: the tile fills the target, and the tiles meet edge to edge.
@(private = "file")
tile_proj :: proc(ri: ^Render_Image, t: u32, proj: render.Mat4) -> render.Mat4 {
	x, y, w, h := tile_rect(ri, t)
	size := [2]f32{f32(ri.width), f32(ri.height)}
	center := [2]f32{f32(x) + f32(w) * 0.5, f32(y) + f32(h) * 0.5}
	ndc := [2]f32{2 * center.x / size.x - 1, 1 - 2 * center.y / size.y}
	sx, sy := size.x / f32(w), size.y / f32(h)
	narrow := render.Mat4{
		sx, 0, 0, -sx * ndc.x,
		0, sy, 0, -sy * ndc.y,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
	return narrow * proj
}

// Copies a tile's `w` x `h` pixels into the picture at (x, y).
@(private = "file")
canvas_put :: proc(ri: ^Render_Image, pixels: []u8, x, y, w, h: u32) {
	for row in 0 ..< h {
		from := int(row * w * 4)
		to := (int(y + row) * int(ri.width) + int(x)) * 4
		copy(ri.canvas[to:][:int(w) * 4], pixels[from:][:int(w) * 4])
	}
}

// Runs this frame's share of the picture, after the viewport's: reads back a finished tile,
// or draws the current one at its size as the backdrop and adds a band of samples; once
// every tile is in, writes the picture and its passes and lets everything go.
render_image_frame :: proc(app: ^App, cmd: render.Cmd, items: []render.Draw_Item) {
	ri := &app.render_image
	if !ri.on do return
	r := &app.renderer
	view := camera.orbit_view(app.camera)
	proj := camera.orbit_proj(app.camera, f32(ri.width) / f32(ri.height))
	if ri.ready {
		if !render_image_take_tile(app) {
			render_image_end(app, false)
			return
		}
		ri.tile += 1
		ri.started, ri.ready = false, false
		if ri.tile < ri.tiles.x * ri.tiles.y do return
		ok := image_save(app, ri.path, ri.canvas, int(ri.width), int(ri.height), alpha = ri.transparent)
		if ok && ri.passes do ok = render_image_passes(app, view, proj, items)
		render_image_end(app, ok)
		return
	}
	_, _, w, h := tile_rect(ri, ri.tile)
	if !render.viewport_target_resize(r, &ri.target, w, h) {
		log.errorf("render image: the device refused a %d x %d target", w, h)
		render_image_end(app, false)
		return
	}
	tproj := tile_proj(ri, ri.tile, proj)
	background, floor, environment, planes := r.background, r.floor, r.environment_look.background, r.ref_planes
	defer r.background, r.floor, r.environment_look.background, r.ref_planes = background, floor, environment, planes
	// The shadow catcher lies where the floor grid's level plane does, shown or not.
	shadow := render.Shadow_Catcher{on = ri.catcher, axis = 1, at = floor.at.y, strength = 1}
	r.ref_planes = nil
	if ri.transparent do r.background, r.floor, r.environment_look.background = {}, {}, false
	_ = render.render_viewport(r, cmd, &ri.target, view, tproj, items, false)
	if ri.fast {
		_ = render.studio_frame(r, &ri.studio, cmd, &ri.target, view, tproj, items, !ri.started, ri.samples, app.studio_ao, app.studio_shadow, viewport_lights(app), &app.pool, app.studio_softness)
		if ri.studio.failed {
			log.errorf("render image: the device cannot run the studio render")
			render_image_end(app, false)
			return
		}
		ri.started = true
		ri.ready = ri.studio.samples >= ri.samples
		return
	}
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	if !render.render_frame(r, &ri.path_render, cmd, &ri.target, view, tproj, items, !ri.started, ri.samples, bounces, viewport_lights(app), app.studio_softness, app.exposure, app.render_denoise, false, render_lens(app), &app.pool, catcher = shadow) {
		log.errorf("render image: the device cannot run Full render")
		render_image_end(app, false)
		return
	}
	ri.started = true
	ri.ready = ri.path_render.samples >= ri.samples
}

// Reads the finished tile back into the picture: Full render's image, which is
// premultiplied by its coverage over a transparent backdrop, or the studio's, whose alpha
// is the tile's own transparent drawing's coverage.
@(private = "file")
render_image_take_tile :: proc(app: ^App) -> bool {
	ri := &app.render_image
	r := &app.renderer
	x, y, w, h := tile_rect(ri, ri.tile)
	shown := render.studio_texture(&ri.studio) if ri.fast else render.render_texture(&ri.path_render)
	if shown == 0 do return false
	pixels := render.texture_download(r, shown, w, h, context.temp_allocator)
	if pixels == nil do return false
	if ri.transparent && ri.fast {
		coverage := render.viewport_download(r, &ri.target, context.temp_allocator)
		if coverage == nil do return false
		for p := 0; p < len(pixels); p += 4 do pixels[p + 3] = coverage[p + 3]
	} else if ri.transparent {
		unpremultiply(pixels)
	}
	canvas_put(ri, pixels, x, y, w, h)
	return true
}

// Straight colour from colour premultiplied by alpha, where alpha is partial.
@(private = "file")
unpremultiply :: proc(pixels: []u8) {
	for p := 0; p < len(pixels); p += 4 {
		a := pixels[p + 3]
		if a == 0 || a == 255 do continue
		for c in 0 ..< 3 do pixels[p + c] = u8(min(int(pixels[p + c]) * 255 / int(a), 255))
	}
}

// The view's passes at the picture's size, each drawn tile by tile into the picture (which
// the beauty image no longer needs) and written beside it: the viewport's own passes, flat
// colours an object and a polygroup for the IDs, and ambient occlusion from live occlusion
// of its own at full strength. Each tile is drawn on a command buffer of its own, submitted
// before it is read back.
@(private = "file")
render_image_passes :: proc(app: ^App, view, proj: render.Mat4, items: []render.Draw_Item) -> bool {
	ri := &app.render_image
	r := &app.renderer
	stem := strings.trim_suffix(ri.path, filepath.ext(ri.path))
	Pass :: struct {
		name: string,
		pass: render.View_Pass,
		ids:  int, // 1 colours by object, 2 by polygroup; 0 the pass as it is
		ao:   bool,
	}
	passes := [?]Pass {
		{"albedo", .Unlit, 0, false},
		{"normal", .Normals, 0, false},
		{"depth", .Depth, 0, false},
		{"occlusion", .AO, 0, true},
		{"curvature", .Curvature, 0, false},
		{"silhouette", .Silhouette, 0, false},
		{"object_id", .Unlit, 1, false},
		{"group_id", .Unlit, 2, false},
	}
	marked := make([]render.Draw_Item, len(items), context.temp_allocator)
	background, floor, environment, planes := r.background, r.floor, r.environment_look.background, r.ref_planes
	defer r.background, r.floor, r.environment_look.background, r.ref_planes = background, floor, environment, planes
	r.floor, r.environment_look.background, r.ref_planes = {}, false, nil
	for p in passes {
		copy(marked, items)
		pass_items(marked, view, p.pass)
		r.background = {}
		if ground, has := pass_ground(p.pass); has do r.background = ground
		for &m, k in marked {
			switch p.ids {
			case 1:
				m.color, m.paint, m.groups, m.slots, m.textured = id_color(k + 1), false, false, nil, nil
			case 2:
				m.color, m.paint, m.groups, m.slots, m.textured = {0, 0, 0, 1}, false, true, nil, nil
			}
		}
		for t in 0 ..< ri.tiles.x * ri.tiles.y {
			x, y, w, h := tile_rect(ri, t)
			if !render.viewport_target_resize(r, &ri.target, w, h) do return false
			cmd := render.cmd_begin(r)
			if cmd == nil do return false
			tproj := tile_proj(ri, t, proj)
			drawn := render.render_viewport(r, cmd, &ri.target, view, tproj, marked, false)
			shown: render.Texture
			if p.ao {
				render.live_ao_reset(&ri.live_ao)
				if render.live_ao_frame(r, &ri.live_ao, cmd, &ri.target, view, tproj, marked, drawn, clamp(app.live_ao_reach, LIVE_AO_REACH_MIN, LIVE_AO_REACH_MAX), 1, 1) do shown = render.live_ao_texture(&ri.live_ao)
			}
			if !render.cmd_submit(cmd) do return false
			pixels := render.texture_download(r, shown, w, h, context.temp_allocator) if shown != 0 else render.viewport_download(r, &ri.target, context.temp_allocator)
			if pixels == nil do return false
			canvas_put(ri, pixels, x, y, w, h)
		}
		if !image_save(app, fmt.tprintf("%s_%s.png", stem, p.name), ri.canvas, int(ri.width), int(ri.height)) do return false
	}
	return true
}

// A flat colour for ID `id` its neighbours' differ from: hues a golden angle apart, bright
// and saturated, the same every run.
@(private = "file")
id_color :: proc(id: int) -> [4]f32 {
	hue := math.mod(f32(id) * 0.618034, 1)
	c: [4]f32 = 1
	for k in 0 ..< 3 {
		x := math.abs(math.mod(hue * 6 + f32(4 - 2 * k), 6) - 3) - 1
		c[k] = 0.15 + 0.8 * clamp(x, 0, 1)
	}
	return c
}

@(private = "file")
render_image_end :: proc(app: ^App, ok: bool) {
	ri := &app.render_image
	if ok {
		ri.written += 1
		file_note(app, false, "Rendered %s: %d x %d, %d samples in %s%s", filepath.base(ri.path), ri.width, ri.height, ri.samples, "Fast" if ri.fast else "Full", ", with its passes" if ri.passes else "")
	} else {
		ri.failed += 1
		file_note(app, true, "Could not render %s", filepath.base(ri.path))
	}
	render_image_drop(app)
}

// The picture's size on the Export sheet's Render tab (Render_Image_Settings): the view's
// own pixels or twice them, or a fixed one, its aspect then the view's own crop.
Render_Image_Size :: enum u8 {
	View,
	View_2x,
	HD,     // 1920 x 1080
	UHD,    // 3840 x 2160
	Square, // 2048 x 2048
}

@(rodata)
RENDER_IMAGE_SIZE_NAMES := [Render_Image_Size]string {
	.View    = "View",
	.View_2x = "View ×2",
	.HD      = "1080p",
	.UHD     = "4K",
	.Square  = "Square",
}

// What Render image... renders, chosen on the Export sheet and remembered: its size, Full
// render or Fast, and the passes and shadow catcher; the samples are the Render card's own
// for that quality, and the background goes as Without background says.
Render_Image_Settings :: struct {
	size:    Render_Image_Size,
	fast:    bool,
	passes:  bool,
	catcher: bool,
}

// The picture's width and height for size `size`, from the view's own pixels.
render_image_dims :: proc(app: ^App, size: Render_Image_Size) -> (w, h: int) {
	vw, vh := max(int(app.target.width), 16), max(int(app.target.height), 16)
	switch size {
	case .View:    w, h = vw, vh
	case .View_2x: w, h = 2 * vw, 2 * vh
	case .HD:      w, h = 1920, 1080
	case .UHD:     w, h = 3840, 2160
	case .Square:  w, h = 2048, 2048
	}
	return min(w, RENDER_IMAGE_MAX), min(h, RENDER_IMAGE_MAX)
}

// The samples the picture takes: the Render card's for the quality it renders in.
render_image_samples :: proc(app: ^App, fast: bool) -> int {
	n := app.studio_samples if fast else app.render_samples
	return clamp(int(n), 1, render.RENDER_SAMPLES_MAX)
}

// Starts the picture Render image... asked for, to `path`, as the Export sheet set it.
render_image_from_settings :: proc(app: ^App, path: string) {
	st := app.render_image_settings
	w, h := render_image_dims(app, st.size)
	catcher := st.catcher && !st.fast && app.screenshot_transparent
	if why := render_image_start(app, w, h, render_image_samples(app, st.fast), path, app.screenshot_transparent, st.passes, catcher, st.fast); why != "" {
		file_note(app, true, "Cannot render %s: %s", filepath.base(path), why)
	}
}

// Stops the picture under way, writing nothing.
render_image_stop :: proc(app: ^App) {
	if !app.render_image.on do return
	file_note(app, false, "Stopped rendering %s", filepath.base(app.render_image.path))
	render_image_drop(app)
}

// How far the picture under way has come, 0 to 1, and a line saying so; false when none is.
render_image_progress :: proc(app: ^App) -> (share: f32, line: string, on: bool) {
	ri := &app.render_image
	if !ri.on do return 0, "", false
	tiles := ri.tiles.x * ri.tiles.y
	done := ri.studio.samples if ri.fast else ri.path_render.samples
	if !ri.started do done = 0
	done = min(done, ri.samples)
	share = (f32(ri.tile) + f32(done) / f32(max(ri.samples, 1))) / f32(max(tiles, 1))
	if tiles > 1 do line = fmt.tprintf("Rendering %s: tile %d of %d, %d / %d samples", filepath.base(ri.path), ri.tile + 1, tiles, done, ri.samples)
	else do line = fmt.tprintf("Rendering %s: %d / %d samples", filepath.base(ri.path), done, ri.samples)
	return share, line, true
}
