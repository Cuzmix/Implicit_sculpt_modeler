package render

import sdl "vendor:sdl3"

// GPU time by pass from timestamps the GPU writes as it runs (Gpu_Caps.timestamps), read a
// few frames late so no frame waits for the GPU. Each pass that should show in the Stats
// panel names its span in its debug_group; spans do not nest (one inside another is not
// timed), so their sum is the frame's GPU time.

Gpu_Span :: enum u8 {
	None, // in Gpu_Times: the frame's whole GPU time, the sum of the others
	Uploads,     // the brush's and polypaint's buffer uploads
	Viewport,    // the 3D view's drawing
	Live_AO,
	Studio,      // the studio render and its traced rays
	Render_Mode, // the path traced render mode
	Pictures,    // thumbnails and History step pictures
	Interface,   // the interface's upload and drawing into each window
}

GPU_SPAN_NAMES := [Gpu_Span]string {
	.None        = "frame",
	.Uploads     = "uploads",
	.Viewport    = "viewport",
	.Live_AO     = "live_ao",
	.Studio      = "studio",
	.Render_Mode = "render_mode",
	.Pictures    = "pictures",
	.Interface   = "interface",
}

// Milliseconds of GPU time by span, and which spans ran.
Gpu_Times :: struct {
	ms:  [Gpu_Span]f64,
	ran: bit_set[Gpu_Span],
}

// Timestamps a frame may write: a begin and an end for each span, run up to four times
// (view windows, several uploads).
TIMESTAMPS_MAX :: 64

// A timestamp as the backend hands it back: its tag (span * 2, + 1 at the span's end) and
// its time in nanoseconds from the GPU's own origin.
Gpu_Timestamp :: struct {
	tag: u8,
	ns:  f64,
}

// The span being recorded, so one inside another is left untimed.
@(private = "file")
span_open: Gpu_Span

@(private)
span_begin :: proc(cmd: ^sdl.GPUCommandBuffer, span: Gpu_Span) {
	if span == .None || span_open != .None do return
	span_open = span
	gpu_write_timestamp(cmd, u8(span) * 2)
}

@(private)
span_end :: proc(cmd: ^sdl.GPUCommandBuffer, span: Gpu_Span) {
	if span == .None || span_open != span do return
	span_open = .None
	gpu_write_timestamp(cmd, u8(span) * 2 + 1)
}

// Call once a frame before it records anything: starts the frame's timestamps and gives
// the GPU times of the frame a few back, `ok` false when there are none to give (no
// timestamps on this backend, or none came back).
timestamps_frame :: proc(r: ^Renderer) -> (times: Gpu_Times, ok: bool) {
	if !r.caps.timestamps do return
	stamps: [TIMESTAMPS_MAX]Gpu_Timestamp
	n := gpu_timestamps_frame(r.device, stamps[:])
	begun: [Gpu_Span]f64
	open: bit_set[Gpu_Span]
	for s in stamps[:n] {
		span := Gpu_Span(s.tag / 2)
		if span > max(Gpu_Span) do continue
		if s.tag % 2 == 0 {
			begun[span] = s.ns
			open += {span}
		} else if span in open && s.ns >= begun[span] {
			open -= {span}
			ms := (s.ns - begun[span]) / 1e6
			times.ms[span] += ms
			times.ms[.None] += ms
			times.ran += {span, .None}
		}
	}
	return times, .None in times.ran
}
