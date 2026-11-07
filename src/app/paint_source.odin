package main

import "../camera"
import "../sculpt"
import "../ui"

// The Paint brush's colour sources (sculpt/paint_source.odin), chosen in the Brush card's
// Colour section: its own colour; Smudge, which drags the paint under it along the
// stroke; Clone, which paints what lies a fixed way off on the surface, set by a first
// press; and Stencil, which paints the picture laid over the view (References, Over the
// view) through the screen onto the surface, as ZBrush's Spotlight and Substance's
// projection. Each paints colour alone, on the vertices or a texture layer, and Erase
// and Blur work as they always do.

@(rodata)
PAINT_SOURCE_NAMES := [sculpt.Paint_Source]string {
	.Color   = "Colour",
	.Smudge  = "Smudge",
	.Clone   = "Clone",
	.Stencil = "Stencil",
}

@(rodata)
PAINT_SOURCE_HINTS := [sculpt.Paint_Source]string {
	.Color   = "Lays the main colour.",
	.Smudge  = "Drags the colour under the press along the stroke.",
	.Clone   = "Copies the colour at the source, the same way off.",
	.Stencil = "Lays the picture over the view onto the surface, seen through it.",
}

// The source a stroke pressed with `input` paints from: the brush's, for the Paint brush
// held, not erasing; its own colour otherwise.
paint_source_of :: proc(app: ^App, input: Viewport_Input) -> sculpt.Paint_Source {
	if stroke_brush(app, input) != .Paint || !held_brush(input) || input.invert do return .Color
	return app.brush.paint_source
}

// Readies a stroke's source as it starts on `obj` at `hit` (world space) seen through
// transform `t`, or says why it cannot start (false): Clone's first press, or one after
// Set source, sets the source and paints nothing; Stencil needs a picture over the view.
// A press says so; a stroke that only reaches the object mid-drag starts quietly or not.
paint_source_start :: proc(app: ^App, obj: ^Object, t: Transform, hit: Vec3, input: Viewport_Input, press: bool) -> bool {
	b := &app.brush
	switch paint_source_of(app, input) {
	case .Color, .Smudge:
	case .Clone:
		local := to_local(t, hit)
		if b.clone_armed || !b.clone_set || (b.clone_object != 0 && b.clone_object != obj.id) {
			if !press do return false
			b.clone_from, b.clone_object, b.clone_set, b.clone_pending, b.clone_armed = local, obj.id, true, true, false
			report(app, Section.Paint_Color, {.Quiet}, "Clone source set: paint where it goes")
			return false
		}
		// The first stroke after the source was set fixes the way off; later strokes keep
		// it, so the copy stays aligned, as Photoshop's Aligned.
		if b.clone_pending do b.clone_offset, b.clone_pending = b.clone_from - local, false
	case .Stencil:
		if !paint_stencil_make(app, t, input.size, &app.stroke.stencil) {
			if press do report(app, Section.Paint_Color, {.Warning}, "Stencil paints the picture over the view: lay one over the view in References first")
			return false
		}
	}
	return true
}

// The Paint_Stencil for the topmost picture over the view, its colour ready, seen from
// the camera through transform `t` in a viewport of `size` pixels; false when none shows.
paint_stencil_make :: proc(app: ^App, t: Transform, size: [2]f32, out: ^sculpt.Paint_Stencil) -> bool {
	refs := &app.scene.refs
	k := &app.kit
	if refs.view_off || k.scale <= 0 || size.x <= 0 || size.y <= 0 do return false
	main := k.grid.main
	// Those in front first, as the interface draws them.
	for pass in 0 ..< 2 do for i := len(refs.refs) - 1; i >= 0; i -= 1 {
		p := refs.refs[i]
		if !p.view || p.image == 0 || p.view_behind != (pass == 1) do continue
		img := ref_image(refs, p.image)
		if img == nil || img.sample == nil do continue
		r := refs_view_rect(main, p)
		c := ref_corners(p)
		// Normalised device x and y to the picture's u and v: to the viewport's pixels,
		// to the window's points, unturned about the place's middle, across its rect and
		// through its crop, flip and turn. Each step is affine, so three points give it.
		uv_of :: proc(app: ^App, r: ui.Rect, angle: f32, c: [4][2]f32, size, ndc: [2]f32) -> [2]f32 {
			px := [2]f32{(ndc.x + 1) * 0.5 * size.x, (1 - ndc.y) * 0.5 * size.y}
			q := refs_unturn(r, angle, (app.ui.viewport_origin + px) / app.kit.scale)
			f := [2]f32{(q.x - r.x) / max(r.w, 1e-6), (q.y - r.y) / max(r.h, 1e-6)}
			return c[0] + (c[1] - c[0]) * f.x + (c[3] - c[0]) * f.y
		}
		o := uv_of(app, r, p.view_angle, c, size, {0, 0})
		dx := uv_of(app, r, p.view_angle, c, size, {1, 0}) - o
		dy := uv_of(app, r, p.view_angle, c, size, {0, 1}) - o
		out^ = {
			clip    = camera.orbit_proj(app.camera, size.x / size.y) * camera.orbit_view(app.camera) * transform_matrix(t),
			to_uv   = {{dx.x, dy.x, o.x}, {dx.y, dy.y, o.y}},
			pixels  = img.sample,
			size    = img.sample_size,
			grey    = p.grey,
			opacity = 1,
		}
		return true
	}
	return false
}

// The Colour section's choice of source, under the Paint brush's line: the four sources,
// what the picked one does, and Clone's source.
kit_paint_source :: proc(app: ^App) {
	ctx := &app.kit.ctx
	b := &app.brush
	names: [len(sculpt.Paint_Source)]string
	for name, s in PAINT_SOURCE_NAMES do names[s] = name
	if picked := ui.tabs(ctx, "paint source", names[:], int(b.paint_source)); picked >= 0 do b.paint_source = sculpt.Paint_Source(picked)
	ui.paragraph(ctx, PAINT_SOURCE_HINTS[b.paint_source])
	if b.paint_source == .Clone {
		obj := selected_object(app)
		set := b.clone_set && obj != nil && (b.clone_object == 0 || b.clone_object == obj.id)
		label := "Press the surface to set the source" if b.clone_armed else ("Set a new source" if set else "Set the source")
		if ui.button(ctx, label, .Bordered, width = ui.fill_width(ctx), enabled = !b.clone_armed) do b.clone_armed = true
	}
}

// The Clone offset in the object's space, for the stroke's dabs.
clone_offset :: proc(app: ^App) -> Vec3 {
	if !app.brush.clone_set || app.brush.clone_pending do return {}
	return app.brush.clone_offset
}
