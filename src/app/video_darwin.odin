#+build darwin
package main

import "base:intrinsics"
import "core:log"
import NS "core:sys/darwin/Foundation"
import "core:time"

// Video on the Mac and the iPad (video.odin): AVFoundation's asset writer makes the MP4
// with the system's H.264 encoder (the media engine's, in hardware). Frames go in as
// 32-bit BGRA pixel buffers from the writer's own pool, stamped at frame / fps seconds.
// The writer works on its own queues, so a frame may wait for the input to be ready and
// the end for the file to be finished: each wait is bounded.
VIDEO_AVAILABLE :: true
// The encoder takes sides that are multiples of this.
VIDEO_ALIGN :: 2

Video_Backend :: struct {
	writer:  ^Av_Asset_Writer,
	input:   ^NS.Object, // AVAssetWriterInput, retained
	adaptor: ^NS.Object, // AVAssetWriterInputPixelBufferAdaptor, retained
}

@(private = "file", objc_class = "AVAssetWriter")
Av_Asset_Writer :: struct {
	using _: NS.Object,
}

@(private = "file", objc_class = "AVAssetWriterInput")
Av_Asset_Writer_Input :: struct {
	using _: NS.Object,
}

@(private = "file", objc_class = "AVAssetWriterInputPixelBufferAdaptor")
Av_Pixel_Buffer_Adaptor :: struct {
	using _: NS.Object,
}

// CoreMedia's time: value / timescale seconds.
@(private = "file")
Cm_Time :: struct {
	value:     i64,
	timescale: i32,
	flags:     u32, // 1: valid
	epoch:     i64,
}

// AVAssetWriterStatus.
@(private = "file") AV_WRITING :: 1
@(private = "file") AV_COMPLETED :: 2
// kCVPixelFormatType_32BGRA, 'BGRA'.
@(private = "file") CV_BGRA :: 0x42475241
// How long a frame waits for the input, and the end for the file, at most.
@(private = "file") VIDEO_FRAME_WAIT :: 2 * time.Second
@(private = "file") VIDEO_FINISH_WAIT :: 30 * time.Second

foreign import avfoundation "system:AVFoundation.framework"
foreign import corevideo "system:CoreVideo.framework"
foreign import coremedia "system:CoreMedia.framework"

@(private = "file")
foreign avfoundation {
	AVFileTypeMPEG4: ^NS.String
	AVMediaTypeVideo: ^NS.String
	AVVideoCodecKey: ^NS.String
	AVVideoCodecTypeH264: ^NS.String
	AVVideoWidthKey: ^NS.String
	AVVideoHeightKey: ^NS.String
}

@(private = "file")
foreign corevideo {
	kCVPixelBufferPixelFormatTypeKey: ^NS.String
	kCVPixelBufferWidthKey: ^NS.String
	kCVPixelBufferHeightKey: ^NS.String
}

@(default_calling_convention = "c", private = "file")
foreign corevideo {
	CVPixelBufferPoolCreatePixelBuffer :: proc(allocator: rawptr, pool: rawptr, out: ^rawptr) -> i32 ---
	CVPixelBufferLockBaseAddress :: proc(buffer: rawptr, flags: u64) -> i32 ---
	CVPixelBufferUnlockBaseAddress :: proc(buffer: rawptr, flags: u64) -> i32 ---
	CVPixelBufferGetBaseAddress :: proc(buffer: rawptr) -> [^]u8 ---
	CVPixelBufferGetBytesPerRow :: proc(buffer: rawptr) -> uint ---
	CVPixelBufferRelease :: proc(buffer: rawptr) ---
}

@(default_calling_convention = "c", private = "file")
foreign coremedia {
	CMTimeMake :: proc(value: i64, timescale: i32) -> Cm_Time ---
}

@(private = "file")
dictionary :: proc(keys: []^NS.String, values: []^NS.Object) -> ^NS.Dictionary {
	return NS.Dictionary_dictionaryWithObjects(raw_data(values), cast([^]^NS.Object)raw_data(keys), NS.UInteger(len(keys)))
}

video_backend_open :: proc(v: ^Video) -> string {
	b := &v.backend
	path := NS.String.alloc()->initWithOdinString(v.path)
	defer NS.release(path)
	url := NS.URL.alloc()->initFileURLWithPath(path)
	defer NS.release(url)
	failure: ^NS.Object
	allocated := intrinsics.objc_send(^Av_Asset_Writer, Av_Asset_Writer, "alloc")
	b.writer = intrinsics.objc_send(^Av_Asset_Writer, allocated, "initWithURL:fileType:error:", url, AVFileTypeMPEG4, &failure)
	if b.writer == nil {
		log.warn("video: AVAssetWriter refused the file")
		return "the file could not be made"
	}
	why := ""
	defer if why != "" do video_backend_close(v, false)
	width, height := NS.Number_numberWithInt(v.width), NS.Number_numberWithInt(v.height)
	settings := dictionary({AVVideoCodecKey, AVVideoWidthKey, AVVideoHeightKey}, {AVVideoCodecTypeH264, width, height})
	input := intrinsics.objc_send(^NS.Object, Av_Asset_Writer_Input, "assetWriterInputWithMediaType:outputSettings:", AVMediaTypeVideo, settings)
	if input == nil {
		why = "the system has no H.264 encoder for this size"
		return why
	}
	b.input = intrinsics.objc_send(^NS.Object, input, "retain")
	intrinsics.objc_send(nil, b.input, "setExpectsMediaDataInRealTime:", NS.BOOL(false))
	pixels := dictionary({kCVPixelBufferPixelFormatTypeKey, kCVPixelBufferWidthKey, kCVPixelBufferHeightKey}, {NS.Number_numberWithU32(CV_BGRA), width, height})
	adaptor := intrinsics.objc_send(^NS.Object, Av_Pixel_Buffer_Adaptor, "assetWriterInputPixelBufferAdaptorWithAssetWriterInput:sourcePixelBufferAttributes:", b.input, pixels)
	if adaptor == nil {
		why = "the encoder does not take the frames"
		return why
	}
	b.adaptor = intrinsics.objc_send(^NS.Object, adaptor, "retain")
	if !bool(intrinsics.objc_send(NS.BOOL, b.writer, "canAddInput:", b.input)) {
		why = "the system has no H.264 encoder for this size"
		return why
	}
	intrinsics.objc_send(nil, b.writer, "addInput:", b.input)
	if !bool(intrinsics.objc_send(NS.BOOL, b.writer, "startWriting")) {
		log.warn("video: AVAssetWriter did not start")
		why = "the video could not start"
		return why
	}
	intrinsics.objc_send(nil, b.writer, "startSessionAtSourceTime:", CMTimeMake(0, i32(v.fps)))
	return ""
}

video_backend_frame :: proc(v: ^Video, rgba: []u8) -> bool {
	b := &v.backend
	start := time.tick_now()
	for !bool(intrinsics.objc_send(NS.BOOL, b.input, "isReadyForMoreMediaData")) {
		if intrinsics.objc_send(NS.Integer, b.writer, "status") != AV_WRITING || time.tick_since(start) > VIDEO_FRAME_WAIT {
			log.warn("video: the encoder took no more frames")
			return false
		}
		time.sleep(time.Millisecond)
	}
	pool := intrinsics.objc_send(rawptr, b.adaptor, "pixelBufferPool")
	buffer: rawptr
	if pool == nil || CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) != 0 || buffer == nil do return false
	defer CVPixelBufferRelease(buffer)
	if CVPixelBufferLockBaseAddress(buffer, 0) != 0 do return false
	base := CVPixelBufferGetBaseAddress(buffer)
	stride := int(CVPixelBufferGetBytesPerRow(buffer))
	row := v.width * 4
	// RGBA rows to BGRA rows, the buffer's rows perhaps padded.
	for y in 0 ..< v.height {
		from := rgba[y * row:][:row]
		to := base[y * stride:][:row]
		for x := 0; x < row; x += 4 {
			to[x], to[x + 1], to[x + 2], to[x + 3] = from[x + 2], from[x + 1], from[x], 255
		}
	}
	_ = CVPixelBufferUnlockBaseAddress(buffer, 0)
	at := CMTimeMake(i64(v.frames), i32(v.fps))
	return bool(intrinsics.objc_send(NS.BOOL, b.adaptor, "appendPixelBuffer:withPresentationTime:", buffer, at))
}

video_backend_close :: proc(v: ^Video, keep: bool) -> bool {
	b := &v.backend
	ok := false
	if b.writer != nil {
		writing := intrinsics.objc_send(NS.Integer, b.writer, "status") == AV_WRITING
		if keep && writing {
			intrinsics.objc_send(nil, b.input, "markAsFinished")
			done := NS.Block_createLocal(nil, proc "c" (data: rawptr) {})
			intrinsics.objc_send(nil, b.writer, "finishWritingWithCompletionHandler:", done)
			start := time.tick_now()
			for intrinsics.objc_send(NS.Integer, b.writer, "status") == AV_WRITING && time.tick_since(start) < VIDEO_FINISH_WAIT do time.sleep(time.Millisecond)
			ok = intrinsics.objc_send(NS.Integer, b.writer, "status") == AV_COMPLETED
			if !ok do log.warn("video: AVAssetWriter did not finish the file")
			NS.release(done)
		} else if writing {
			intrinsics.objc_send(nil, b.writer, "cancelWriting")
		}
		NS.release(b.writer)
	}
	if b.adaptor != nil do NS.release(b.adaptor)
	if b.input != nil do NS.release(b.input)
	b^ = {}
	return ok
}
