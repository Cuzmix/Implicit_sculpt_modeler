#+build linux
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:sys/posix"

// Video on Linux (video.odin): the ffmpeg on the PATH, fed raw RGBA frames through a
// pipe, makes the MP4 with its default encoder for the container (libx264 where ffmpeg
// has it) in yuv420p, which every player takes. Without ffmpeg there is no video, and the
// frames stay as pictures. Android, a Linux too, has MediaCodec instead, not yet here.
VIDEO_AVAILABLE :: ODIN_PLATFORM_SUBTARGET != .Android

Video_Backend :: struct {
	process: os.Process,
	input:   ^os.File, // the pipe's end ffmpeg reads its frames from
}

video_backend_open :: proc(v: ^Video) -> string {
	// A write to the pipe after ffmpeg has gone would otherwise end the app: ignored, it
	// fails as a write, and the video stops with a note.
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
	read, write, err := os.pipe()
	if err != nil do return fmt.tprintf("no pipe to ffmpeg: %v", err)
	command := []string {
		"ffmpeg", "-loglevel", "error", "-y",
		"-f", "rawvideo", "-pix_fmt", "rgba", "-s", fmt.tprintf("%dx%d", v.width, v.height), "-r", fmt.tprintf("%d", v.fps), "-i", "-",
		"-pix_fmt", "yuv420p", "-movflags", "+faststart", v.path,
	}
	process, perr := os.process_start({command = command, stdin = read})
	os.close(read)
	if perr != nil {
		os.close(write)
		log.warnf("video: ffmpeg did not start: %v", perr)
		return "it needs ffmpeg, which was not found"
	}
	v.backend = {process = process, input = write}
	return ""
}

video_backend_frame :: proc(v: ^Video, rgba: []u8) -> bool {
	_, err := os.write(v.backend.input, rgba)
	if err != nil do log.warnf("video: ffmpeg took no more frames: %v", err)
	return err == nil
}

video_backend_close :: proc(v: ^Video, keep: bool) -> bool {
	b := &v.backend
	os.close(b.input)
	if !keep do _ = os.process_kill(b.process)
	state, err := os.process_wait(b.process)
	if err != nil do return false
	if keep && state.exit_code != 0 do log.warnf("video: ffmpeg ended with %d", state.exit_code)
	return state.exited && state.exit_code == 0
}
