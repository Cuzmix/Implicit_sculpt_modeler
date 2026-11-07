package main

import "core:os"
import "core:path/filepath"
import "core:testing"

// A video's size keeps under VIDEO_MAX with even sides; its frames are opaque, laid over
// black where the picture was transparent.
@(test)
video_size_and_frames :: proc(t: ^testing.T) {
	w, h := video_size(3840, 2161)
	testing.expect(t, w == 1920 && h == 1080, "4K not brought to 1080p")
	w, h = video_size(801, 601)
	testing.expect(t, w == 800 && h == 600, "odd sides not made even")
	v := Video{width = 2, height = 1}
	pixels := []u8{200, 100, 50, 255, 200, 100, 50, 0}
	out := video_picture(&v, pixels, 2, 1)
	testing.expect_value(t, out[0], 200)
	testing.expect_value(t, out[3], 255)
	testing.expect(t, out[4] == 0 && out[5] == 0 && out[6] == 0 && out[7] == 255, "a transparent pixel is not black")
}

// Where the system makes videos, one opens, takes its frames and is written; dropped, it
// leaves no file. A Linux without ffmpeg has none to make, which the open says.
@(test)
video_round_trip :: proc(t: ^testing.T) {
	if !VIDEO_AVAILABLE do return
	dir := os.get_env("TMPDIR", context.temp_allocator)
	if dir == "" do dir = "/tmp" when ODIN_OS != .Windows else "."
	path, _ := filepath.join({dir, "sculpt_video_test.mp4"}, context.temp_allocator)
	v, why := video_open(path, 64, 48, 30)
	if v == nil {
		testing.expectf(t, why == "it needs ffmpeg, which was not found", "no video: %s", why)
		return
	}
	frame := make([]u8, 64 * 48 * 4, context.temp_allocator)
	for k in 0 ..< 10 {
		for i := 0; i < len(frame); i += 4 do frame[i], frame[i + 1], frame[i + 2], frame[i + 3] = u8(k * 20), 128, u8(i / 64), 255
		testing.expect(t, video_frame(v, frame), "a frame was refused")
	}
	testing.expect(t, video_close(v, true), "the video was not finished")
	info, err := os.stat(path, context.temp_allocator)
	testing.expectf(t, err == nil && info.size > 0, "no video written: %v", err)
	_ = os.remove(path)
	v, _ = video_open(path, 64, 48, 30)
	if v != nil {
		_ = video_frame(v, frame)
		testing.expect(t, !video_close(v, false))
		testing.expect(t, !os.exists(path), "a dropped video left its file")
	}
}
