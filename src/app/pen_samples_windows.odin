#+build windows
package main

import "base:runtime"
import win32 "core:sys/windows"
import sdl "vendor:sdl3"

// The Windows bridge of pen_samples.odin. Windows gathers the pen's updates between two
// reads of the message queue into one WM_POINTERUPDATE whose history holds the rest, and
// SDL reads only the message's own (newest) sample. A message hook runs before SDL
// handles each message, so it reads the history (as Blender does) and pushes the older
// samples, oldest first, ahead of the events SDL makes of the message.

foreign import user32 "system:User32.lib"

@(default_calling_convention = "system")
foreign user32 {
	GetPointerPenInfoHistory :: proc(pointerId: win32.UINT32, entriesCount: ^win32.UINT32, penInfo: [^]win32.POINTER_PEN_INFO) -> win32.BOOL ---
	GetPointerDeviceRects :: proc(device: win32.HANDLE, pointerDeviceRect: ^win32.RECT, displayRect: ^win32.RECT) -> win32.BOOL ---
}

// The user event type the hook pushes, set once before the hook starts and only read after.
@(private = "file")
pen_hook_type: u32

// More history than this in one message is older than a few frames; the newest are kept.
@(private = "file")
PEN_HISTORY_MAX :: 64

pen_samples_platform_start :: proc(event_type: u32, window: ^sdl.Window) {
	pen_hook_type = event_type
	sdl.SetWindowsMessageHook(pen_hook, nil)
}

// Pushes a pen update's history, if it has one, and always lets SDL handle the message.
@(private = "file")
pen_hook :: proc "c" (userdata: rawptr, msg: ^win32.MSG) -> bool {
	if msg.message != win32.WM_POINTERUPDATE || pen_hook_type == 0 do return true
	context = runtime.default_context()
	id := win32.UINT32(msg.wParam & 0xffff) // GET_POINTERID_WPARAM
	now: win32.POINTER_PEN_INFO
	if !win32.GetPointerPenInfo(id, &now) || now.pointerInfo.pointerType != .PT_PEN do return true
	if now.pointerInfo.historyCount <= 1 || .in_contact not_in now.pointerInfo.pointerFlags do return true
	history: [PEN_HISTORY_MAX]win32.POINTER_PEN_INFO = ---
	count := min(now.pointerInfo.historyCount, PEN_HISTORY_MAX)
	if !GetPointerPenInfoHistory(id, &count, &history[0]) do return true
	// SDL places the pen through the tablet's own rectangle where Windows gives it (sub-pixel),
	// else by the message's pixel: the offsets are measured the same way.
	bounds, mapping: win32.RECT
	fine := bool(GetPointerDeviceRects(now.pointerInfo.sourceDevice, &bounds, &mapping)) && bounds.right > 0 && bounds.bottom > 0
	place :: proc "contextless" (p: win32.POINTER_INFO, fine: bool, bounds, mapping: win32.RECT) -> [2]f32 {
		if !fine do return {f32(p.ptPixelLocation.x), f32(p.ptPixelLocation.y)}
		w, h := f32(mapping.right - mapping.left), f32(mapping.bottom - mapping.top)
		return {f32(p.ptHimetricLocationRaw.x) / f32(bounds.right) * w, f32(p.ptHimetricLocationRaw.y) / f32(bounds.bottom) * h}
	}
	newest := place(history[0].pointerInfo, fine, bounds, mapping)
	// The history is newest first, and its first entry is the message's own sample.
	for i := int(count) - 1; i >= 1; i -= 1 {
		h := history[i]
		if .in_contact not_in h.pointerInfo.pointerFlags do continue
		s := Pen_Sample {
			offset   = place(h.pointerInfo, fine, bounds, mapping) - newest,
			pressure = f32(h.pressure) / 1024 if .pressure in h.penMask else -1,
			lean     = {f32(h.tiltX), f32(h.tiltY)} if .tiltX in h.penMask || .tiltY in h.penMask else {},
		}
		e := pen_sample_event(pen_hook_type, s)
		_ = sdl.PushEvent(&e)
	}
	return true
}
