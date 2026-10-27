package main

import "core:path/filepath"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../render"

// Transparent screenshots (Scene > Background > Screenshots without background): the
// objects alone on a see-through ground, for a picture laid over others, as a renderer's
// transparent film or a sculpting app's export with alpha gives. A screenshot read back
// from the viewport cannot say which pixels are background, so the frame after the
// request draws the viewport a second time into a target of its own, on a clear
// transparent ground without the floor grid or the environment's picture: its alpha is
// how much of each pixel the objects cover, soft at their edges with multisampling.
// Where they cover a pixel wholly the picture takes the viewport's own colour, live
// occlusion, studio render and all; at the edges it takes the second drawing's, whose
// colour is not mixed with the background. The turntable (turntable.odin) reads its
// frames back here too, with or without the background.
Capture :: struct {
	path:        string, // the screenshot waiting to be written; "" for none
	turntable:   bool, // a turntable frame waits instead
	transparent: bool, // without the background, by the second drawing
	target:      render.Viewport_Target,
	drawn:       bool, // this frame's commands draw what it reads back
}

capture_destroy :: proc(app: ^App) {
	render.viewport_target_destroy(&app.renderer, &app.capture.target)
	delete(app.capture.path)
	app.capture = {}
}

// Asks the next frame for a transparent screenshot to `path`; a second request before
// it is written replaces the first.
capture_request :: proc(app: ^App, path: string) {
	// The turntable reads every frame back as it wants it.
	if turntable_recording(app) {
		file_note(app, true, "Cannot save a screenshot while the turntable records")
		return
	}
	delete(app.capture.path)
	app.capture.path = strings.clone(path)
	app.capture.transparent = true
}

// Draws the viewport again on a transparent ground, when a screenshot waits, after the
// frame's own viewport, on the same `cmd` and from the same camera and items.
capture_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, view, proj: render.Mat4, draws: []render.Draw_Item) {
	c := &app.capture
	c.drawn = false
	if c.path == "" && !c.turntable do return
	if !c.transparent {
		c.drawn = true
		return
	}
	r := &app.renderer
	if !render.viewport_target_resize(r, &c.target, app.target.width, app.target.height, app.target.samples) {
		file_note(app, true, "Could not make the transparent screenshot: %s", sdl.GetError())
		delete(c.path)
		c.path = ""
		if c.turntable do turntable_stop(app, "the GPU could not make its frame")
		c.turntable = false
		return
	}
	background, floor, lod_px, environment := r.background, r.floor, r.lod_px, r.environment_look.background
	defer r.background, r.floor, r.lod_px, r.environment_look.background = background, floor, lod_px, environment
	r.background, r.floor, r.lod_px, r.environment_look.background = {}, {}, 0, false
	_ = render.render_viewport(r, cmd, &c.target, view, proj, draws, false)
	c.drawn = true
}

// Writes the screenshot, or hands the turntable its frame, once the frame that drew it
// is submitted. A screenshot's target is let go after; the turntable keeps it for its
// next frame.
capture_finish :: proc(app: ^App) {
	c := &app.capture
	if !c.drawn do return
	c.drawn = false
	start := time.tick_now()
	path, turntable, transparent := c.path, c.turntable, c.transparent
	c.path, c.turntable = "", false
	defer {
		delete(path)
		if !turntable_recording(app) do render.viewport_target_destroy(&app.renderer, &c.target)
	}
	w, h := int(app.target.width), int(app.target.height)
	shown := render.viewport_download(&app.renderer, &app.target, context.temp_allocator, viewport_shown(app))
	cut: []u8
	if transparent do cut = render.viewport_download(&app.renderer, &c.target, context.temp_allocator)
	if shown == nil || (transparent && cut == nil) {
		file_note(app, true, "Could not read the viewport back: %s", sdl.GetError())
		if turntable do turntable_stop(app, "the viewport could not be read back")
		return
	}
	if transparent do capture_compose(shown, cut)
	if turntable {
		turntable_take(app, shown, w, h, transparent)
		return
	}
	if !image_save(app, path, shown, w, h, alpha = true) do return
	file_note(app, false, "Saved %s (%d x %d, transparent) in %.0f ms", filepath.base(path), w, h, time.duration_milliseconds(time.tick_since(start)))
}

// Gives `shown` (RGBA8 rows) the alpha of `cut`, the same view drawn on transparent
// black: the viewport's colour where the objects cover a pixel wholly, none where they
// leave it empty, and between, `cut`'s colour, which the edge's coverage scaled, divided
// back out.
capture_compose :: proc(shown, cut: []u8) {
	for i := 0; i + 3 < len(shown); i += 4 {
		a := u32(cut[i + 3])
		switch a {
		case 255:
		case 0:
			shown[i], shown[i + 1], shown[i + 2], shown[i + 3] = 0, 0, 0, 0
		case:
			for k in 0 ..< 3 do shown[i + k] = u8(min((u32(cut[i + k]) * 255 + a / 2) / a, 255))
			shown[i + 3] = u8(a)
		}
	}
}
