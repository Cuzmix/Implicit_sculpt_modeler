package main

import "core:hash"
import "core:math/linalg"
import "core:mem"
import "core:time"

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
	// Its shading mode and Solid's options, shown while the pass is Shaded (shading.odin).
	shading:  View_Shading,
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

// What a view can show, in its Shows list's order: Blender's shading modes (Rendered being
// the Render pass), then the passes that check the form and the studio render.
Second_Shows :: struct {
	pass: Second_Pass,
	mode: Shading_Mode,
}

@(rodata)
SECOND_SHOWS := [?]Second_Shows {
	{.Shaded, .Wireframe},
	{.Shaded, .Solid},
	{.Shaded, .Material_Preview},
	{.Render, .Rendered},
	{.Silhouette, {}},
	{.Normals, {}},
	{.Curvature, {}},
	{.Occlusion, {}},
	{.Depth, {}},
	{.Studio, {}},
}

// How many of SECOND_SHOWS are shading modes, the rest passes.
SECOND_SHOWS_MODES :: 4

// The name of what second view `sv` shows: its shading mode, or its pass.
second_shows_name :: proc(sv: ^Second_View) -> string {
	if m, ok := second_shading_mode(sv); ok do return SHADING_MODE_NAMES[m]
	return SECOND_PASS_NAMES[sv.pass]
}

// Which of SECOND_SHOWS second view `sv` shows.
second_shows_index :: proc(sv: ^Second_View) -> int {
	m, _ := second_shading_mode(sv)
	for e, i in SECOND_SHOWS do if e.pass == sv.pass && (sv.pass != .Shaded || e.mode == m) do return i
	return 0
}

// Makes second view `sv` show SECOND_SHOWS[i], keeping Solid's options.
second_shows_set :: proc(sv: ^Second_View, i: int) {
	if i < 0 || i >= len(SECOND_SHOWS) do return
	e := SECOND_SHOWS[i]
	sv.pass = e.pass
	if e.pass == .Shaded do sv.shading.mode = e.mode
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
	shown: render.Texture, // what the window shows this frame, nil for nothing yet
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
	// Scene > Finish on the studio render or Render shown (picture_finish); picture_shown
	// gives what the window shows.
	finished: render.Finish,
	// For the exit stats: how often it was drawn and how long it last took on the CPU.
	draws: int,
	ms:    f64,
}

picture_destroy :: proc(app: ^App, pic: ^Picture) {
	render.thumbnail_view_destroy(&app.renderer, &pic.view)
	render.live_ao_destroy(&app.renderer, &pic.ao)
	render.studio_destroy(&app.renderer, &pic.studio)
	render.path_render_destroy(&app.renderer, &pic.path)
	render.finish_destroy(&app.renderer, &pic.finished)
	pic^ = {}
}

// What a picture's window shows: its finished picture while Scene > Finish reaches it
// (picture_finish), else the picture as drawn; nil for nothing yet.
picture_shown :: proc(pic: ^Picture) -> render.Texture {
	if pic.shown == nil do return nil
	if t := render.finish_texture(&pic.finished); t != nil do return t
	return pic.shown
}

// Whether second view `sv`'s picture is finished: it shows the studio render or Render, the
// passes the main view is finished in while its Render switch is on, and a control of Scene >
// Finish is away from its none value. The other passes are each a look at one signal, which
// stays as it is.
picture_finish_wanted :: proc(app: ^App, sv: ^Second_View) -> bool {
	return (sv.pass == .Studio || sv.pass == .Render) && render.finish_active(finish_look(app.finish))
}

// Finishes a picture after it was drawn or gathered a sample, from render mode's linear light
// once it shows, as the main view's is (finish_view_frame); a still picture with the same look
// costs nothing. A picture copied from the main view while a pane was worked in waits, shown
// as copied, until it is drawn again.
@(private = "file")
picture_finish :: proc(app: ^App, cmd: render.Cmd, sv: ^Second_View, pic: ^Picture) {
	if !picture_finish_wanted(app, sv) || pic.shown == nil || pic.key == 0 {
		render.finish_reset(&pic.finished)
		return
	}
	source, linear := pic.shown, false
	if sv.pass == .Render && pic.shown == render.render_texture(&pic.path) {
		if t := render.render_linear_texture(&pic.path); t != nil do source, linear = t, true
	}
	look := finish_look(app.finish)
	look.seed = u32(pic.version)
	target := &pic.view.target
	_ = render.finish_frame(&app.renderer, &pic.finished, cmd, source, target.width, target.height, linear, look, u64(pic.version))
}

thumbnail_destroy :: proc(app: ^App) {
	picture_destroy(app, &app.thumbnail)
}

// Draws the second view on `cmd` when the window is laid out and what it shows changed,
// from the frame's `draws`, as their materials made them from `froms`.
thumbnail_frame :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item, froms: []Item_From) {
	k := &app.kit
	size := k.thumbnail_px
	if !k.thumbnail || k.home || size.x == 0 || size.y == 0 {
		app.thumbnail.shown, app.thumbnail.due = nil, false
		return
	}
	picture_frame(app, cmd, draws, froms, &k.second, &app.thumbnail, size, render.THUMBNAIL_SUPERSAMPLE)
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
		// Its shading, as one number.
		shading:     u64,
		// What it stands on: the background, the floor's settings and the environment's
		// look, as one number.
		ground:      u64,
	}
	pass := u32(second_view_pass(sv.pass)) | u32(sv.pass) << 8
	s := sv.shading
	shading := u64(s.mode) | u64(s.lighting) << 8 | u64(s.color) << 16 | u64(s.matcap) << 24
	Ground :: struct {
		background: render.Background,
		floor:      Floor_Settings,
		env:        [8]f32, // strength, blur, exposure, turn, whether it shows, whether it is fixed, its own turn and tilt
		kind:       u64,
	}
	e := &app.env
	// Declared, then filled, so its padding is zero and hashes the same every frame.
	g: Ground
	g.background, g.kind = background_frame(app.background), u64(e.kind)
	g.floor.on, g.floor.planes, g.floor.axes, g.floor.fit, g.floor.cell = app.floor.on, app.floor.planes, app.floor.axes, app.floor.fit, app.floor.cell
	g.env = {e.strength, e.blur, app.exposure, app.light_turn, f32(int(e.background)), f32(int(e.fixed)), e.turn, e.tilt}
	ground := hash.fnv64a(mem.ptr_to_bytes(&g))
	keyed := Keyed{camera.orbit_view(orbit), camera.orbit_proj(orbit, f32(size.x) / f32(size.y)), scene_fingerprint(app), size, pass, supersample, shading, ground}
	key = max(hash.fnv64a(mem.ptr_to_bytes(&keyed)), 1)
	return
}

// Draws second view `sv` into `pic`, `size` pixels as shown at `supersample` times that,
// when what it shows changed and its turn came: never while a stroke or a turn of the view
// goes on, at most every THUMBNAIL_EVERY seconds, and every frame while its own camera is
// dragged. A heavy pass runs on the picture's own target after it: live occlusion once,
// the studio a sample a frame afterwards, at rest, until it has the studio's count.
picture_frame :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item, froms: []Item_From, sv: ^Second_View, pic: ^Picture, size: [2]u32, supersample: u32) {
	pic.due = false
	defer picture_finish(app, cmd, sv, pic)
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
	// Shaded draws as the view's shading mode says, and Render's picture before its samples
	// as Material Preview.
	if sv.pass == .Shaded {
		shading_items(app, items, froms, sv.shading, pane = true)
		pass = shading_pass(app, sv.shading, pass, pane = true)
	} else if sv.pass == .Render {
		shading_items(app, items, froms, {mode = .Material_Preview}, pane = true)
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
	// Only a heavy pass reads the picture's depth after drawing it (the gather on later
	// frames included), so only it keeps the depth; the others draw into a transient one.
	heavy := second_pass_heavy(sv.pass) && render.live_ao_supported(&app.renderer, &pic.ao)
	// A pass without a ground of its own stands on the scene's background, its environment
	// and its floor, seen through the view's own camera, as the main view does, so a pane
	// split from it looks the same; a heavy pass, which reads the picture after, on the
	// background's colour alone.
	scene := !own && !heavy
	r := &app.renderer
	saved_background, saved_floor, saved_look := r.background, r.floor, r.environment_look
	if !own {
		ground = background_frame(app.background)
		if scene {
			r.background = ground
			f := app.floor
			r.floor = floor_grid_place(app.floor_state.bounds, camera.orbit_eye(orbit), f) if f.on && f.planes != {} else {}
			main := app.camera
			app.camera = orbit
			environment_view(app)
			app.camera = main
		}
	}
	defer if scene do r.background, r.floor, r.environment_look = saved_background, saved_floor, saved_look
	if tex := render.thumbnail_view_draw(r, &pic.view, cmd, size, view, proj, items, ground.top, supersample, keep_depth = heavy, scene = scene); tex != nil {
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

// How many samples a picture's studio render or path tracing has and how many it gathers
// to, for its chip; zero wanted when it shows neither or the device does not run it.
picture_samples :: proc(app: ^App, sv: ^Second_View, pic: ^Picture) -> (have, want: int) {
	if !render.live_ao_supported(&app.renderer, &pic.ao) do return
	#partial switch sv.pass {
	case .Studio:
		if pic.studio.failed || !pic.studio.shown_valid do return
		return pic.studio.samples, int(app.studio_samples)
	case .Render:
		pr := &pic.path
		if pr.failed || !pr.valid || pr.refused != "" do return
		return pr.samples, int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	}
	return
}

// One step of a picture's path tracing, with Scene > Render's settings and the lens seen
// from the picture's camera; `changed` starts it over.
@(private = "file")
picture_render :: proc(app: ^App, cmd: render.Cmd, pic: ^Picture, view, proj: render.Mat4, items: []render.Draw_Item, lights: render.Lights, orbit: camera.Orbit, changed: bool) {
	samples := int(clamp(app.render_samples, 1, render.RENDER_SAMPLES_MAX))
	bounces := int(clamp(app.render_bounces, 1, render.RENDER_BOUNCES_MAX))
	lens := render_lens(app)
	if lens.on && app.focus == nil do lens.focus = orbit.target
	linear := render.finish_active(finish_look(app.finish))
	_ = render.render_frame(&app.renderer, &pic.path, cmd, &pic.view.target, view, proj, items, changed, samples, bounces, lights, app.studio_softness, app.exposure, app.render_denoise, app.render_half, lens, &app.pool, linear = linear)
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
	} else if !a.clicked {
		// The release keeps it for its own frame, so a caller that answers a tap on the
		// picture (the mini view's swap) does not take the end of a drag for one.
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
