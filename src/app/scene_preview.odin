package main

import "core:hash"
import "core:mem"
import "core:strings"
import "core:time"
import sdl "vendor:sdl3"

import "../geom"
import "../png_write"
import "../render"

// The scene file's preview: a small picture of the viewport and a few numbers stored
// right after the file's version (scene version 22), as Blender keeps a thumbnail inside
// each .blend, so the Home screen can show a saved scene, and say when it was saved and
// how big it is, by reading only the start of the file, never the whole scene.
//
// The picture is the viewport as it was last drawn, without the brush ring or the gizmo,
// shrunk to PREVIEW_LONG pixels on its long side. It is taken while the app rests, at
// most every PREVIEW_EVERY seconds and only when the scene or the view changed: the copy
// back from the GPU is collected once its fence signals (render.Readback), so no frame
// waits for it. A save takes a fresh one if it is out of date, since a save stops the
// frame anyway; an autosave writes the last one taken and never touches the GPU.

// The picture's long side, in pixels.
PREVIEW_LONG :: 320
// Seconds of rest before a picture is taken, and between two.
PREVIEW_REST :: 1.0
PREVIEW_EVERY :: 2.0
// The most a preview block may hold: more is a damaged file.
PREVIEW_BLOCK_MAX :: 4 << 20
// The numbers before the picture: when, objects, vertices, width and height.
PREVIEW_HEAD :: 8 + 4 + 8 + 2 + 2

Scene_Preview :: struct {
	png:        [dynamic]u8, // the picture as a PNG, empty for none yet
	w, h:       int,
	stamp:      u64, // what it shows (preview_stamp), 0 for nothing
	grab:       render.Readback, // a picture under way
	grab_stamp: u64,
	grab_w:     int,
	grab_h:     int,
	busy_at:    f64, // input_clock of the last frame not at rest
	tried_at:   f64, // ...and of the last look at whether a picture was due
	background: bool, // the app is in the background, where it draws nothing
	// For the exit stats: pictures taken and the time the last one took to shrink and encode.
	taken:      int,
	ms:         f64,
}

// What a saved scene's start says about it (scene_preview_read).
Scene_File_Info :: struct {
	version:  u32,
	saved:    i64, // unix seconds when it was written; 0 for a file from before version 22
	objects:  int,
	vertices: int,
	w, h:     int, // the picture's size, 0 for none
}

scene_preview_destroy :: proc(app: ^App) {
	p := &app.preview
	if app.renderer.device != nil do render.readback_cancel(&app.renderer, &p.grab)
	delete(p.png)
	p^ = {}
}

// What the picture would show: the scene as the autosave fingerprints it, and the view.
preview_stamp :: proc(app: ^App) -> u64 {
	c := app.camera
	keyed := [7]f32{c.target.x, c.target.y, c.target.z, c.distance, c.yaw, c.pitch, c.roll}
	parts := [2]u64{scene_fingerprint(app), hash.fnv64a(mem.slice_to_bytes(keyed[:]))}
	return max(hash.fnv64a(mem.slice_to_bytes(parts[:])), 1)
}

// Collects a picture under way, or starts one once the app has rested and the scene or
// the view changed since the last. Called at the end of each frame, after its submit.
preview_frame :: proc(app: ^App) {
	p := &app.preview
	if app.renderer.device == nil do return
	if p.grab.transfer != nil {
		pixels, done := render.readback_poll(&app.renderer, &p.grab, context.temp_allocator)
		if done && pixels != nil do preview_take(app, pixels, p.grab_w, p.grab_h, p.grab_stamp)
		return
	}
	now := input_clock(app)
	if !autosave_quiet(app) || p.background {
		p.busy_at = now
		return
	}
	if now - p.busy_at < PREVIEW_REST || now - p.tried_at < PREVIEW_EVERY || len(app.scene.objects) == 0 do return
	p.tried_at = now
	stamp := preview_stamp(app)
	if stamp == p.stamp do return
	shown := viewport_shown(app)
	if render.readback_start(&app.renderer, &p.grab, shown if shown != nil else app.target.color, app.target.width, app.target.height) {
		p.grab_stamp, p.grab_w, p.grab_h = stamp, int(app.target.width), int(app.target.height)
	}
}

// Brings the picture up to date before a save, waiting for the GPU when it is not.
preview_refresh :: proc(app: ^App) {
	p := &app.preview
	if app.renderer.device == nil || app.target.color == nil || p.background do return
	stamp := preview_stamp(app)
	if stamp == p.stamp do return
	render.readback_cancel(&app.renderer, &p.grab)
	w, h := int(app.target.width), int(app.target.height)
	if pixels := render.viewport_download(&app.renderer, &app.target, context.temp_allocator, viewport_shown(app)); pixels != nil {
		preview_take(app, pixels, w, h, stamp)
	}
}

// Shrinks the viewport's RGBA8 `pixels` to the picture's size, averaging every pixel it
// covers, and keeps it as a PNG showing `stamp`.
preview_take :: proc(app: ^App, pixels: []u8, w, h: int, stamp: u64) {
	start := time.tick_now()
	small, sw, sh := preview_shrink(pixels, w, h, PREVIEW_LONG, context.temp_allocator)
	if small == nil do return
	p := &app.preview
	clear(&p.png)
	append(&p.png, ..png_write.encode(small, sw, sh, alpha = false, allocator = context.temp_allocator))
	p.w, p.h, p.stamp = sw, sh, stamp
	p.taken += 1
	p.ms = time.duration_milliseconds(time.tick_since(start))
}

// `pixels` (RGBA8, `w` by `h`) averaged down so the long side is at most `long`: each
// pixel of the result the mean of the source pixels its area covers, so thin lines and
// fine detail fade rather than flicker in and out. Nil for an empty image.
preview_shrink :: proc(pixels: []u8, w, h, long: int, allocator := context.allocator) -> (out: []u8, ow, oh: int) {
	if w <= 0 || h <= 0 || len(pixels) < w * h * 4 do return nil, 0, 0
	ow, oh = w, h
	if max(w, h) > long {
		ow = max(w * long / max(w, h), 1)
		oh = max(h * long / max(w, h), 1)
	}
	out = make([]u8, ow * oh * 4, allocator)
	for y in 0 ..< oh {
		y0, y1 := y * h / oh, max((y + 1) * h / oh, y * h / oh + 1)
		for x in 0 ..< ow {
			x0, x1 := x * w / ow, max((x + 1) * w / ow, x * w / ow + 1)
			sum: [4]u32
			for sy in y0 ..< y1 do for sx in x0 ..< x1 {
				at := (sy * w + sx) * 4
				sum += {u32(pixels[at]), u32(pixels[at + 1]), u32(pixels[at + 2]), u32(pixels[at + 3])}
			}
			n := u32((y1 - y0) * (x1 - x0))
			o := (y * ow + x) * 4
			for c in 0 ..< 4 do out[o + c] = u8((sum[c] + n / 2) / n)
		}
	}
	return
}

// Writes the preview block a scene file of version 22 keeps after its version: its
// length, then when, how many objects and vertices, the picture's size and the PNG.
preview_block_put :: proc(app: ^App, out: ^[dynamic]u8) {
	p := &app.preview
	vertices := 0
	for obj in app.scene.objects do vertices += object_vertex_count(obj)
	geom.byte_put(out, u32(PREVIEW_HEAD + len(p.png)))
	geom.byte_put(out, unix_now())
	geom.byte_put(out, u32(len(app.scene.objects)))
	geom.byte_put(out, u64(vertices))
	has := len(p.png) > 0
	geom.byte_put(out, u16(p.w if has else 0))
	geom.byte_put(out, u16(p.h if has else 0))
	append(out, ..p.png[:])
}

// Steps over the preview block of a scene file being opened, which the scene does not
// need; false when its length runs past the file or past PREVIEW_BLOCK_MAX, a damaged
// file. The picture itself is not looked at: a bad one only shows no picture at Home.
preview_block_skip :: proc(r: ^geom.Byte_Reader) -> bool {
	n := int(geom.byte_get(r, u32))
	if !r.ok || n < PREVIEW_HEAD || n > PREVIEW_BLOCK_MAX do return false
	_ = geom.byte_get_bytes(r, n)
	return r.ok
}

// Reads what the start of the scene file at `path` says about it and its picture's PNG
// bytes (nil for none), reading no more of the file than that: through SDL's IO, which
// also opens Android's content:// URIs. ok is false for a file that is not a scene this
// app reads or whose preview block is damaged.
scene_preview_read :: proc(path: string, allocator := context.allocator) -> (info: Scene_File_Info, png: []u8, ok: bool) {
	io := sdl.IOFromFile(strings.clone_to_cstring(path, context.temp_allocator), "rb")
	if io == nil do return
	defer _ = sdl.CloseIO(io)
	head: [len(SCENE_MAGIC) + 4 + 4]u8
	got := int(sdl.ReadIO(io, &head, len(head)))
	if got < len(SCENE_MAGIC) + 4 || string(head[:len(SCENE_MAGIC)]) != SCENE_MAGIC do return
	r := geom.byte_reader(head[len(SCENE_MAGIC):got])
	info.version = geom.byte_get(&r, u32)
	if info.version < 1 || info.version > SCENE_VERSION do return
	if info.version < 22 do return info, nil, true
	n := int(geom.byte_get(&r, u32))
	if !r.ok || n < PREVIEW_HEAD || n > PREVIEW_BLOCK_MAX do return
	block := make([]u8, n, context.temp_allocator)
	if int(sdl.ReadIO(io, raw_data(block), uint(n))) != n do return
	b := geom.byte_reader(block)
	info.saved = geom.byte_get(&b, i64)
	info.objects = int(geom.byte_get(&b, u32))
	info.vertices = int(geom.byte_get(&b, u64))
	info.w = int(geom.byte_get(&b, u16))
	info.h = int(geom.byte_get(&b, u16))
	if !b.ok do return
	if n > PREVIEW_HEAD && info.w > 0 && info.h > 0 {
		png = make([]u8, n - PREVIEW_HEAD, allocator)
		copy(png, block[PREVIEW_HEAD:])
	} else {
		info.w, info.h = 0, 0
	}
	return info, png, true
}
