package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../camera"
import "../png_write"

// The turntable (Scene > Turntable > Record turntable...): the camera goes once round the
// scene about the world's up axis, as a model on a turntable before a still camera, and
// every frame is saved: as numbered PNG pictures, which any video tool joins into a film,
// and as one animated PNG that browsers and image viewers play as it is. It takes the
// best of a sculpting app's turntable movie, a renderer's image sequence and a
// presentation app's looping animation: the frames are the viewport's own, without the
// background when Screenshots without background is on, and the animation loops
// seamlessly, its last frame one step short of the first. Each frame is drawn at full
// detail and read back by the transparent screenshot's capture (capture.odin), so
// recording takes over the window until it ends, and a stroke or Stop ends it early.
Turntable :: struct {
	on:     bool,
	dir:    string, // the folder it writes into
	frames: int, // how many it takes in all
	frame:  int, // the next to draw
	yaw:    f32, // where the camera stood, given back after
	apng:   png_write.Apng,
	file:   ^os.File, // the animated PNG, written a frame at a time
	buffer: [dynamic]u8, // its chunks between writes
}

TURNTABLE_FRAMES_DEFAULT :: 120
TURNTABLE_FRAMES_MIN :: 24
TURNTABLE_FRAMES_MAX :: 720
// The frames a second it plays at, and so the turn takes Frames / this many seconds.
TURNTABLE_FPS :: 30
// The animated picture's widest side at most: a whole screen at every frame would make
// a file too large to send. The numbered frames keep the viewport's size.
TURNTABLE_ANIMATION_MAX :: 960
TURNTABLE_ANIMATION_NAME :: "turntable.png"

turntable_destroy :: proc(app: ^App) {
	tt := &app.turntable
	// Closing mid-recording leaves the frames written and no half animation.
	if tt.on && tt.file != nil {
		os.close(tt.file)
		path, _ := filepath.join({tt.dir, TURNTABLE_ANIMATION_NAME}, context.temp_allocator)
		_ = os.remove(path)
	}
	delete(app.turntable.dir)
	delete(app.turntable.buffer)
	app.turntable = {}
}

turntable_recording :: proc(app: ^App) -> bool {return app.turntable.on}

// Starts recording into `dir`, made if it is missing.
turntable_start :: proc(app: ^App, dir: string) {
	tt := &app.turntable
	if tt.on do return
	stroke_finish(app)
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		file_note(app, true, "Cannot make the folder %s: %v", dir, err)
		return
	}
	path, _ := filepath.join({dir, TURNTABLE_ANIMATION_NAME}, context.temp_allocator)
	file, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
	if err != nil {
		file_note(app, true, "Cannot write %s: %v", path, err)
		return
	}
	delete(tt.dir)
	tt.dir = strings.clone(dir)
	tt.on, tt.file, tt.frame = true, file, 0
	tt.frames = clamp(int(app.turntable_frames), TURNTABLE_FRAMES_MIN, TURNTABLE_FRAMES_MAX)
	tt.yaw = app.camera.yaw
	tt.apng = {}
	clear(&tt.buffer)
	app.timeline.playing = false
	log.infof("turntable: recording %d frames into %s", tt.frames, dir)
}

// Ends the recording, early with `why` (the animated PNG, cut short, is removed) or after
// its last frame with an empty `why`, and puts the camera back.
turntable_stop :: proc(app: ^App, why: string) {
	tt := &app.turntable
	if !tt.on do return
	tt.on = false
	app.camera.yaw = tt.yaw
	reason := why
	if reason == "" {
		png_write.apng_end(&tt.buffer)
		if !turntable_flush(tt) do reason = "the animated picture could not be written"
	}
	if tt.file != nil do os.close(tt.file)
	tt.file = nil
	clear(&tt.buffer)
	path, _ := filepath.join({tt.dir, TURNTABLE_ANIMATION_NAME}, context.temp_allocator)
	if reason != "" {
		_ = os.remove(path)
		file_note(app, true, "Turntable stopped after %d of %d frames: %s", tt.frame, tt.frames, reason)
		return
	}
	file_note(app, false, "Turntable: %d frames and %s in %s", tt.frames, TURNTABLE_ANIMATION_NAME, tt.dir)
}

// At the start of a frame: turns the camera to the next frame's place and asks for it to
// be read back once drawn, or stops for a stroke.
turntable_frame :: proc(app: ^App) {
	tt := &app.turntable
	if !tt.on do return
	if app.stroke.active {
		turntable_stop(app, "a stroke started")
		return
	}
	if tt.frame >= tt.frames || app.capture.turntable do return
	app.camera.yaw = tt.yaw
	camera.orbit_spin(&app.camera, 2 * math.PI * f32(tt.frame) / f32(tt.frames))
	app.capture.turntable = true
	app.capture.transparent = app.screenshot_transparent
}

// Takes one frame read back (RGBA rows, `w` by `h`, straight alpha when transparent):
// its numbered PNG, then the animation's frame; the last one ends the recording.
turntable_take :: proc(app: ^App, pixels: []u8, w, h: int, transparent: bool) {
	tt := &app.turntable
	if !tt.on do return
	path, _ := filepath.join({tt.dir, fmt.tprintf("turntable_%05d.png", tt.frame)}, context.temp_allocator)
	if !image_save(app, path, pixels, w, h, alpha = transparent) {
		turntable_stop(app, "a frame could not be written")
		return
	}
	if tt.frame == 0 {
		scale := 1
		for w / scale > TURNTABLE_ANIMATION_MAX && h / scale > 1 do scale *= 2
		tt.apng = {width = w / scale, height = h / scale, alpha = transparent, frames = tt.frames, delay = {1, TURNTABLE_FPS}}
		png_write.apng_begin(&tt.buffer, &tt.apng)
	}
	// Every frame of the animation is the first one's size, should the window change.
	png_write.apng_frame(&tt.buffer, &tt.apng, image_resize(pixels, w, h, tt.apng.width, tt.apng.height))
	if !turntable_flush(tt) {
		turntable_stop(app, "the animated picture could not be written")
		return
	}
	tt.frame += 1
	if tt.frame >= tt.frames do turntable_stop(app, "")
}

// Writes the animation's waiting chunks to its file; false when the file refused them.
@(private = "file")
turntable_flush :: proc(tt: ^Turntable) -> bool {
	if tt.file == nil do return false
	_, err := os.write(tt.file, tt.buffer[:])
	clear(&tt.buffer)
	return err == nil
}

// RGBA rows `w` by `h` resized to `dw` by `dh`, each pixel the average of the source
// pixels its area covers (whole ones, at least one), colour weighted by alpha so that a
// soft edge over nothing keeps its colour; the rows themselves at the same size. Temp
// memory.
image_resize :: proc(pixels: []u8, w, h, dw, dh: int) -> []u8 {
	if w == dw && h == dh do return pixels
	out := make([]u8, dw * dh * 4, context.temp_allocator)
	for y in 0 ..< dh {
		y0 := y * h / dh
		y1 := max((y + 1) * h / dh, y0 + 1)
		for x in 0 ..< dw {
			x0 := x * w / dw
			x1 := max((x + 1) * w / dw, x0 + 1)
			sum: [4]u32
			for sy in y0 ..< y1 {
				for sx in x0 ..< x1 {
					p := pixels[(sy * w + sx) * 4:]
					a := u32(p[3])
					for k in 0 ..< 3 do sum[k] += u32(p[k]) * a
					sum[3] += a
				}
			}
			o := out[(y * dw + x) * 4:]
			n := u32((y1 - y0) * (x1 - x0))
			if sum[3] == 0 {
				o[0], o[1], o[2], o[3] = 0, 0, 0, 0
				continue
			}
			for k in 0 ..< 3 do o[k] = u8((sum[k] + sum[3] / 2) / sum[3])
			o[3] = u8((sum[3] + n / 2) / n)
		}
	}
	return out
}
