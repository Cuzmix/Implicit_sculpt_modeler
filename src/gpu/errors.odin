package gpu

import "core:fmt"

// What went wrong with the last call that failed on this thread, as a kind render can act on
// and the backend's words for the log. A failing call returns nil or false and records both
// here; the next failure overwrites them, and nothing clears them, so they are read only
// right after a call said it failed.
Error :: enum u8 {
	None,
	// The device or the backend has no such thing: a feature, a format, a limit too low.
	Unsupported,
	// Memory ran out on the device or for its objects.
	Out_Of_Memory,
	// The API refused a call it should have taken; its words say how.
	Refused,
	// The call broke the seam's rules: a pass left open, a window not claimed.
	Invalid,
}

ERROR_TEXT_MAX :: 256

// Per thread, as uploads and kernels are made on more than the main thread.
@(private = "file", thread_local)
error_kind: Error
@(private = "file", thread_local)
error_text: [ERROR_TEXT_MAX]u8
@(private = "file", thread_local)
error_len: int

// Records why a call failed; the backends call it where they return nil or false.
fail :: proc(kind: Error, format: string, args: ..any) {
	error_kind = kind
	error_len = len(fmt.bprintf(error_text[:], format, ..args))
}

// The backend's words for the last failure on this thread ("" before any).
last_error :: proc() -> string {
	return string(error_text[:error_len])
}

// The kind of the last failure on this thread (None before any).
last_error_kind :: proc() -> Error {
	return error_kind
}
