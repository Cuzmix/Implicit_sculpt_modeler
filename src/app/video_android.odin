#+build linux
package main

@(require) import "core:log"
@(require) import "core:strings"
@(require) import "core:sys/posix"
@(require) import "core:time"

// Video on Android (video.odin): the NDK's MediaCodec encodes H.264 (the SoC's encoder)
// and MediaMuxer writes the MP4. Frames go in as NV12 (YUV 4:2:0, the chroma interleaved),
// the colour format every Android encoder must take, with BT.601 studio-range maths;
// sides are multiples of 16, which hardware encoders lay their planes out by. The encoder
// runs beside the app, so each frame drains what it has finished into the muxer, and the
// end sends end-of-stream and drains to it, each wait bounded.
when ODIN_PLATFORM_SUBTARGET == .Android {
	VIDEO_AVAILABLE :: true
	// The encoder takes sides that are multiples of this.
	VIDEO_ALIGN :: 16

	Video_Backend :: struct {
		codec:   rawptr, // AMediaCodec
		muxer:   rawptr, // AMediaMuxer
		fd:      posix.FD,
		track:   int, // the muxer's track, -1 until the encoder names its format
		started: bool, // the muxer started
		failed:  bool,
	}

	@(private = "file")
	Media_Buffer_Info :: struct {
		offset:                 i32,
		size:                   i32,
		presentation_time_us:   i64,
		flags:                  u32,
	}

	@(private = "file") COLOR_FORMAT_YUV420_SEMI_PLANAR :: 21
	@(private = "file") CONFIGURE_FLAG_ENCODE :: 1
	@(private = "file") BUFFER_FLAG_CODEC_CONFIG :: 2
	@(private = "file") BUFFER_FLAG_END_OF_STREAM :: 4
	@(private = "file") INFO_TRY_AGAIN_LATER :: -1
	@(private = "file") INFO_OUTPUT_FORMAT_CHANGED :: -2
	@(private = "file") MUXER_OUTPUT_MPEG_4 :: 0
	// How long one call waits for the encoder, and a frame or the end at most.
	@(private = "file") CODEC_WAIT_US :: 10_000
	@(private = "file") VIDEO_FRAME_WAIT :: 2 * time.Second
	@(private = "file") VIDEO_FINISH_WAIT :: 10 * time.Second

	foreign import mediandk "system:mediandk"

	@(default_calling_convention = "c", private = "file")
	foreign mediandk {
		AMediaFormat_new :: proc() -> rawptr ---
		AMediaFormat_delete :: proc(format: rawptr) -> i32 ---
		AMediaFormat_setString :: proc(format: rawptr, name: cstring, value: cstring) ---
		AMediaFormat_setInt32 :: proc(format: rawptr, name: cstring, value: i32) ---
		AMediaCodec_createEncoderByType :: proc(mime: cstring) -> rawptr ---
		AMediaCodec_configure :: proc(codec: rawptr, format: rawptr, surface: rawptr, crypto: rawptr, flags: u32) -> i32 ---
		AMediaCodec_start :: proc(codec: rawptr) -> i32 ---
		AMediaCodec_stop :: proc(codec: rawptr) -> i32 ---
		AMediaCodec_delete :: proc(codec: rawptr) -> i32 ---
		AMediaCodec_dequeueInputBuffer :: proc(codec: rawptr, timeout_us: i64) -> int ---
		AMediaCodec_getInputBuffer :: proc(codec: rawptr, index: uint, size: ^uint) -> [^]u8 ---
		AMediaCodec_queueInputBuffer :: proc(codec: rawptr, index: uint, offset: i64, size: uint, time_us: u64, flags: u32) -> i32 ---
		AMediaCodec_dequeueOutputBuffer :: proc(codec: rawptr, info: ^Media_Buffer_Info, timeout_us: i64) -> int ---
		AMediaCodec_getOutputBuffer :: proc(codec: rawptr, index: uint, size: ^uint) -> [^]u8 ---
		AMediaCodec_getOutputFormat :: proc(codec: rawptr) -> rawptr ---
		AMediaCodec_releaseOutputBuffer :: proc(codec: rawptr, index: uint, render: bool) -> i32 ---
		AMediaMuxer_new :: proc(fd: i32, format: i32) -> rawptr ---
		AMediaMuxer_delete :: proc(muxer: rawptr) -> i32 ---
		AMediaMuxer_addTrack :: proc(muxer: rawptr, format: rawptr) -> int ---
		AMediaMuxer_start :: proc(muxer: rawptr) -> i32 ---
		AMediaMuxer_stop :: proc(muxer: rawptr) -> i32 ---
		AMediaMuxer_writeSampleData :: proc(muxer: rawptr, track: uint, data: [^]u8, info: ^Media_Buffer_Info) -> i32 ---
	}

	video_backend_open :: proc(v: ^Video) -> string {
		b := &v.backend
		b.track, b.fd = -1, -1
		why := ""
		defer if why != "" do video_backend_close(v, false)
		b.fd = posix.open(strings.clone_to_cstring(v.path, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if b.fd < 0 {
			why = "the file could not be made"
			return why
		}
		b.muxer = AMediaMuxer_new(i32(b.fd), MUXER_OUTPUT_MPEG_4)
		b.codec = AMediaCodec_createEncoderByType("video/avc")
		if b.muxer == nil || b.codec == nil {
			why = "the system has no H.264 encoder"
			return why
		}
		format := AMediaFormat_new()
		defer AMediaFormat_delete(format)
		AMediaFormat_setString(format, "mime", "video/avc")
		AMediaFormat_setInt32(format, "width", i32(v.width))
		AMediaFormat_setInt32(format, "height", i32(v.height))
		AMediaFormat_setInt32(format, "color-format", COLOR_FORMAT_YUV420_SEMI_PLANAR)
		AMediaFormat_setInt32(format, "bitrate", i32(clamp(v.width * v.height * v.fps / 5, 1_000_000, 20_000_000)))
		AMediaFormat_setInt32(format, "frame-rate", i32(v.fps))
		AMediaFormat_setInt32(format, "i-frame-interval", 1)
		if status := AMediaCodec_configure(b.codec, format, nil, nil, CONFIGURE_FLAG_ENCODE); status != 0 {
			log.warnf("video: MediaCodec refused the format: %d", status)
			why = "the H.264 encoder does not take this size"
			return why
		}
		if AMediaCodec_start(b.codec) != 0 {
			why = "the video could not start"
			return why
		}
		return ""
	}

	// Moves what the encoder has finished into the muxer, starting the muxer once the
	// encoder names its format; with `to_end`, waits up to VIDEO_FINISH_WAIT for the end of
	// the stream.
	@(private = "file")
	video_drain :: proc(b: ^Video_Backend, to_end: bool) -> bool {
		start := time.tick_now()
		for {
			info: Media_Buffer_Info
			index := AMediaCodec_dequeueOutputBuffer(b.codec, &info, CODEC_WAIT_US if to_end else 0)
			switch {
			case index == INFO_TRY_AGAIN_LATER:
				if !to_end do return true
				if time.tick_since(start) > VIDEO_FINISH_WAIT do return false
			case index == INFO_OUTPUT_FORMAT_CHANGED:
				if b.started do return false
				b.track = AMediaMuxer_addTrack(b.muxer, AMediaCodec_getOutputFormat(b.codec))
				if b.track < 0 || AMediaMuxer_start(b.muxer) != 0 do return false
				b.started = true
			case index >= 0:
				size: uint
				data := AMediaCodec_getOutputBuffer(b.codec, uint(index), &size)
				if info.flags & BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0 && data != nil {
					if !b.started || AMediaMuxer_writeSampleData(b.muxer, uint(b.track), data, &info) != 0 {
						_ = AMediaCodec_releaseOutputBuffer(b.codec, uint(index), false)
						return false
					}
				}
				_ = AMediaCodec_releaseOutputBuffer(b.codec, uint(index), false)
				if info.flags & BUFFER_FLAG_END_OF_STREAM != 0 do return true
			}
		}
	}

	video_backend_frame :: proc(v: ^Video, rgba: []u8) -> bool {
		b := &v.backend
		start := time.tick_now()
		index: int
		for {
			index = AMediaCodec_dequeueInputBuffer(b.codec, CODEC_WAIT_US)
			if index >= 0 do break
			if !video_drain(b, false) || time.tick_since(start) > VIDEO_FRAME_WAIT do return false
		}
		size: uint
		data := AMediaCodec_getInputBuffer(b.codec, uint(index), &size)
		w, h := v.width, v.height
		need := w * h * 3 / 2
		if data == nil || int(size) < need do return false
		// RGBA to NV12: a luma byte a pixel, then a U and V pair a 2 x 2 block.
		for y in 0 ..< h {
			for x in 0 ..< w {
				p := rgba[(y * w + x) * 4:]
				r, g, bl := i32(p[0]), i32(p[1]), i32(p[2])
				data[y * w + x] = u8(((66 * r + 129 * g + 25 * bl + 128) >> 8) + 16)
			}
		}
		chroma := data[w * h:]
		for y := 0; y < h; y += 2 {
			for x := 0; x < w; x += 2 {
				r, g, bl: i32
				for dy in 0 ..< 2 do for dx in 0 ..< 2 {
					p := rgba[((y + dy) * w + x + dx) * 4:]
					r += i32(p[0]); g += i32(p[1]); bl += i32(p[2])
				}
				r, g, bl = r / 4, g / 4, bl / 4
				c := chroma[(y / 2) * w + x:]
				c[0] = u8(clamp(((-38 * r - 74 * g + 112 * bl + 128) >> 8) + 128, 0, 255))
				c[1] = u8(clamp(((112 * r - 94 * g - 18 * bl + 128) >> 8) + 128, 0, 255))
			}
		}
		at := u64(v.frames) * 1_000_000 / u64(v.fps)
		if AMediaCodec_queueInputBuffer(b.codec, uint(index), 0, uint(need), at, 0) != 0 do return false
		return video_drain(b, false)
	}

	video_backend_close :: proc(v: ^Video, keep: bool) -> bool {
		b := &v.backend
		ok := false
		if b.codec != nil {
			if keep {
				// The end of the stream, then everything the encoder still holds.
				start := time.tick_now()
				for time.tick_since(start) < VIDEO_FRAME_WAIT {
					index := AMediaCodec_dequeueInputBuffer(b.codec, CODEC_WAIT_US)
					if index < 0 do continue
					ok = AMediaCodec_queueInputBuffer(b.codec, uint(index), 0, 0, u64(v.frames) * 1_000_000 / u64(v.fps), BUFFER_FLAG_END_OF_STREAM) == 0
					break
				}
				ok = ok && video_drain(b, true)
			}
			_ = AMediaCodec_stop(b.codec)
			_ = AMediaCodec_delete(b.codec)
		}
		if b.muxer != nil {
			if b.started do ok = AMediaMuxer_stop(b.muxer) == 0 && ok
			_ = AMediaMuxer_delete(b.muxer)
		}
		if b.fd >= 0 do posix.close(b.fd)
		b^ = {}
		return ok
	}
}
