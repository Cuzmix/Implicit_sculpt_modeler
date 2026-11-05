package main

import "core:fmt"
import "core:slice"

import "../ui"

// Reference pictures over the view (Ref.view), as ZBrush's Spotlight in Reference mode and
// Nomad's overlay: pinned over the main view at their opacity, drawn by the interface
// before every panel, so they lie under the bars and cards and the sculpt passes and the
// idle cache never see them. While the References card is open each takes the pointer:
// a drag moves it, its corner sizes it, a tap picks it on the board. With the card shut
// they take no touch at all, so sculpting goes on under them, and the one under the
// pointer fades to REF_VIEW_FADE of its opacity so the brush never works blind. The
// Eyedropper picks their colour as it picks the model's.

// What a place under the pointer fades to, and how fast, per second, it goes there and back.
REF_VIEW_FADE :: 0.15
REF_VIEW_FADE_RATE :: 12

// Where place `p` stands over the main view `main`, in points.
refs_view_rect :: proc(main: ui.Rect, p: Ref) -> ui.Rect {
	w := p.view_w * main.w
	h := w * p.size.y / max(p.size.x, 1e-6)
	return {main.x + p.view_at.x * main.w, main.y + p.view_at.y * main.h, w, h}
}

// Draws the places over the view and, while the References card is open, takes the
// pointer on them. Called before every panel is laid out, so each panel is above them.
refs_view :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	refs := &app.scene.refs
	main := k.grid.main
	if refs.view_off || main.w <= 0 || main.h <= 0 do return
	editing := card_shown(app, .References)
	step := clamp(ctx.input.dt, 0, 0.1) * REF_VIEW_FADE_RATE
	for &p in refs.refs {
		if !p.view || p.image == 0 do continue
		r := refs_view_rect(main, p)
		if editing {
			ui.begin_at(ctx, fmt.tprintf("ref view %d", p.id), {r.x, r.y}, {width = r.w, height = r.h})
			a := ui.area(ctx, "ref", {r.w, r.h})
			ui.end(ctx)
			refs_view_input(app, &p, a)
			r = refs_view_rect(main, p)
		}
		// Under the pointer while the card is shut, it gives way to the brush.
		fade := b.fades[p.id] or_else 1
		under := !editing && ctx.input.mouse_valid && ui.rect_contains(r, ctx.input.mouse)
		goal: f32 = REF_VIEW_FADE if under else 1
		fade += (goal - fade) * min(step, 1)
		b.fades[p.id] = fade
		alpha := u8(clamp(p.opacity * fade, 0, 1) * 255 + 0.5)
		refs_picture_draw(app, r, p, alpha)
		if editing && board_picked(b, p.id) {
			ui.stroke_rect(ctx, r, 0, t.accent, 2)
			if !p.locked do ui.fill_circle(ctx, {r.x + r.w, r.y + r.h}, board_corner(ctx) * 0.4, t.accent)
		}
	}
}

// The pointer on place `p` over the view, through its area `a`: a press picks it on the
// board (Shift adds it) or, while the Eyedropper waits, picks its colour; a drag moves it,
// from its corner sizes it, both one undo step when it lets go; a locked one only picks.
@(private = "file")
refs_view_input :: proc(app: ^App, p: ^Ref, a: ui.Area) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	main := k.grid.main
	if a.pressed {
		if app.ui.eyedrop_armed {
			app.ui.eyedrop_armed = false
			refs_pick_color(app, p^, refs_view_rect(main, p^), a.mouse)
			return
		}
		if ctx.input.shift {
			if !board_picked(b, p.id) do append(&b.selected, p.id)
		} else if !board_picked(b, p.id) {
			clear(&b.selected)
			append(&b.selected, p.id)
		}
		r := refs_view_rect(main, p^)
		d := a.mouse - [2]f32{r.x + r.w, r.y + r.h}
		corner := d.x * d.x + d.y * d.y <= board_corner(ctx) * board_corner(ctx)
		b.view_drag = .None if p.locked else (.Size if corner else .Move)
		b.view_id, b.view_last = p.id, a.mouse
		if b.view_drag != .None {
			delete(b.before)
			b.before = refs_clone(app.scene.refs.refs[:])
		}
	}
	if b.view_id != p.id do return
	if a.held && a.mouse != b.view_last {
		d := a.mouse - b.view_last
		#partial switch b.view_drag {
		case .Move:
			p.view_at += d / [2]f32{main.w, main.h}
		case .Size:
			// The corner follows the pointer across, keeping the picture's shape; never smaller than a finger.
			least := REF_MIN_SIDE * 2 / main.w
			p.view_w = clamp(p.view_w + d.x / main.w, least, 4)
		}
		// Never wholly off the view, so it can always be taken again.
		r := refs_view_rect(main, p^)
		p.view_at.x = clamp(p.view_at.x, (REF_MIN_SIDE - r.w) / main.w, 1 - REF_MIN_SIDE / main.w)
		p.view_at.y = clamp(p.view_at.y, (REF_MIN_SIDE - r.h) / main.h, 1 - REF_MIN_SIDE / main.h)
		b.view_last = a.mouse
	}
	if !a.held && b.view_drag != .None {
		if b.before != nil {
			if !slice.equal(b.before, app.scene.refs.refs[:]) {
				history_record_refs(app, b.before, "Move reference on view" if b.view_drag == .Move else "Size reference on view")
				b.moves += 1
			} else do delete(b.before)
			b.before = nil
		}
		b.view_drag = .None
		b.view_id = 0
	}
}

// Picks the colour of place `p`, drawn at `r`, under screen point `at` into the Colours
// card, as the Eyedropper does on the model.
refs_pick_color :: proc(app: ^App, p: Ref, r: ui.Rect, at: [2]f32) {
	rgb, ok := refs_color_at(app, p, r, at)
	if !ok {
		report(app, Section.Paint_Color, {.Warning}, "Eyedropper: the picture is still loading")
		return
	}
	colors_pick(app, rgb)
	report(app, Section.Paint_Color, {.Quiet}, "Picked %s", hex_text(rgb))
}

// The colour of place `p`, drawn at `r`, at screen point `at`, from its picture's small
// copy; false while there is none yet.
refs_color_at :: proc(app: ^App, p: Ref, r: ui.Rect, at: [2]f32) -> (rgb: [3]f32, ok: bool) {
	img := ref_image(&app.scene.refs, p.image)
	if img == nil || img.sample == nil do return
	f := [2]f32{clamp((at.x - r.x) / max(r.w, 1e-6), 0, 1), clamp((at.y - r.y) / max(r.h, 1e-6), 0, 1)}
	c := ref_corners(p)
	top := c[0] + (c[1] - c[0]) * f.x
	bottom := c[3] + (c[2] - c[3]) * f.x
	uv := top + (bottom - top) * f.y
	x := clamp(int(uv.x * f32(img.sample_size.x)), 0, img.sample_size.x - 1)
	y := clamp(int(uv.y * f32(img.sample_size.y)), 0, img.sample_size.y - 1)
	px := img.sample[(y * img.sample_size.x + x) * 4:]
	rgb = {f32(px[0]) / 255, f32(px[1]) / 255, f32(px[2]) / 255}
	if p.grey {
		y := 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
		rgb = y
	}
	return rgb, true
}

// The colour of the topmost place over the view at viewport point `at` (pixels from the
// viewport's top left), for the Eyedropper: what the person sees there is the picture.
refs_view_color :: proc(app: ^App, at: [2]f32) -> (rgb: [3]f32, over, ok: bool) {
	k := &app.kit
	refs := &app.scene.refs
	if refs.view_off || k.scale <= 0 do return
	point := (app.ui.viewport_origin + at) / k.scale
	for i := len(refs.refs) - 1; i >= 0; i -= 1 {
		p := refs.refs[i]
		if !p.view || p.image == 0 do continue
		r := refs_view_rect(k.grid.main, p)
		if !ui.rect_contains(r, point) do continue
		rgb, ok = refs_color_at(app, p, r, point)
		return rgb, true, ok
	}
	return
}

// The Show refs command: hides or shows every place over the view at once.
refs_view_toggle :: proc(app: ^App) {
	app.scene.refs.view_off = !app.scene.refs.view_off
	app.scene_edits += 1
}

// Lucide's gallery-thumbnails, for Show refs.
ICON_SHOW_REFS :: rune(0xe4d5)
