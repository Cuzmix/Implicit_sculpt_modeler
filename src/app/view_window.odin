package main

import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:math"
import "core:mem"
import sdl "vendor:sdl3"

import "../render"
import "../ui"

// View windows (Camera > New view window, a view pane's Open in a window): a second view in
// an OS window of its own, to move to another monitor, after Blender's extra main windows
// and the torn-off viewports of 3D-Coat and Marmoset. Each has its own camera and pass and
// a small head to change them, drawn by an interface context of its own at its monitor's
// scale; its picture follows the view panes' rules (drawn whole, only at rest, one picture
// a frame). It is a view, not a second workspace: brushes stay in the main window, and keys
// typed while it has the focus are the main window's. Desktop only: Android gives an app
// one window.
VIEW_WINDOWS_MAX :: 3
VIEW_WINDOWS_AVAILABLE :: ODIN_PLATFORM_SUBTARGET == .Default

// A new window's size, in points.
VIEW_WINDOW_SIZE :: [2]f32{960, 640}

// The most pixels a window's picture is drawn at, 1920x1080's worth: a bigger window shows
// it scaled up and smoothed, so a 4K monitor costs one 1080p drawing of the whole scene
// after a stroke rather than four.
VIEW_WINDOW_PICTURE_MAX :: 1920 * 1080

// Interface uploads that may fail in a row before a window closes.
VIEW_WINDOW_FAILS :: 3

// The picture's image id in a window's own interface.
VIEW_WINDOW_IMAGE :: 1

View_Window :: struct {
	window:   ^sdl.Window,
	id:       sdl.WindowID,
	number:   int, // 1 to VIEW_WINDOWS_MAX: its title and its camera's colour
	view:     Second_View,
	pic:      Picture,
	ctx:      ui.Context,
	pass:     render.Ui_Pass,
	device:   Device, // its own pointer; the keys are the main window's
	finger:   sdl.FingerID, // the finger that is its pointer, 0 for none
	scale:    f32, // window coordinates per point
	pixels:   [2]i32,
	laid_out: bool, // its interface began a frame that has not ended
	// What it last presented, to present again only when something changed: a 60 Hz
	// monitor's window presented every frame would hold back a faster main window.
	hash:     u64,
	version:  int, // the picture's version presented
	stale:    bool, // shown out of date (exposed, resized, a present skipped)
	failed:   int, // interface uploads that failed in a row; a few close it, as a failed submit does
	close:    bool, // asked to close, which happens at the start of the next frame
	presents: int,
}

View_Windows :: struct {
	open:    [VIEW_WINDOWS_MAX]^View_Window,
	pending: [dynamic; VIEW_WINDOWS_MAX]Second_View, // asked for, opened at the start of the next frame
	// For the exit stats, the closed windows' too.
	opens:    int,
	draws:    int,
	presents: int,
	refused:  int,
}

view_windows_count :: proc(vws: ^View_Windows) -> (n: int) {
	for w in vws.open do if w != nil && !w.close do n += 1
	return n + len(vws.pending)
}

// Asks for a window showing `sv`, opened at the start of the next frame; past the third
// it says why not.
view_window_request :: proc(app: ^App, sv: Second_View) {
	vws := &app.view_windows
	if !VIEW_WINDOWS_AVAILABLE do return
	if view_windows_count(vws) >= VIEW_WINDOWS_MAX {
		vws.refused += 1
		report(app, nil, {.Warning}, "%d view windows are open, the most there can be; close one to open another", VIEW_WINDOWS_MAX)
		return
	}
	v := sv
	v.max, v.dragging, v.turns, v.linked = false, false, 0, 0
	append(&vws.pending, v)
}

// What the New view window command shows: the first view pane's camera and pass in a grid
// with panes, else the main camera, shaded.
view_window_default :: proc(app: ^App) -> Second_View {
	g := &app.kit.grid
	if grid_panes(g) > 1 do return g.views[0]
	return {camera = .Follow, pass = .Shaded}
}

// The window an event belongs to by its window id, nil for the main window's (or one
// that has no window).
view_window_route :: proc(vws: ^View_Windows, id: sdl.WindowID) -> ^View_Window {
	if id == 0 do return nil
	for w in vws.open do if w != nil && w.id == id do return w
	return nil
}

// The pixels a window's picture is drawn at for a window of `pixels`: all of them up to
// VIEW_WINDOW_PICTURE_MAX, scaled down keeping the shape beyond.
view_window_picture_size :: proc(pixels: [2]i32) -> [2]u32 {
	w, h := f64(max(pixels.x, 1)), f64(max(pixels.y, 1))
	if w * h > VIEW_WINDOW_PICTURE_MAX {
		s := math.sqrt(VIEW_WINDOW_PICTURE_MAX / (w * h))
		w, h = math.floor(w * s), math.floor(h * s)
	}
	return {u32(max(w, 1)), u32(max(h, 1))}
}

// At the start of a frame, before anything is acquired: closes the windows asked to
// close and opens those asked for.
view_windows_settle :: proc(app: ^App) {
	vws := &app.view_windows
	for w, i in vws.open do if w != nil && w.close do view_window_close(app, i)
	for sv in vws.pending do view_window_open(app, sv)
	clear(&vws.pending)
}

@(private = "file")
view_window_open :: proc(app: ^App, sv: Second_View) {
	vws := &app.view_windows
	slot := -1
	for w, i in vws.open do if w == nil {
		slot = i
		break
	}
	if slot < 0 do return
	// Points to window coordinates at the main window's scale; the window keeps its size
	// in window coordinates when moved to another monitor, as the OS has it.
	scale := kit_content_scale(app.window) * app.kit.ui_scale
	size := VIEW_WINDOW_SIZE * scale
	title := fmt.ctprintf("Sculpt view %d", slot + 1)
	window := sdl.CreateWindow(title, i32(size.x), i32(size.y), platform_window_flags())
	if window == nil {
		report(app, nil, {.Warning}, "Could not open a view window: %s", sdl.GetError())
		return
	}
	if !render.window_claim(&app.renderer, window) {
		report(app, nil, {.Warning}, "Could not draw into a view window: %s", sdl.GetError())
		sdl.DestroyWindow(window)
		return
	}
	w := new(View_Window)
	w.window, w.id, w.number, w.view = window, sdl.GetWindowID(window), slot + 1, sv
	w.stale = true
	ui.init(&w.ctx)
	vws.open[slot] = w
	vws.opens += 1
	log.infof("view window %d open", w.number)
}

@(private = "file")
view_window_close :: proc(app: ^App, i: int) {
	vws := &app.view_windows
	w := vws.open[i]
	if w == nil do return
	// Its picture and interface buffers may still be read by work in flight; this wait
	// covers the destroys below and the window's release.
	render.wait_idle(&app.renderer)
	vws.draws += w.pic.draws
	vws.presents += w.presents
	if w.laid_out do _ = ui.frame_end(&w.ctx)
	picture_destroy(app, &w.pic)
	render.ui_pass_destroy(&app.renderer, &w.pass)
	ui.destroy(&w.ctx)
	render.window_release(&app.renderer, w.window)
	sdl.DestroyWindow(w.window)
	free(w)
	vws.open[i] = nil
}

// Closes every view window at the app's end, before the renderer goes.
view_windows_destroy :: proc(app: ^App) {
	for _, i in app.view_windows.open do view_window_close(app, i)
	clear(&app.view_windows.pending)
}

// Whether a window shows nothing now (minimised, hidden or covered): its picture waits and
// it presents nothing, so it neither keeps the app awake nor spends work on what no one
// sees; uncovered, it is drawn and presented again.
view_window_hidden :: proc(w: ^View_Window) -> bool {
	return sdl.GetWindowFlags(w.window) & {.MINIMIZED, .HIDDEN, .OCCLUDED} != {}
}

// Starts each window's pointer afresh for the frame's events, as the main one's.
view_windows_frame_begin :: proc(app: ^App) {
	for w in app.view_windows.open do if w != nil do device_frame_begin(&w.device)
}

// Takes an event that belongs to a view window (its pointer, wheel, fingers, pen and window
// events; the keys stay the main window's) and returns true, or false for the main
// window's. An event for a window just closed is dropped rather than read as the main one's.
view_windows_event :: proc(app: ^App, e: ^sdl.Event, main: sdl.WindowID) -> bool {
	#partial switch e.type {
	case .KEY_DOWN, .KEY_UP, .TEXT_INPUT, .TEXT_EDITING, .QUIT:
		return false
	}
	window := sdl.GetWindowFromEvent(e^)
	if window == nil {
		// One that names a window which is gone (a view window just closed) was its.
		id := event_window_id(e)
		return id != 0 && id != main
	}
	w := view_window_route(&app.view_windows, sdl.GetWindowID(window))
	if w == nil do return false
	view_window_event(w, e)
	return true
}

// The window an event names, 0 for none: the pointer's, the fingers', the pen's and the
// window events carry one.
@(private = "file")
event_window_id :: proc(e: ^sdl.Event) -> sdl.WindowID {
	#partial switch e.type {
	case .MOUSE_MOTION:                                return e.motion.windowID
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:        return e.button.windowID
	case .MOUSE_WHEEL:                                 return e.wheel.windowID
	case .FINGER_DOWN, .FINGER_MOTION, .FINGER_UP, .FINGER_CANCELED: return e.tfinger.windowID
	case .PEN_PROXIMITY_IN, .PEN_PROXIMITY_OUT:        return e.pproximity.windowID
	case .PEN_DOWN, .PEN_UP:                           return e.ptouch.windowID
	case .PEN_MOTION:                                  return e.pmotion.windowID
	case .PEN_BUTTON_DOWN, .PEN_BUTTON_UP:             return e.pbutton.windowID
	case .PEN_AXIS:                                    return e.paxis.windowID
	}
	if e.type >= .WINDOW_FIRST && e.type <= .WINDOW_LAST do return e.window.windowID
	return 0
}

@(private = "file")
view_window_event :: proc(w: ^View_Window, e: ^sdl.Event) {
	d := &w.device
	#partial switch e.type {
	case .WINDOW_CLOSE_REQUESTED:
		w.close = true
	case .WINDOW_EXPOSED, .WINDOW_RESIZED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED, .WINDOW_DISPLAY_CHANGED:
		w.stale = true
	case .FINGER_DOWN, .FINGER_MOTION, .FINGER_UP, .FINGER_CANCELED:
		// Its first finger is its pointer; the pen's stand-in finger is the pen's mouse.
		f := e.tfinger
		if f.touchID == sdl.PEN_TOUCHID do return
		ww, wh: i32
		_ = sdl.GetWindowSize(w.window, &ww, &wh)
		at := [2]f32{f.x * f32(ww), f.y * f32(wh)}
		if e.type == .FINGER_DOWN {
			if w.finger != 0 do return
			w.finger = f.fingerID
			d.pointer = .Finger
			device_move(d, at, jump = true)
			device_button(d, .Left, true, e.common.timestamp)
			return
		}
		if f.fingerID != w.finger do return
		device_move(d, at)
		if e.type == .FINGER_MOTION do return
		device_button(d, .Left, false, e.common.timestamp)
		if e.type == .FINGER_CANCELED do d.cancel = true
		w.finger = 0
	case:
		device_event(d, e)
	}
}

// Lays out each window's interface for the frame: its picture filling it, a drag on it
// turning the camera it sees through, and its head. Runs after the main interface and
// before the camera takes the frame's input, so a drag on a linked window turns the main
// view this frame.
view_windows_layout :: proc(app: ^App) {
	for w in app.view_windows.open {
		if w == nil || w.close do continue
		view_window_layout(app, w)
	}
}

@(private = "file")
view_window_layout :: proc(app: ^App, w: ^View_Window) {
	k := &app.kit
	ww, wh, pw, ph: i32
	_ = sdl.GetWindowSize(w.window, &ww, &wh)
	_ = sdl.GetWindowSizeInPixels(w.window, &pw, &ph)
	if pw != w.pixels.x || ph != w.pixels.y do w.stale = true
	w.pixels = {pw, ph}
	scale := kit_content_scale(w.window) * k.ui_scale
	w.scale = scale
	d := &w.device
	in_ := ui.Input {
		mouse         = d.mouse / scale,
		mouse_valid   = device_pointing(d),
		down          = d.down,
		pressed       = d.pressed,
		released      = d.released,
		wheel         = d.wheel,
		shift         = app.device.shift,
		ctrl          = app.device.ctrl,
		alt           = app.device.alt,
		window        = [2]f32{f32(ww), f32(wh)} / scale,
		pixel_density = f32(pw) / f32(max(ww, 1)) * scale,
		pointer       = d.pointer,
		cancel        = d.cancel,
		dt            = k.ctx.input.dt,
	}
	// A frame that ended early (the app stopping) left the last one open.
	if w.laid_out do _ = ui.frame_end(&w.ctx)
	w.ctx.theme = kit_theme(app)
	w.ctx.mirror = k.ctx.mirror
	ui.frame_begin(&w.ctx, in_)
	w.laid_out = true
	ctx := &w.ctx
	t := ctx.theme
	room := in_.window
	ui.begin_at(ctx, "view window", {0, 0}, {width = room.x, height = room.y})
	a := ui.area(ctx, "picture", room)
	ui.fill_rect(ctx, a.rect, 0, t.pane)
	if w.pic.shown != nil do ui.image(ctx, a.rect, VIEW_WINDOW_IMAGE)
	second_view_input(app, ctx, scale, &w.view, a)
	ui.end(ctx)
	ui.begin_at(ctx, "view window head", {6, 6}, {direction = .Row, center = true, gap = 4, padding = 4, radius = t.radius_large, background = .Panel})
	view_head_camera(app, ctx, &w.view, GRID_VIEWS + w.number)
	view_head_pass(ctx, &w.view)
	view_head_link(app, ctx, &w.view)
	if ui.icon_button(ctx, "Close this window", ui.ICON_CLOSE) do w.close = true
	ui.end(ctx)
}

// Draws each window's picture that is due, at most VIEW_WINDOW_PICTURE_MAX pixels, after the
// view panes', sharing their one picture a frame.
view_windows_pictures :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item) {
	for w in app.view_windows.open {
		if w == nil || w.close || w.pixels.x <= 0 || w.pixels.y <= 0 || view_window_hidden(w) do continue
		if app.kit.home {
			w.pic.shown, w.pic.due = nil, false
			continue
		}
		picture_frame(app, cmd, draws, &w.view, &w.pic, view_window_picture_size(w.pixels), 1)
	}
}

// Ends each window's interface and, when what it shows changed, presents it on a command
// buffer of its own: a window that cannot be drawn into closes, leaving the app running.
// The acquire never waits for a free image; a window without one (minimised, or its
// monitor still showing the last) tries again next frame.
view_windows_present :: proc(app: ^App) {
	for w in app.view_windows.open {
		if w == nil || !w.laid_out do continue
		w.laid_out = false
		dl := ui.frame_end(&w.ctx)
		h := xxhash.XXH3_64_default(mem.slice_to_bytes(dl.vertices[:]))
		h ~= xxhash.XXH3_64_with_seed(mem.slice_to_bytes(dl.indices[:]), 1)
		h ~= xxhash.XXH3_64_with_seed(mem.slice_to_bytes(dl.cmds[:]), 2)
		changed := h != w.hash || w.pic.version != w.version || w.stale
		w.hash = h
		if !changed || w.close do continue
		// Shown again, it presents what changed meanwhile.
		if view_window_hidden(w) {
			w.stale = true
			continue
		}
		if !view_window_present(app, w, dl) do w.close = true
	}
}

@(private = "file")
view_window_present :: proc(app: ^App, w: ^View_Window, dl: ^ui.Draw_List) -> bool {
	cmd := render.cmd_begin(&app.renderer)
	if cmd == nil {
		log.errorf("view window %d: no command buffer", w.number)
		return false
	}
	swapchain, size, acquired := render.swapchain_acquire(cmd, w.window, wait = false)
	if !acquired {
		log.errorf("view window %d: no swapchain", w.number)
		_ = render.cmd_cancel(cmd)
		return false
	}
	if swapchain == nil {
		w.stale = true
		return render.cmd_cancel(cmd)
	}
	pixels, aw, ah, dirty, atlas_changed := ui.atlas_take(&w.ctx)
	vertices := transmute([]render.Ui_Vertex)dl.vertices[:]
	uploaded := render.ui_pass_upload(&app.renderer, &w.pass, cmd, vertices, dl.indices[:], pixels, {u32(aw), u32(ah)}, dirty, atlas_changed)
	draws := view_window_draws(w, dl) if uploaded else nil
	render.ui_present(&app.renderer, &w.pass, cmd, w.window, swapchain, size, kit_frame_color(&app.kit), draws, uploaded)
	if !render.cmd_submit(cmd) {
		log.errorf("view window %d: submit failed", w.number)
		return false
	}
	w.version, w.stale = w.pic.version, !uploaded
	w.presents += 1
	w.failed = 0 if uploaded else w.failed + 1
	if w.failed >= VIEW_WINDOW_FAILS {
		log.errorf("view window %d: its interface could not be uploaded %d times", w.number, w.failed)
		return false
	}
	return true
}

// A window's draw commands as the renderer takes them: its one image is its picture,
// smoothed, since it may be drawn smaller than the window.
@(private = "file")
view_window_draws :: proc(w: ^View_Window, dl: ^ui.Draw_List) -> []render.Ui_Draw {
	draws := make([]render.Ui_Draw, len(dl.cmds), context.temp_allocator)
	for c, i in dl.cmds {
		draws[i] = {
			first_index = c.first_index,
			index_count = c.index_count,
			clip        = {i32(c.clip.x), i32(c.clip.y), i32(c.clip.w + 0.5), i32(c.clip.h + 0.5)},
		}
		if c.texture != .Image do continue
		draws[i].image, draws[i].smooth = picture_shown(&w.pic), true
		if c.image != VIEW_WINDOW_IMAGE || w.pic.shown == nil do draws[i].index_count = 0
	}
	return draws
}

// Whether a window waits to be drawn or presented, which keeps the frames coming.
view_windows_due :: proc(app: ^App) -> bool {
	for w in app.view_windows.open {
		if w == nil do continue
		if w.close || w.device.down != {} do return true
		if !view_window_hidden(w) && (w.pic.due || w.stale) do return true
	}
	return len(app.view_windows.pending) > 0
}

// Writes window `number`'s last frame as its interface drew it to a PNG, or a PPM when the
// path ends in .ppm (--dump-view-window).
view_window_save :: proc(app: ^App, number: int, path: string) -> bool {
	w: ^View_Window
	for o in app.view_windows.open do if o != nil && o.number == number do w = o
	if w == nil || w.presents == 0 {
		log.errorf("--dump-view-window: view window %d was never drawn", number)
		return false
	}
	dl := &w.ctx.draw
	vertices := transmute([]render.Ui_Vertex)dl.vertices[:]
	atlas, aw, ah := ui.atlas_pixels(&w.ctx)
	size := [2]u32{u32(w.pixels.x), u32(w.pixels.y)}
	pixels := render.ui_pass_capture(&app.renderer, &w.pass, size, kit_frame_color(&app.kit), view_window_draws(w, dl), vertices, dl.indices[:], atlas, {u32(aw), u32(ah)}, context.temp_allocator)
	if pixels == nil {
		log.errorf("--dump-view-window: could not read the window back: %s", sdl.GetError())
		return false
	}
	return image_save(app, path, pixels, int(size.x), int(size.y))
}

// The exit stats' view window line.
view_windows_stats :: proc(app: ^App) -> (open, draws, presents: int) {
	vws := &app.view_windows
	draws, presents = vws.draws, vws.presents
	for w in vws.open do if w != nil {
		open += 1
		draws += w.pic.draws
		presents += w.presents
	}
	return
}
