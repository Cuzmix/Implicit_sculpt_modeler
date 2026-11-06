package main

import "core:fmt"
import "core:log"
import "core:path/filepath"
import "core:strings"

import "../camera"
import "../render"

// Render image: Full render of the main view at a size of its own, not the viewport's,
// into an offscreen target, gathering its samples over the frames that follow as render
// mode does, then written as a PNG. With `transparent` the background, floor and the
// environment's picture are left out, so the image's alpha is what the scene covers;
// with `catcher`, the floor grid's level plane is traced as a shadow catcher, showing only
// the shadows the scene casts on it (render.Shadow_Catcher), which over a transparent
// background are the image's alpha there; with `passes`, its albedo, normal and depth (the render's own guides) and the
// viewport's curvature and silhouette passes at the same size are written beside it,
// NAME_albedo.png and so on. The scripts start it (render_image); the interface may
// call render_image_start.
Render_Image :: struct {
	on:          bool,
	path:        string, // owned
	width:       u32,
	height:      u32,
	samples:     int,
	transparent: bool,
	passes:      bool,
	catcher:     bool, // the floor's plane shows the shadows the scene casts on it, nothing else
	started:     bool, // its first frame ran (the render starts over then)
	// All its samples are in; it is read back and written at the start of the next frame,
	// once the commands that laid the last one out have been submitted.
	ready:       bool,
	target:      render.Viewport_Target,
	path_render: render.Path_Render,
	// For the exit stats: images written, and the last one's size and samples.
	written:     int,
	failed:      int,
}

// The largest side an image may have: Full render keeps two 16-byte sums a pixel, so
// 4096 x 4096 already holds 512 MB on the device.
RENDER_IMAGE_MAX :: 4096

// Starts rendering an image of `width` x `height` with `samples` samples to `path`; a
// second start before it is written replaces the first. Says why when it cannot.
render_image_start :: proc(app: ^App, width, height, samples: int, path: string, transparent := false, passes := false, catcher := false) -> string {
	if width < 16 || height < 16 || width > RENDER_IMAGE_MAX || height > RENDER_IMAGE_MAX do return fmt.tprintf("an image is 16 to %d pixels a side", RENDER_IMAGE_MAX)
	if samples < 1 || samples > render.RENDER_SAMPLES_MAX do return fmt.tprintf("an image takes 1 to %d samples", render.RENDER_SAMPLES_MAX)
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	if ext != ".png" do return "an image is written as .png"
	ri := &app.render_image
	delete(ri.path)
	ri.path = strings.clone(path)
	ri.width, ri.height, ri.samples = u32(width), u32(height), samples
	ri.transparent, ri.passes, ri.catcher = transparent, passes, catcher
	ri.on, ri.started, ri.ready = true, false, false
	return ""
}

render_image_destroy :: proc(app: ^App) {
	ri := &app.render_image
	render.path_render_destroy(&app.renderer, &ri.path_render)
	render.viewport_target_destroy(&app.renderer, &ri.target)
	delete(ri.path)
	ri^ = {}
}

// Runs this frame's share of the image being rendered, after the viewport's: draws the
// scene at the image's size as the backdrop, adds a band of samples, and once all are in
// writes the image (and its passes) and lets the device's copy go.
render_image_frame :: proc(app: ^App, cmd: render.Cmd, items: []render.Draw_Item) {
	ri := &app.render_image
	if !ri.on do return
	r := &app.renderer
	view := camera.orbit_view(app.camera)
	proj := camera.orbit_proj(app.camera, f32(ri.width) / f32(ri.height))
	if ri.ready {
		shown := render.render_texture(&ri.path_render)
		ok := shown != 0 && render_image_write(app, shown, ri.path)
		if ok && ri.passes do ok = render_image_passes(app, view, proj, items)
		render_image_end(app, ok)
		return
	}
	if !render.viewport_target_resize(r, &ri.target, ri.width, ri.height) {
		log.errorf("render image: the device refused a %d x %d target", ri.width, ri.height)
		render_image_end(app, false)
		return
	}
	background, floor, environment, planes := r.background, r.floor, r.environment_look.background, r.ref_planes
	// The shadow catcher lies where the floor grid's level plane does, shown or not.
	shadow := render.Shadow_Catcher{on = ri.catcher, axis = 1, at = floor.at.y, strength = 1}
	defer r.background, r.floor, r.environment_look.background, r.ref_planes = background, floor, environment, planes
	r.ref_planes = nil
	if ri.transparent do r.background, r.floor, r.environment_look.background = {}, {}, false
	_ = render.render_viewport(r, cmd, &ri.target, view, proj, items, false)
	samples := ri.samples
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	if !render.render_frame(r, &ri.path_render, cmd, &ri.target, view, proj, items, !ri.started, samples, bounces, viewport_lights(app), app.studio_softness, app.exposure, app.render_denoise, false, render_lens(app), &app.pool, catcher = shadow) {
		log.errorf("render image: the device cannot run Full render")
		render_image_end(app, false)
		return
	}
	ri.started = true
	ri.ready = ri.path_render.samples >= samples
}

// Writes `texture` (the image's size) to `path`, with its alpha when transparent.
@(private = "file")
render_image_write :: proc(app: ^App, texture: render.Texture, path: string) -> bool {
	ri := &app.render_image
	pixels := render.texture_download(&app.renderer, texture, ri.width, ri.height, context.temp_allocator)
	if pixels == nil do return false
	// Over a transparent backdrop the colour comes premultiplied by its coverage; a PNG
	// keeps it straight.
	if ri.transparent {
		for p := 0; p < len(pixels); p += 4 {
			a := pixels[p + 3]
			if a == 0 || a == 255 do continue
			for c in 0 ..< 3 do pixels[p + c] = u8(min(int(pixels[p + c]) * 255 / int(a), 255))
		}
	}
	return image_save(app, path, pixels, int(ri.width), int(ri.height), alpha = ri.transparent)
}

// The passes beside the image: the render's albedo, normal and depth guides, and the
// viewport's curvature and silhouette passes drawn at the image's size (its occlusion
// pass reads the live occlusion, which is worked out for the viewport alone, so it is
// left out).
@(private = "file")
render_image_passes :: proc(app: ^App, view, proj: render.Mat4, items: []render.Draw_Item) -> bool {
	ri := &app.render_image
	stem := strings.trim_suffix(ri.path, filepath.ext(ri.path))
	r := &app.renderer
	guides := render.render_guides(r, &ri.path_render, ri.width, ri.height, context.temp_allocator)
	ok := true
	for g in guides {
		ok &&= image_save(app, fmt.tprintf("%s_%s.png", stem, g.name), g.pixels, int(ri.width), int(ri.height))
	}
	passes := [?]struct {
		pass: render.View_Pass,
		name: string,
	}{{.Curvature, "curvature"}, {.Silhouette, "silhouette"}}
	marked := make([]render.Draw_Item, len(items), context.temp_allocator)
	for p in passes {
		copy(marked, items)
		for &m in marked do m.pass = {f32(p.pass), 0, 0, 0}
		// Drawn on a command buffer of its own, submitted before it is read back.
		cmd := render.cmd_begin(r)
		if cmd == nil do return false
		_ = render.render_viewport(r, cmd, &ri.target, view, proj, marked, false)
		if !render.cmd_submit(cmd) do return false
		pixels := render.viewport_download(r, &ri.target, context.temp_allocator)
		ok &&= pixels != nil && image_save(app, fmt.tprintf("%s_%s.png", stem, p.name), pixels, int(ri.width), int(ri.height))
	}
	return ok
}

@(private = "file")
render_image_end :: proc(app: ^App, ok: bool) {
	ri := &app.render_image
	if ok {
		ri.written += 1
		file_note(app, false, "Rendered %s: %d x %d, %d samples%s", filepath.base(ri.path), ri.width, ri.height, ri.samples, ", with its passes" if ri.passes else "")
	} else {
		ri.failed += 1
		file_note(app, true, "Could not render %s", filepath.base(ri.path))
	}
	render.path_render_destroy(&app.renderer, &ri.path_render)
	render.viewport_target_destroy(&app.renderer, &ri.target)
	ri.on = false
}
