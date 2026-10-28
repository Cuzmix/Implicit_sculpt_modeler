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

// Where the second view looks from. Linked and Mirrored are the main camera itself, so a
// drag on either turns the main view and every linked view with it; the others are the
// view's own, independent of it. Files name them, so a new one goes at the end.
Second_Camera :: enum u8 {
	Follow, // linked: the main camera, as the viewport sees
	Front,
	Back,
	Left,
	Right,
	Top,
	Bottom,
	Free, // its own, turned by dragging the picture
	Mirror, // the main camera reflected in the X symmetry plane: the other side
}

// What the second view shows: the cheap passes, which need no buffers of their own, then
// the heavy ones, which keep their own on the picture (Picture.ao, Picture.studio).
Second_Pass :: enum u8 {
	Silhouette,
	Shaded,
	Normals,
	Depth,
	Curvature,
	Occlusion, // live occlusion alone, as the main view's AO pass
	Studio, // the studio render, gathering samples at rest
	Render, // render mode's path tracing, gathering samples at rest
}

// Whether a pass runs more than the picture's one draw: live occlusion, the studio or the
// path tracer.
second_pass_heavy :: proc(p: Second_Pass) -> bool {
	return p == .Occlusion || p == .Studio || p == .Render
}

// The second view's choices, which the settings keep (the Free camera's turn excepted),
// and its picture's drag.
Second_View :: struct {
	// The Free camera; never kept, so a restart shows Follow's turn. Before `camera`,
	// whose name would hide the package's.
	orbit:    camera.Orbit,
	camera:   Second_Camera,
	pass:     Second_Pass,
	max:      bool, // maximised; never kept
	from:     [2]f32, // where the drag on the picture went down, and where it was last frame
	last:     [2]f32,
	dragging: bool, // the drag passed the slop and turns the Free camera
	sign:     f32, // camera.Orbit_Settings.axis_sign, latched as the drag began
	turns:    int, // frames a drag turned it, for the exit stats
	linked:   int, // frames a drag on it turned the main camera, for the exit stats
}

@(rodata)
SECOND_CAMERA_NAMES := [Second_Camera]string {
	.Follow = "Linked",
	.Front  = "Front",
	.Back   = "Back",
	.Left   = "Left",
	.Right  = "Right",
	.Top    = "Top",
	.Bottom = "Bottom",
	.Free   = "Free",
	.Mirror = "Mirrored",
}

@(rodata)
SECOND_PASS_NAMES := [Second_Pass]string {
	.Silhouette = "Silhouette",
	.Shaded     = "Shaded",
	.Normals    = "Normals",
	.Depth      = "Depth",
	.Curvature  = "Curvature",
	.Occlusion  = "AO only",
	.Studio     = "Studio",
	.Render     = "Render",
}

// The viewport's pass a second view's pass draws with.
second_view_pass :: proc(p: Second_Pass) -> render.View_Pass {
	switch p {
	case .Silhouette: return .Silhouette
	case .Shaded:     return .Shaded
	case .Normals:    return .Normals
	case .Depth:      return .Depth
	case .Curvature:  return .Curvature
	case .Occlusion:  return .AO
	case .Studio:     return .Shaded
	case .Render:     return .Shaded
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

// The camera a second view sees through: the viewport's, its reflection, an axis view of
// it, or its own.
second_orbit :: proc(app: ^App, sv: ^Second_View) -> camera.Orbit {
	c := main_camera(app)
	switch sv.camera {
	case .Follow:
	case .Mirror:
		c = camera.orbit_mirror_x(c)
	case .Front, .Back, .Left, .Right, .Top, .Bottom:
		axis, _ := second_axis(sv.camera)
		camera.orbit_axis_view(&c, axis)
		c.ortho = true
	case .Free:
		// Never turned yet (a restart keeps no turn): it starts as the camera is.
		if sv.orbit.distance > 0 do c = sv.orbit
	}
	// The main view's shift is for the room its panels leave; a second view has its own.
	c.shift = {}
	return c
}

// Whether a second view sees through the main camera, so that turning it turns the main view.
second_linked :: proc(sv: ^Second_View) -> bool {
	return sv.camera == .Follow || sv.camera == .Mirror
}

// The link button: links an independent view to the main camera, or lets a linked one go
// to the Free camera at the view it shows, so that nothing jumps either way.
second_link_toggle :: proc(app: ^App, sv: ^Second_View) {
	if second_linked(sv) do second_free(app, sv)
	else do sv.camera = .Follow
}

// The colour of the dot that says which camera a view sees through: the main camera's for
// a linked view (a ring for a mirrored one), else the view's own, `index` 1 to 3.
second_color :: proc(t: ui.Theme, sv: ^Second_View, index: int) -> (color: ui.Color, ring: bool) {
	if second_linked(sv) do return t.camera[0], sv.camera == .Mirror
	return t.camera[clamp(index, 1, len(t.camera) - 1)], false
}

// A camera's colour dot, in a row: a disc, or a ring for a mirrored view.
camera_dot :: proc(ctx: ^ui.Context, color: ui.Color, ring: bool) {
	r := ui.place(ctx, {14, 14})
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	if ring do ui.stroke_circle(ctx, c, 4.5, color, 2)
	else do ui.fill_circle(ctx, c, 5, color)
}

// Turns a second view to the Free camera, starting from what it shows.
second_free :: proc(app: ^App, sv: ^Second_View) {
	if sv.camera == .Free && sv.orbit.distance > 0 do return
	sv.orbit = second_orbit(app, sv)
	sv.camera = .Free
}

// A second view's picture on the device, and when it was drawn: the thumbnail window's and
// each view pane's (grid.odin).
Picture :: struct {
	view:  render.Thumbnail_View,
	shown: ^sdl.GPUTexture, // what the window shows this frame, nil for nothing yet
	key:   u64, // what the texture holds; 0 for nothing
	at:    time.Tick, // when it was last drawn
	// The camera it was drawn through, which what is drawn over it (the proportion
	// guides) follows, since the picture lags the camera while a stroke or turn goes on.
	orbit: camera.Orbit,
	due:   bool, // what it shows changed and waits for its turn, or the studio gathers
	version: int, // counts every change to what it shows, a gathered sample too (a view window presents on it)
	// The heavy passes' own buffers, made the first time one is shown.
	ao:     render.Live_AO,
	studio: render.Studio,
	path:   render.Path_Render, // a copy of the traced scene, given back when it shows another pass
	// For the exit stats: how often it was drawn and how long it last took on the CPU.
	draws: int,
	ms:    f64,
}

@(private = "file")
ICON_FLIP :: rune(0xe361) // flip-horizontal

picture_destroy :: proc(app: ^App, pic: ^Picture) {
	render.thumbnail_view_destroy(&app.renderer, &pic.view)
	render.live_ao_destroy(&app.renderer, &pic.ao)
	render.studio_destroy(&app.renderer, &pic.studio)
	render.path_render_destroy(&app.renderer, &pic.path)
	pic^ = {}
}

thumbnail_destroy :: proc(app: ^App) {
	picture_destroy(app, &app.thumbnail)
}

// Draws the second view on `cmd` when the window is laid out and what it shows changed,
// from the frame's `draws` (shaded, as the viewport's own pass is cleared before this).
thumbnail_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, draws: []render.Draw_Item) {
	k := &app.kit
	size := k.thumbnail_px
	if !k.thumbnail || k.home || size.x == 0 || size.y == 0 {
		app.thumbnail.shown, app.thumbnail.due = nil, false
		return
	}
	picture_frame(app, cmd, draws, &k.second, &app.thumbnail, size, 1 if k.second.max else render.THUMBNAIL_SUPERSAMPLE)
}

// What second view `sv`'s picture at `size` and `supersample` shows, as one number (never 0),
// and the camera it is seen through.
picture_key :: proc(app: ^App, sv: ^Second_View, size: [2]u32, supersample: u32) -> (key: u64, orbit: camera.Orbit) {
	orbit = second_orbit(app, sv)
	Keyed :: struct {
		view, proj:  render.Mat4,
		scene:       u64,
		size:        [2]u32,
		// The pass drawn and the second view's own (Studio draws as Shaded), as one number.
		pass:        u32,
		supersample: u32,
	}
	pass := u32(second_view_pass(sv.pass)) | u32(sv.pass) << 8
	keyed := Keyed{camera.orbit_view(orbit), camera.orbit_proj(orbit, f32(size.x) / f32(size.y)), scene_fingerprint(app), size, pass, supersample}
	key = max(hash.fnv64a(mem.ptr_to_bytes(&keyed)), 1)
	return
}

// Draws second view `sv` into `pic`, `size` pixels as shown at `supersample` times that,
// when what it shows changed and its turn came: never while a stroke or a turn of the view
// goes on, at most every THUMBNAIL_EVERY seconds, and every frame while its own camera is
// dragged. A heavy pass runs on the picture's own target after it: live occlusion once,
// the studio a sample a frame afterwards, at rest, until it has the studio's count.
picture_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, draws: []render.Draw_Item, sv: ^Second_View, pic: ^Picture, size: [2]u32, supersample: u32) {
	pic.due = false
	// The path tracer's copy of the scene is costly to keep: a picture showing another pass
	// gives it back.
	if sv.pass != .Render && pic.path.pipeline != nil do render.path_render_destroy(&app.renderer, &pic.path)
	key, orbit := picture_key(app, sv, size, supersample)
	view, proj := camera.orbit_view(orbit), camera.orbit_proj(orbit, f32(size.x) / f32(size.y))
	pass := second_view_pass(sv.pass)
	fresh := pic.shown == nil || key != pic.key
	gathering := !fresh && picture_gathers(app, sv, pic)
	if !fresh && !gathering do return
	// Each picture draws every object whole, without the viewport's culling or simplified
	// copies, so it waits while a stroke or a turn of the view goes on; a drag on the
	// picture itself is the one thing moving then, and draws it every frame.
	// While a view pane is worked in, that pane is the one view drawn live (grid_work).
	moving := app.stroke.active || time.tick_since(app.view_moved) < LOD_SETTLE || app.kit.grid.work != 0
	// One picture a frame at most, so the panes due after a stroke share out their cost; a
	// studio sample waits for a frame with none, but never holds one back.
	soon := fresh && time.duration_seconds(time.tick_since(pic.at)) < THUMBNAIL_EVERY
	if pic.shown != nil && !sv.dragging && (moving || app.pictures_drawn > 0 || soon) {
		pic.due = true
		return
	}
	start := time.tick_now()
	items := make([]render.Draw_Item, len(draws), context.temp_allocator)
	copy(items, draws)
	// Lights fixed to the scene are turned into the view the second view sees through.
	lights := items[0].lights if len(items) > 0 else {}
	if sv.camera != .Follow && pass == .Shaded {
		saved := app.camera
		app.camera = orbit
		lights = viewport_lights(app)
		app.camera = saved
		for &d in items do d.lights = lights
	}
	if gathering {
		if sv.pass == .Render {
			picture_render(app, cmd, pic, view, proj, items, lights, orbit, false)
			if tex := render.render_texture(&pic.path); tex != nil && pic.path.samples >= RENDER_SHOW_MIN do pic.shown = tex
		} else {
			_ = render.studio_frame(&app.renderer, &pic.studio, cmd, &pic.view.target, view, proj, items, false, int(app.studio_samples), app.studio_ao, app.studio_shadow, lights, &app.pool, app.studio_softness)
			if tex := render.studio_texture(&pic.studio); tex != nil do pic.shown = tex
		}
		pic.version += 1
		pic.due = picture_gathers(app, sv, pic)
		return
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
	// A pass without a ground of its own sits on the interface's pane colour, so a view
	// pane's empty corners are the same colour as the pane before its first picture.
	if !own {
		pane := color_f32(LOOK_THEMES[app.kit.look].pane)
		ground = {pane, pane}
	}
	heavy := second_pass_heavy(sv.pass) && render.live_ao_supported(&app.renderer, &pic.ao)
	if tex := render.thumbnail_view_draw(&app.renderer, &pic.view, cmd, size, view, proj, items, ground.top, supersample, keep_depth = heavy); tex != nil {
		shown := tex
		if heavy && sv.pass == .Occlusion {
			reach := clamp(app.live_ao_reach, LIVE_AO_REACH_MIN, LIVE_AO_REACH_MAX)
			if render.live_ao_frame(&app.renderer, &pic.ao, cmd, &pic.view.target, view, proj, items, {}, reach, 1, LIVE_AO_SCALE) {
				if t := render.live_ao_texture(&pic.ao); t != nil do shown = t
			}
		} else if heavy && sv.pass == .Studio {
			if render.studio_frame(&app.renderer, &pic.studio, cmd, &pic.view.target, view, proj, items, true, int(app.studio_samples), app.studio_ao, app.studio_shadow, lights, &app.pool, app.studio_softness) {
				if t := render.studio_texture(&pic.studio); t != nil do shown = t
			}
		} else if heavy && sv.pass == .Render {
			// It starts over here and traces from the next frame at rest, the shaded picture
			// showing until it has samples enough.
			picture_render(app, cmd, pic, view, proj, items, lights, orbit, true)
		}
		pic.shown, pic.key, pic.at, pic.orbit = shown, key, time.tick_now(), orbit
		pic.draws += 1
		pic.version += 1
		app.pictures_drawn += 1
		pic.ms = time.duration_milliseconds(time.tick_since(start))
		pic.due = picture_gathers(app, sv, pic)
	}
}

// Whether a picture's studio render or path tracing still gathers samples: it shows Studio
// or Render, the device runs it, and it has fewer than Scene > Studio render's or Render's
// count.
picture_gathers :: proc(app: ^App, sv: ^Second_View, pic: ^Picture) -> bool {
	if !render.live_ao_supported(&app.renderer, &pic.ao) do return false
	#partial switch sv.pass {
	case .Studio:
		return !pic.studio.failed && pic.studio.shown_valid && pic.studio.samples < int(app.studio_samples)
	case .Render:
		pr := &pic.path
		return !pr.failed && pr.valid && pr.refused == "" && pr.samples < int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	}
	return false
}

// One step of a picture's path tracing, with Scene > Render's settings and the lens seen
// from the picture's camera; `changed` starts it over.
@(private = "file")
picture_render :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, pic: ^Picture, view, proj: render.Mat4, items: []render.Draw_Item, lights: render.Lights, orbit: camera.Orbit, changed: bool) {
	samples := int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	lens := render_lens(app)
	if lens.on && app.focus == nil do lens.focus = orbit.target
	_ = render.render_frame(&app.renderer, &pic.path, cmd, &pic.view.target, view, proj, items, changed, samples, bounces, lights, app.studio_softness, app.exposure, app.render_denoise, app.render_half, lens, &app.pool)
}

// The window: the picture, then the camera and the pass, Flip, Maximise and Close under
// it. A drag on the picture turns the Free camera and the wheel over it zooms that.
// Returns true when a press landed on it, to bring it to the front.
kit_thumbnail :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	if k.chrome == .Lens do return kit_mini_view(app)
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
	// A flipped picture is mirrored left to right, which leaves level lines where they are.
	if app.thumbnail.shown != nil do kit_guides(app, pic, app.thumbnail.orbit, "thumbnail")
	second_view_input(app, ctx, k.scale, sv, a)
	// The camera and the pass side by side, then Flip, Maximise and Close.
	ui.begin(ctx, "second view choices", {direction = .Row, center = true, gap = 4})
	// The dot takes its place from the camera's select.
	dot, ring := second_color(t, sv, 1)
	camera_dot(ctx, dot, ring)
	each := (width - 4 - 18) / 2
	cameras := make([]string, len(Second_Camera), context.temp_allocator)
	for name, c in SECOND_CAMERA_NAMES do cameras[c] = name
	if picked := ui.select(ctx, "Second view camera", cameras, int(sv.camera), each); picked >= 0 && Second_Camera(picked) != sv.camera {
		if Second_Camera(picked) == .Free do second_free(app, sv)
		else do sv.camera = Second_Camera(picked)
	}
	passes := make([]string, len(Second_Pass), context.temp_allocator)
	for name, kind in SECOND_PASS_NAMES do passes[kind] = name
	if picked := ui.select(ctx, "Second view shows", passes, int(sv.pass), each); picked >= 0 do sv.pass = Second_Pass(picked)
	ui.end(ctx)
	ui.begin(ctx, "thumbnail row", {direction = .Row, center = true, gap = 4})
	if ui.icon_button(ctx, "Flip left to right", ICON_FLIP, selected = k.thumbnail_flip) do k.thumbnail_flip = !k.thumbnail_flip
	linked := second_linked(sv)
	if ui.icon_button(ctx, "Unlink from the main camera" if linked else "Link to the main camera", ICON_LINK, selected = linked) do second_link_toggle(app, sv)
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

// A drag on the picture turns the camera the view sees through once it passes the slop,
// the way a drag turns the viewport's; the wheel over it zooms it. A linked view turns the
// main camera, so the main view and the other linked views turn with it (a mirrored one
// with the sideways turn reversed, so its picture follows the finger); an independent
// view turns its own, an axis view becoming Free from what it showed.
// `ctx` is the interface it runs in and `scale` that interface's window coordinates per point
// (a view window's differ from the main window's).
second_view_input :: proc(app: ^App, ctx: ^ui.Context, scale: f32, sv: ^Second_View, a: ui.Area) {
	if a.pressed do sv.from, sv.last, sv.dragging = a.mouse, a.mouse, false
	if a.held {
		if !sv.dragging && linalg.length(a.mouse - sv.from) > ctx.theme.slop {
			sv.dragging = true
			if second_linked(sv) {
				orbit_latch(app)
			} else {
				second_free(app, sv)
				sv.sign = camera.orbit_axis_sign(sv.orbit, app.nav.orbit_style)
			}
		}
		if sv.dragging && a.mouse != sv.last {
			delta := (a.mouse - sv.last) * scale
			if second_linked(sv) {
				if sv.camera == .Mirror do delta.x = -delta.x
				camera.orbit_rotate(&app.camera, delta, orbit_settings(app))
				sv.linked += 1
			} else {
				s := orbit_settings(app)
				s.axis_sign = sv.sign
				camera.orbit_rotate(&sv.orbit, delta, s)
				sv.turns += 1
			}
		}
		sv.last = a.mouse
	} else {
		sv.dragging = false
	}
	if a.hovered && ctx.input.wheel != 0 {
		if second_linked(sv) {
			camera.orbit_zoom(&app.camera, ctx.input.wheel)
		} else {
			second_free(app, sv)
			camera.orbit_zoom(&sv.orbit, ctx.input.wheel)
		}
	}
}
