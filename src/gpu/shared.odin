package gpu

// What a device offers and reports back, shared by the backends and named again by render.

Async_Compute :: enum u8 {
	// No compute queue: Metal (for now), and a Vulkan device with no second queue.
	Off,
	// The own Vulkan backend on a device whose graphics family has one queue: compute
	// submissions keep their own timeline and waits but share the queue, so nothing
	// overlaps. Only --async-compute uses it, to check the bookkeeping.
	Same_Queue,
	// A second queue of the graphics family: compute runs beside the frame.
	Second_Queue,
}

Present_Timing :: enum u8 {
	None,
	// VK_KHR_present_wait (desktop Vulkan): the wait for a frame's present returns once it
	// is on the screen. The backend waits for the frame frames_in_flight back before each
	// acquire under vsync, so no more frames than that queue for the screen either.
	Present_Wait,
	// VK_GOOGLE_display_timing (Android's Vulkan): the screen reports each frame's time
	// afterwards. Nothing waits for it.
	Display_Timing,
	// Metal's presented handlers (the own Metal backend, iPad and Mac): each drawable
	// reports when it reached the screen, or that it never did (frames_dropped).
	Presented_Handler,
}

// A frame that reached the screen: the input it showed and when, both SDL nanoseconds
// (sdl.GetTicksNS). Present_Wait's times are when the waiting backend saw the frame shown,
// a frame late at most when it saw it without waiting.
Present_Time :: struct {
	input_ns: u64,
	shown_ns: u64,
}

FRAMES_IN_FLIGHT_DEFAULT :: 2
FRAMES_IN_FLIGHT_MAX :: 3

// Timestamps a frame may write: a begin and an end for each span, run up to four times
// (view windows, several uploads).
TIMESTAMPS_MAX :: 64

// A timestamp as the backend hands it back: its tag (span * 2, + 1 at the span's end) and
// its time in nanoseconds from the GPU's own origin.
Gpu_Timestamp :: struct {
	tag: u8,
	ns:  f64,
}


// The device's name and its driver's version, for people and logs, set by the backend that
// made the device and kept in buffers of their own, as the backends' words are temporary.
@(private = "file")
device_name_text: [256]u8
@(private = "file")
device_name_len: int
@(private = "file")
driver_text: [256]u8
@(private = "file")
driver_len: int

@(private)
device_info_set :: proc(name, driver: string) {
	device_name_len = copy(device_name_text[:], name)
	driver_len = copy(driver_text[:], driver)
}

// The device's name ("" where the backend does not say).
device_name :: proc() -> string {
	return string(device_name_text[:device_name_len])
}

// The driver's version ("" where the backend does not say).
driver_version :: proc() -> string {
	return string(driver_text[:driver_len])
}
