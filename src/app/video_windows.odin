#+build windows
package main

import "core:log"
import win "core:sys/windows"

// Video on Windows (video.odin): Media Foundation's sink writer, which picks the MP4
// container from the file's name and the system's H.264 encoder (the GPU's where the
// driver gives one) for the stream. Frames go in as RGB32 (BGRX bytes, rows bottom up,
// as Media Foundation lays RGB out), stamped in 100 ns units.
VIDEO_AVAILABLE :: true

Video_Backend :: struct {
	writer:  ^Com, // IMFSinkWriter
	stream:  u32,
	started: bool, // MFStartup ran and wants its MFShutdown
}

// A COM object as Media Foundation hands it out: its methods are called by their place
// in the interface's table (the *_AT constants, counted from IUnknown's three).
@(private = "file")
Com :: struct {
	vtable: [^]rawptr,
}

@(private = "file")
com_release :: proc(o: ^Com) {
	if o == nil do return
	release := cast(proc "system" (this: ^Com) -> u32)o.vtable[2]
	_ = release(o)
}

// IMFAttributes, which IMFMediaType and IMFSample begin with.
@(private = "file") ATTR_SET_UINT32_AT :: 21
@(private = "file") ATTR_SET_UINT64_AT :: 22
@(private = "file") ATTR_SET_GUID_AT :: 24
// IMFSample, after IMFAttributes' 30 methods.
@(private = "file") SAMPLE_SET_TIME_AT :: 36
@(private = "file") SAMPLE_SET_DURATION_AT :: 38
@(private = "file") SAMPLE_ADD_BUFFER_AT :: 42
// IMFMediaBuffer.
@(private = "file") BUFFER_LOCK_AT :: 3
@(private = "file") BUFFER_UNLOCK_AT :: 4
@(private = "file") BUFFER_SET_LENGTH_AT :: 6
// IMFSinkWriter.
@(private = "file") WRITER_ADD_STREAM_AT :: 3
@(private = "file") WRITER_SET_INPUT_AT :: 4
@(private = "file") WRITER_BEGIN_AT :: 5
@(private = "file") WRITER_WRITE_AT :: 6
@(private = "file") WRITER_FINALIZE_AT :: 11

@(private = "file")
set_guid :: proc(o: ^Com, key, value: Mf_Guid) -> win.HRESULT {
	f := cast(proc "system" (this: ^Com, key: ^win.GUID, value: ^win.GUID) -> win.HRESULT)o.vtable[ATTR_SET_GUID_AT]
	k, v := guid(key), guid(value)
	return f(o, &k, &v)
}

@(private = "file")
set_u32 :: proc(o: ^Com, key: Mf_Guid, value: u32) -> win.HRESULT {
	f := cast(proc "system" (this: ^Com, key: ^win.GUID, value: u32) -> win.HRESULT)o.vtable[ATTR_SET_UINT32_AT]
	k := guid(key)
	return f(o, &k, value)
}

@(private = "file")
set_u64 :: proc(o: ^Com, key: Mf_Guid, value: u64) -> win.HRESULT {
	f := cast(proc "system" (this: ^Com, key: ^win.GUID, value: u64) -> win.HRESULT)o.vtable[ATTR_SET_UINT64_AT]
	k := guid(key)
	return f(o, &k, value)
}

@(private = "file")
pair :: proc(hi, lo: int) -> u64 {return u64(hi) << 32 | u64(u32(lo))}

// mfapi.h's GUIDs: the first three parts, then the last eight bytes in order as one
// number, so each reads as the header writes it.
@(private = "file")
Mf_Guid :: [4]u64

@(private = "file")
guid :: proc(g: Mf_Guid) -> (out: win.GUID) {
	out.Data1, out.Data2, out.Data3 = win.DWORD(g[0]), win.WORD(g[1]), win.WORD(g[2])
	for k in 0 ..< 8 do out.Data4[k] = win.BYTE(g[3] >> uint(56 - 8 * k))
	return
}
@(private = "file") MF_MT_MAJOR_TYPE :: Mf_Guid{0x48eba18e, 0xf8c9, 0x4687, 0xbf110a74c9f96a8f}
@(private = "file") MF_MT_SUBTYPE :: Mf_Guid{0xf7e34c9a, 0x42e8, 0x4714, 0xb74bcb29d72c35e5}
@(private = "file") MF_MT_AVG_BITRATE :: Mf_Guid{0x20332624, 0xfb0d, 0x4d9e, 0xbd0dcbf6786c102e}
@(private = "file") MF_MT_INTERLACE_MODE :: Mf_Guid{0xe2724bb8, 0xe676, 0x4806, 0xb4b2a8d6efb44ccd}
@(private = "file") MF_MT_FRAME_SIZE :: Mf_Guid{0x1652c33d, 0xd6b2, 0x4012, 0xb83472030849a37d}
@(private = "file") MF_MT_FRAME_RATE :: Mf_Guid{0xc459a2e8, 0x3d2c, 0x4e44, 0xb132fee5156c7bb0}
@(private = "file") MF_MT_PIXEL_ASPECT_RATIO :: Mf_Guid{0xc6376a1e, 0x8d0a, 0x4027, 0xbe456d9a0ad39bb6}
@(private = "file") MF_MEDIA_TYPE_VIDEO :: Mf_Guid{0x73646976, 0x0000, 0x0010, 0x800000aa00389b71}
@(private = "file") MF_VIDEO_FORMAT_H264 :: Mf_Guid{0x34363248, 0x0000, 0x0010, 0x800000aa00389b71}
@(private = "file") MF_VIDEO_FORMAT_RGB32 :: Mf_Guid{0x00000016, 0x0000, 0x0010, 0x800000aa00389b71}

@(private = "file") MF_VERSION :: 0x00020070
@(private = "file") MF_INTERLACE_PROGRESSIVE :: 2
// 100 ns units a second, the samples' clock.
@(private = "file") MF_SECOND :: 10_000_000

foreign import mfplat "system:mfplat.lib"
foreign import mfreadwrite "system:mfreadwrite.lib"

@(default_calling_convention = "system", private = "file")
foreign mfplat {
	MFStartup :: proc(version: u32, flags: u32) -> win.HRESULT ---
	MFShutdown :: proc() -> win.HRESULT ---
	MFCreateMediaType :: proc(out: ^^Com) -> win.HRESULT ---
	MFCreateSample :: proc(out: ^^Com) -> win.HRESULT ---
	MFCreateMemoryBuffer :: proc(max_length: u32, out: ^^Com) -> win.HRESULT ---
}

@(default_calling_convention = "system", private = "file")
foreign mfreadwrite {
	MFCreateSinkWriterFromURL :: proc(url: win.wstring, byte_stream: rawptr, attributes: rawptr, out: ^^Com) -> win.HRESULT ---
}

video_backend_open :: proc(v: ^Video) -> string {
	b := &v.backend
	// The app's thread may have COM already, in either model; Media Foundation works in both.
	_ = win.CoInitializeEx(nil, .APARTMENTTHREADED)
	if hr := MFStartup(MF_VERSION, 0); win.FAILED(hr) {
		log.warnf("video: MFStartup failed: 0x%x", u32(hr))
		return "Media Foundation is missing (Windows N needs the Media Feature Pack)"
	}
	b.started = true
	why := ""
	defer if why != "" do video_backend_close(v, false)
	if hr := MFCreateSinkWriterFromURL(win.utf8_to_wstring(v.path), nil, nil, &b.writer); win.FAILED(hr) {
		log.warnf("video: MFCreateSinkWriterFromURL failed: 0x%x", u32(hr))
		why = "the file could not be made"
		return why
	}
	// What the file holds: H.264 at about 0.2 bits a pixel, plenty for a turning model.
	out: ^Com
	if win.FAILED(MFCreateMediaType(&out)) {
		why = "Media Foundation refused a media type"
		return why
	}
	defer com_release(out)
	bitrate := clamp(v.width * v.height * v.fps / 5, 1_000_000, 20_000_000)
	ok := win.SUCCEEDED(set_guid(out, MF_MT_MAJOR_TYPE, MF_MEDIA_TYPE_VIDEO))
	ok = ok && win.SUCCEEDED(set_guid(out, MF_MT_SUBTYPE, MF_VIDEO_FORMAT_H264))
	ok = ok && win.SUCCEEDED(set_u32(out, MF_MT_AVG_BITRATE, u32(bitrate)))
	ok = ok && win.SUCCEEDED(set_u32(out, MF_MT_INTERLACE_MODE, MF_INTERLACE_PROGRESSIVE))
	ok = ok && win.SUCCEEDED(set_u64(out, MF_MT_FRAME_SIZE, pair(v.width, v.height)))
	ok = ok && win.SUCCEEDED(set_u64(out, MF_MT_FRAME_RATE, pair(v.fps, 1)))
	ok = ok && win.SUCCEEDED(set_u64(out, MF_MT_PIXEL_ASPECT_RATIO, pair(1, 1)))
	add := cast(proc "system" (this: ^Com, type: ^Com, index: ^u32) -> win.HRESULT)b.writer.vtable[WRITER_ADD_STREAM_AT]
	if !ok || win.FAILED(add(b.writer, out, &b.stream)) {
		why = "the system has no H.264 encoder for this size"
		return why
	}
	// What goes in: the frames as RGB32.
	input: ^Com
	if win.FAILED(MFCreateMediaType(&input)) {
		why = "Media Foundation refused a media type"
		return why
	}
	defer com_release(input)
	ok = win.SUCCEEDED(set_guid(input, MF_MT_MAJOR_TYPE, MF_MEDIA_TYPE_VIDEO))
	ok = ok && win.SUCCEEDED(set_guid(input, MF_MT_SUBTYPE, MF_VIDEO_FORMAT_RGB32))
	ok = ok && win.SUCCEEDED(set_u32(input, MF_MT_INTERLACE_MODE, MF_INTERLACE_PROGRESSIVE))
	ok = ok && win.SUCCEEDED(set_u64(input, MF_MT_FRAME_SIZE, pair(v.width, v.height)))
	ok = ok && win.SUCCEEDED(set_u64(input, MF_MT_FRAME_RATE, pair(v.fps, 1)))
	ok = ok && win.SUCCEEDED(set_u64(input, MF_MT_PIXEL_ASPECT_RATIO, pair(1, 1)))
	set_input := cast(proc "system" (this: ^Com, stream: u32, type: ^Com, params: rawptr) -> win.HRESULT)b.writer.vtable[WRITER_SET_INPUT_AT]
	if !ok || win.FAILED(set_input(b.writer, b.stream, input, nil)) {
		why = "the H.264 encoder does not take the frames"
		return why
	}
	begin := cast(proc "system" (this: ^Com) -> win.HRESULT)b.writer.vtable[WRITER_BEGIN_AT]
	if hr := begin(b.writer); win.FAILED(hr) {
		log.warnf("video: BeginWriting failed: 0x%x", u32(hr))
		why = "the video could not start"
		return why
	}
	return ""
}

video_backend_frame :: proc(v: ^Video, rgba: []u8) -> bool {
	b := &v.backend
	size := u32(v.width * v.height * 4)
	buffer: ^Com
	if win.FAILED(MFCreateMemoryBuffer(size, &buffer)) do return false
	defer com_release(buffer)
	lock := cast(proc "system" (this: ^Com, data: ^[^]u8, max_length: ^u32, length: ^u32) -> win.HRESULT)buffer.vtable[BUFFER_LOCK_AT]
	unlock := cast(proc "system" (this: ^Com) -> win.HRESULT)buffer.vtable[BUFFER_UNLOCK_AT]
	set_length := cast(proc "system" (this: ^Com, length: u32) -> win.HRESULT)buffer.vtable[BUFFER_SET_LENGTH_AT]
	data: [^]u8
	if win.FAILED(lock(buffer, &data, nil, nil)) do return false
	// RGBA rows top down to BGRX rows bottom up.
	row := v.width * 4
	for y in 0 ..< v.height {
		from := rgba[y * row:][:row]
		to := data[(v.height - 1 - y) * row:][:row]
		for x := 0; x < row; x += 4 {
			to[x], to[x + 1], to[x + 2], to[x + 3] = from[x + 2], from[x + 1], from[x], 255
		}
	}
	_ = unlock(buffer)
	if win.FAILED(set_length(buffer, size)) do return false
	sample: ^Com
	if win.FAILED(MFCreateSample(&sample)) do return false
	defer com_release(sample)
	add_buffer := cast(proc "system" (this: ^Com, buffer: ^Com) -> win.HRESULT)sample.vtable[SAMPLE_ADD_BUFFER_AT]
	set_time := cast(proc "system" (this: ^Com, time: i64) -> win.HRESULT)sample.vtable[SAMPLE_SET_TIME_AT]
	set_duration := cast(proc "system" (this: ^Com, duration: i64) -> win.HRESULT)sample.vtable[SAMPLE_SET_DURATION_AT]
	duration := i64(MF_SECOND / v.fps)
	if win.FAILED(add_buffer(sample, buffer)) || win.FAILED(set_time(sample, i64(v.frames) * duration)) || win.FAILED(set_duration(sample, duration)) do return false
	write := cast(proc "system" (this: ^Com, stream: u32, sample: ^Com) -> win.HRESULT)b.writer.vtable[WRITER_WRITE_AT]
	if hr := write(b.writer, b.stream, sample); win.FAILED(hr) {
		log.warnf("video: WriteSample failed: 0x%x", u32(hr))
		return false
	}
	return true
}

video_backend_close :: proc(v: ^Video, keep: bool) -> bool {
	b := &v.backend
	ok := false
	if b.writer != nil {
		if keep {
			finalize := cast(proc "system" (this: ^Com) -> win.HRESULT)b.writer.vtable[WRITER_FINALIZE_AT]
			hr := finalize(b.writer)
			ok = win.SUCCEEDED(hr)
			if !ok do log.warnf("video: Finalize failed: 0x%x", u32(hr))
		}
		com_release(b.writer)
		b.writer = nil
	}
	if b.started do _ = MFShutdown()
	b.started = false
	return ok
}
