package main

import "core:hash"
import "core:math/linalg"
import "core:mem"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../render"
import "../ui"

// The second view (Camera > Second view), grown from the thumbnail window: the scene small,
// as a sculptor steps back to judge the whole. Its idea comes from ZBrush's thumbnail view,
// a silhouette of the model beside the work; from painters' and digital painting apps'
// habit of flipping the picture to see its proportions afresh; and from Blender's and
// ZBrush's front, side and top views, which check a likeness and its symmetry from the
// sides the working view is not on. It follows the camera, or looks along an axis
// (orthographic, at the camera's target and distance), or turns on its own once its
// picture is dragged; it shows a silhouette, the shading, or one of the cheap passes
// (passes.odin); Flip mirrors it, and Maximise makes a floating one large. Redrawn only
// when what it shows changed, once a stroke or a turn of the view is over, and at most
// every THUMBNAIL_EVERY seconds, so a big mesh is never drawn twice a frame while you work;
// a drag on the picture redraws it every frame, as nothing else moves then.

THUMBNAIL_EVERY :: 0.1
// The picture's width in points; its height follows the viewport's shape, within reason.
THUMBNAIL_W :: 232
// A maximised view's share of the viewport's width.
SECOND_MAX_SHARE :: 0.6

// Where the second view looks from.
Second_Camera :: enum u8 {
	Follow, // the camera, as the viewport sees
	Front,
	Back,
	Left,
	Right,
	Top,
	Bottom,
	Free, // its own, turned by dragging the picture
}

// What the second view shows: the cheap passes, which need no buffers of their own.
Second_Pass :: enum u8 {
	Silhouette,
	Shaded,
	Normals,
	Depth,
	Curvature,
}

// The second view's choices, which the settings keep (the Free camera's turn excepted),
// and its picture's drag.
Second_View :: struct {
	camera:   Second_Camera,
	pass:     Second_Pass,
	max:      bool, // maximised; never kept
	from:     [2]f32, // where the drag on the picture went down, and where it was last frame
	last:     [2]f32,
	dragging: bool, // the drag passed the slop and turns the Free camera
	sign:     f32, // camera.Orbit_Settings.axis_sign, latched as the drag began
	turns:    int, // frames a drag turned it, for the exit stats
}

@(rodata)
SECOND_CAMERA_NAMES := [Second_Camera]string {
	.Follow = "Follow",
	.Front  = "Front",
	.Back   = "Back",
	.Left   = "Left",
	.Right  = "Right",
	.Top    = "Top",
	.Bottom = "Bottom",
	.Free   = "Free",
}

@(rodata)
SECOND_PASS_NAMES := [Second_Pass]string {
	.Silhouette = "Silhouette",
	.Shaded     = "Shaded",
	.Normals    = "Normals",
	.Depth      = "Depth",
	.Curvature  = "Curvature",
}

// The viewport's pass a second view's pass draws with.
second_view_pass :: proc(p: Second_Pass) -> render.View_Pass {
	switch p {
	case .Silhouette: return .Silhouette
	case .Shaded:     return .Shaded
	case .Normals:    return .Normals
	case .Depth:      return .Depth
	case .Curvature:  return .Curvature
	}
	return .Shaded
}

// The axis a camera preset looks along, by name: the two enums list them differently.
second_axis :: proc(c: Second_Camera) -> (camera.Axis_View, bool) {
	#partial switch c {
	case .Front:  return .Front, true
	case .Back:   return .Back, true
	case .Left:   return .Left, true
	case .Right:  return .Right, true
	case .Top:    return .Top, true
	case .Bottom: return .Bottom, true
	}
	return .Front, false
}

// The camera the second view sees through: the viewport's, an axis view of it, or its own.
second_orbit :: proc(app: ^App) -> camera.Orbit {
	c := app.camera
	switch app.kit.second.camera {
	case .Follow:
	case .Front, .Back, .Left, .Right, .Top, .Bottom:
		axis, _ := second_axis(app.kit.second.camera)
		camera.orbit_axis_view(&c, axis)
		c.ortho = true
	case .Free:
		// Never turned yet (a restart keeps no turn): it starts as the camera is.
		if app.second_orbit.distance > 0 do c = app.second_orbit
	}
	return c
}

// Turns the second view to the Free camera, starting from what it shows.
second_free :: proc(app: ^App) {
	if app.kit.second.camera == .Free && app.second_orbit.distance > 0 do return
	app.second_orbit = second_orbit(app)
	app.kit.second.camera = .Free
}

Thumbnail_State :: struct {
	view:  render.Thumbnail_View,
	shown: ^sdl.GPUTexture, // what the window shows this frame, nil for nothing yet
	key:   u64, // what the texture holds; 0 for nothing
	at:    time.Tick, // when it was last drawn
	due:   bool, // what it shows changed and waits for its turn
	// For the exit stats: how often it was drawn and how long it last took on the CPU.
	draws: int,
	ms:    f64,
}

@(private = "file")
ICON_FLIP :: rune(0xe361) // flip-horizontal

thumbnail_destroy :: proc(app: ^App) {
	render.thumbnail_view_destroy(&app.renderer, &app.thumbnail.view)
	app.thumbnail = {}
}

// Draws the second view on `cmd` when the window is laid out and what it shows changed,
// from the frame's `draws` (shaded, as the viewport's own pass is cleared before this).
thumbnail_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, draws: []render.Draw_Item) {
	th := &app.thumbnail
	k := &app.kit
	size := k.thumbnail_px
	th.due = false
	if !k.thumbnail || k.home || size.x == 0 || size.y == 0 {
		th.shown = nil
		return
	}
	orbit := second_orbit(app)
	view, proj := camera.orbit_view(orbit), camera.orbit_proj(orbit, f32(size.x) / f32(size.y))
	pass := second_view_pass(k.second.pass)
	supersample := u32(1 if k.second.max else render.THUMBNAIL_SUPERSAMPLE)
	Keyed :: struct {
		view, proj:  render.Mat4,
		scene:       u64,
		size:        [2]u32,
		pass:        render.View_Pass,
		supersample: u32,
	}
	keyed := Keyed{view, proj, scene_fingerprint(app), size, pass, supersample}
	key := max(hash.fnv64a(mem.ptr_to_bytes(&keyed)), 1)
	if th.shown != nil && key == th.key do return
	// Each picture draws every object whole, without the viewport's culling or simplified
	// copies, so it waits while a stroke or a turn of the view goes on; a drag on the
	// picture itself is the one thing moving then, and draws it every frame.
	moving := app.stroke.active || time.tick_since(app.view_moved) < LOD_SETTLE
	if th.shown != nil && !k.second.dragging && (moving || time.duration_seconds(time.tick_since(th.at)) < THUMBNAIL_EVERY) {
		th.due = true
		return
	}
	start := time.tick_now()
	items := make([]render.Draw_Item, len(draws), context.temp_allocator)
	copy(items, draws)
	// Lights fixed to the scene are turned into the view the second view sees through.
	if k.second.camera != .Follow && pass == .Shaded {
		saved := app.camera
		app.camera = orbit
		lights := viewport_lights(app)
		app.camera = saved
		for &d in items do d.lights = lights
	}
	// A silhouette is the outline alone: no wireframe, paint, groups or maps over it.
	if pass == .Silhouette {
		for &d in items {
			d.wireframe, d.paint, d.groups = false, false, false
			d.matcap, d.textured, d.slots = nil, nil, nil
			d.checker = {}
		}
	}
	pass_items(items, view, pass)
	ground, own := pass_ground(pass)
	if !own do ground = {render.THUMBNAIL_DARK, render.THUMBNAIL_DARK}
	if tex := render.thumbnail_view_draw(&app.renderer, &th.view, cmd, size, view, proj, items, ground.top, supersample); tex != nil {
		th.shown, th.key, th.at = tex, key, time.tick_now()
		th.draws += 1
		th.ms = time.duration_milliseconds(time.tick_since(start))
	}
}

// The window: the picture, then the camera and the pass, Flip, Maximise and Close under
// it. A drag on the picture turns the Free camera and the wheel over it zooms that.
// Returns true when a press landed on it, to bring it to the front.
kit_thumbnail :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	sv := &k.second
	shown := ui.presence(ctx, panel_id(Kit_Window.Thumbnail), k.thumbnail, t.panel_time)
	k.thumbnail_px = {}
	if shown <= 0 do return
	win := &k.windows[.Thumbnail]
	PADDING :: 10
	// Maximised only while it floats: a docked column is as wide as its widest panel.
	_, _, docked := panel_docked(k, Kit_Window.Thumbnail)
	if docked do sv.max = false
	area := ui.safe_area(ctx)
	width: f32 = THUMBNAIL_W
	if sv.max do width = max(min(area.w * SECOND_MAX_SHARE, area.w - kit_left(app) - kit_right(app) - 2 * PADDING), THUMBNAIL_W)
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, Kit_Window.Thumbnail, "", .Start, .Start, {kit_left(app), points_bottom(app)}, {direction = .Column, gap = 8, padding = PADDING, width = width + 2 * PADDING, radius = t.radius_large, background = .Panel, inert = !k.thumbnail}, card = true)
	raised = p.raised
	if p.closed do k.thumbnail = false
	// Its grip held long is Panel options: it has no title to put the button beside.
	if p.dock do panel_menu_open(app, Kit_Window.Thumbnail)
	if !p.body {
		panel_end(app, &p)
		ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .Start) * (1 - shown) * 16, 0})
		return
	}
	aspect := f32(1.33)
	if app.target.height > 0 do aspect = clamp(f32(app.target.width) / f32(app.target.height), 0.6, 2)
	// As tall as the shape asks, within the room under the window's top and its rows.
	height := width / aspect
	if sv.max do height = min(height, max(window_room(app, win^, points_bottom(app)) - 3 * t.target - 5 * PADDING, THUMBNAIL_W / aspect))
	a := ui.area(ctx, "second view picture", {width, height})
	pic := a.rect
	d := ctx.input.pixel_density
	k.thumbnail_px = {u32(pic.w * d + 0.5), u32(pic.h * d + 0.5)}
	ui.fill_rect(ctx, pic, t.radius_small, t.fill)
	if app.thumbnail.shown != nil {
		// Mirrored by reading the texture right to left.
		lo, hi := [2]f32{0, 0}, [2]f32{1, 1}
		if k.thumbnail_flip do lo.x, hi.x = 1, 0
		ui.image_part(ctx, pic, KIT_THUMBNAIL_IMAGE, lo, hi)
	}
	second_view_input(app, a)
	// The camera and the pass side by side, then Flip, Maximise and Close.
	ui.begin(ctx, "second view choices", {direction = .Row, center = true, gap = 4})
	each := (width - 4) / 2
	cameras := make([]string, len(Second_Camera), context.temp_allocator)
	for name, c in SECOND_CAMERA_NAMES do cameras[c] = name
	if picked := ui.select(ctx, "Second view camera", cameras, int(sv.camera), each); picked >= 0 && Second_Camera(picked) != sv.camera {
		if Second_Camera(picked) == .Free do second_free(app)
		else do sv.camera = Second_Camera(picked)
	}
	passes := make([]string, len(Second_Pass), context.temp_allocator)
	for name, kind in SECOND_PASS_NAMES do passes[kind] = name
	if picked := ui.select(ctx, "Second view shows", passes, int(sv.pass), each); picked >= 0 do sv.pass = Second_Pass(picked)
	ui.end(ctx)
	ui.begin(ctx, "thumbnail row", {direction = .Row, center = true, gap = 4})
	if ui.icon_button(ctx, "Flip left to right", ICON_FLIP, selected = k.thumbnail_flip) do k.thumbnail_flip = !k.thumbnail_flip
	if !p.docked {
		if ui.icon_button(ctx, "Restore" if sv.max else "Maximise", ui.ICON_MINIMISE if sv.max else ui.ICON_RESTORE, selected = sv.max) do sv.max = !sv.max
		// Floating, Close sits here; docked, the header has it.
		if ui.icon_button(ctx, "Close", ui.ICON_CLOSE) do k.thumbnail = false
	}
	ui.end(ctx)
	panel_end(app, &p)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .Start) * (1 - shown) * 16, 0})
	return
}

// A drag on the picture turns the second view's own camera once it passes the slop, from
// whatever it showed, the way a drag turns the viewport's; the wheel over it zooms it.
second_view_input :: proc(app: ^App, a: ui.Area) {
	ctx := &app.kit.ctx
	sv := &app.kit.second
	if a.pressed do sv.from, sv.last, sv.dragging = a.mouse, a.mouse, false
	if a.held {
		if !sv.dragging && linalg.length(a.mouse - sv.from) > ctx.theme.slop {
			second_free(app)
			sv.dragging = true
			sv.sign = camera.orbit_axis_sign(app.second_orbit, app.nav.orbit_style)
		}
		if sv.dragging && a.mouse != sv.last {
			s := orbit_settings(app)
			s.axis_sign = sv.sign
			camera.orbit_rotate(&app.second_orbit, (a.mouse - sv.last) * app.kit.scale, s)
			sv.turns += 1
		}
		sv.last = a.mouse
	} else {
		sv.dragging = false
	}
	if a.hovered && ctx.input.wheel != 0 {
		second_free(app)
		camera.orbit_zoom(&app.second_orbit, ctx.input.wheel)
	}
}
