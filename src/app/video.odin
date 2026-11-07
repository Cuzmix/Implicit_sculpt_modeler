package main

import "core:os"
import "core:strings"

// Video files (README "Turntable", "History timeline and time-lapse"): the turntable and
// the time-lapse write an MP4 beside their pictures where the system has an encoder to
// make one: Media Foundation on Windows, AVFoundation on the Mac and the iPad,
// MediaCodec on Android, and on Linux the ffmpeg on the PATH; none on the web. The
// system's own H.264 encoder costs the app no licence and runs on its hardware where it
// has one. A frame goes in as RGBA rows, opaque (a video keeps no alpha), at the size the
// file was opened at, which video_size makes even and keeps under VIDEO_MAX a side.
Video :: struct {
	path:          string, // owned
	width, height: int,
	fps:           int,
	frames:        int, // written so far
	backend:       Video_Backend, // the platform's state (video_*.odin)
}

// The longest side a video may have: 1080p's, which every system encoder takes at level
// 4.2 and which plays everywhere.
VIDEO_MAX :: 1920

// Opens a video of `w` x `h` (video_size's) at `fps` frames a second at `path`, or says
// why it cannot.
video_open :: proc(path: string, w, h, fps: int) -> (v: ^Video, why: string) {
	if !VIDEO_AVAILABLE do return nil, "this system has no video encoder"
	if w < VIDEO_ALIGN || h < VIDEO_ALIGN || w % VIDEO_ALIGN != 0 || h % VIDEO_ALIGN != 0 do return nil, "a video's sides do not suit the encoder"
	v = new(Video)
	v.path = strings.clone(path)
	v.width, v.height, v.fps = w, h, fps
	if why = video_backend_open(v); why != "" {
		delete(v.path)
		free(v)
		return nil, why
	}
	return v, ""
}

// Adds one frame, RGBA rows top to bottom at the video's size; false when the encoder
// refused it, after which only video_close (dropping the file) is left.
video_frame :: proc(v: ^Video, rgba: []u8) -> bool {
	if v == nil || len(rgba) != v.width * v.height * 4 do return false
	if !video_backend_frame(v, rgba) do return false
	v.frames += 1
	return true
}

// Ends the video: with `keep`, finishes the file (false when that failed); without,
// stops and removes what was written. Frees `v` either way.
video_close :: proc(v: ^Video, keep: bool) -> (ok: bool) {
	if v == nil do return false
	ok = video_backend_close(v, keep && v.frames > 0)
	if !keep || !ok do _ = os.remove(v.path)
	delete(v.path)
	free(v)
	return ok && keep
}

// The size a video of a `w` x `h` picture takes: scaled down until its longest side is at
// most VIDEO_MAX, each side then a multiple of the encoder's VIDEO_ALIGN.
video_size :: proc(w, h: int) -> (vw, vh: int) {
	vw, vh = w, h
	if m := max(vw, vh); m > VIDEO_MAX {
		vw = vw * VIDEO_MAX / m
		vh = vh * VIDEO_MAX / m
	}
	return max(vw &~ (VIDEO_ALIGN - 1), VIDEO_ALIGN), max(vh &~ (VIDEO_ALIGN - 1), VIDEO_ALIGN)
}

// A frame for the video from a picture `w` x `h`: resized to the video's size and laid
// opaque over black where it is transparent (a video keeps no alpha). Temp memory.
video_picture :: proc(v: ^Video, pixels: []u8, w, h: int) -> []u8 {
	sized := image_resize(pixels, w, h, v.width, v.height)
	out := make([]u8, len(sized), context.temp_allocator)
	for i := 0; i + 3 < len(sized); i += 4 {
		a := u32(sized[i + 3])
		for k in 0 ..< 3 do out[i + k] = u8((u32(sized[i + k]) * a + 127) / 255)
		out[i + 3] = 255
	}
	return out
}
