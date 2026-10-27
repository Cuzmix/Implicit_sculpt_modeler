package main

import "core:hash"
import "core:mem"
import "core:time"
import sdl "vendor:sdl3"

import "../camera"
import "../render"
import "../ui"

// The thumbnail window (View > Thumbnail): the scene small, as a sculptor steps back to
// judge the whole. Its idea comes from ZBrush's thumbnail view, a silhouette of the model
// beside the work, and from painters' and digital painting apps' habit of flipping the
// picture to see its proportions afresh: Silhouette draws every object black on a light
// ground, Shaded as the viewport shades it, and Flip mirrors it left to right. It follows
// the camera. Redrawn only when what it shows changed, once a stroke or a turn of the
// view is over, and at most every THUMBNAIL_EVERY seconds, so a big mesh is never drawn
// twice a frame while you work.

THUMBNAIL_EVERY :: 0.1
// The picture's width in points; its height follows the viewport's shape, within reason.
THUMBNAIL_W :: 232

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

// Draws the thumbnail on `cmd` when the window is laid out and what it shows changed,
// from the frame's `draws` seen through the camera's `view`.
thumbnail_frame :: proc(app: ^App, cmd: ^sdl.GPUCommandBuffer, view: render.Mat4, draws: []render.Draw_Item) {
	th := &app.thumbnail
	k := &app.kit
	size := k.thumbnail_px
	th.due = false
	if !k.thumbnail || k.home || size.x == 0 || size.y == 0 {
		th.shown = nil
		return
	}
	silhouette := k.thumbnail_shaded == false
	proj := camera.orbit_proj(app.camera, f32(size.x) / f32(size.y))
	Keyed :: struct {
		view, proj: render.Mat4,
		scene:      u64,
		size:       [2]u32,
		silhouette: bool,
	}
	keyed := Keyed{view, proj, scene_fingerprint(app), size, silhouette}
	key := max(hash.fnv64a(mem.ptr_to_bytes(&keyed)), 1)
	if th.shown != nil && key == th.key do return
	// Each picture draws every object whole, without the viewport's culling or simplified
	// copies, so it waits while a stroke or a turn of the view goes on.
	moving := app.stroke.active || time.tick_since(app.view_moved) < LOD_SETTLE
	if th.shown != nil && (moving || time.duration_seconds(time.tick_since(th.at)) < THUMBNAIL_EVERY) {
		th.due = true
		return
	}
	start := time.tick_now()
	if tex := render.thumbnail_view_draw(&app.renderer, &th.view, cmd, size, view, proj, draws, silhouette); tex != nil {
		th.shown, th.key, th.at = tex, key, time.tick_now()
		th.draws += 1
		th.ms = time.duration_milliseconds(time.tick_since(start))
	}
}

// The window: the picture, then Silhouette or Shaded, Flip and Close under it. Returns
// true when a press landed on it, to bring it to the front.
kit_thumbnail :: proc(app: ^App) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	shown := ui.presence(ctx, panel_id(Kit_Window.Thumbnail), k.thumbnail, t.panel_time)
	k.thumbnail_px = {}
	if shown <= 0 do return
	win := &k.windows[.Thumbnail]
	PADDING :: 10
	mark := ui.vertex_mark(ctx)
	p := panel_begin(app, Kit_Window.Thumbnail, "", .Start, .Start, {kit_left(app), points_bottom(app)}, {direction = .Column, gap = 8, padding = PADDING, width = THUMBNAIL_W + 2 * PADDING, radius = t.radius_large, background = .Panel, inert = !k.thumbnail}, card = true)
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
	pic := ui.place(ctx, {THUMBNAIL_W, THUMBNAIL_W / aspect})
	d := ctx.input.pixel_density
	k.thumbnail_px = {u32(pic.w * d + 0.5), u32(pic.h * d + 0.5)}
	ui.fill_rect(ctx, pic, t.radius_small, t.fill)
	if app.thumbnail.shown != nil {
		// Mirrored by reading the texture right to left.
		lo, hi := [2]f32{0, 0}, [2]f32{1, 1}
		if k.thumbnail_flip do lo.x, hi.x = 1, 0
		ui.image_part(ctx, pic, KIT_THUMBNAIL_IMAGE, lo, hi)
	}
	ui.begin(ctx, "thumbnail row", {direction = .Row, center = true, gap = 4})
	modes := [2]string{"Silhouette", "Shaded"}
	if picked := ui.tabs(ctx, "Thumbnail shows", modes[:], int(k.thumbnail_shaded), item_width = (THUMBNAIL_W - 2 * t.target - 8) / 2); picked >= 0 do k.thumbnail_shaded = picked == 1
	if ui.icon_button(ctx, "Flip left to right", ICON_FLIP, selected = k.thumbnail_flip) do k.thumbnail_flip = !k.thumbnail_flip
	// Floating, Close sits here; docked, the header has it.
	if !p.docked && ui.icon_button(ctx, "Close", ui.ICON_CLOSE) do k.thumbnail = false
	ui.end(ctx)
	panel_end(app, &p)
	ui.transform_since(ctx, mark, shown, 1, {}, {window_slide(ctx, win^, .Start) * (1 - shown) * 16, 0})
	return
}
