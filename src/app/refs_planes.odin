package main

import "core:fmt"
import "core:math/linalg"
import "core:slice"
import "core:strings"

import "../camera"
import "../gizmo"
import "../render"
import "../ui"

// Reference pictures on planes in the scene (Ref.plane), as Blender's view-aligned
// reference images and ZBrush's image planes: a picked picture's place is put on a plane
// facing one axis view (the References card's In scene menu), through the middle of the
// scene's bounds, so a perspective view shows it at the model's size, and as tall as the
// selected object. The renderer draws it unlit (render/ref_planes.odin) only while the
// camera looks along its axis within 10°, unless it is shown from any side, so a front
// photo never cuts through a three-quarter view. Behind, it shows only where the model
// is not, whatever its depth; Through, it is drawn over the model, the silhouette check.
// While the References card is open a picked plane is dragged in the view to move it,
// from its corner to size it, one undo step each. The Scene card lists the planes after
// the lights, each with its eye and lock.

// Which axis view a place's plane faces: none, or the view whose camera looks at its
// picture square on.
Ref_Plane :: enum u8 {
	None,
	Front,
	Back,
	Right,
	Left,
	Top,
	Bottom,
}

@(rodata)
REF_PLANE_NAMES := [Ref_Plane]string{.None = "Not in scene", .Front = "Front", .Back = "Back", .Right = "Right", .Left = "Left", .Top = "Top", .Bottom = "Bottom"}

// A plane's middle and height stay within this of the origin: anything further is a
// damaged file.
REF_PLANE_FAR :: 1e6
// How tall a plane is put with no object to measure.
REF_PLANE_DEFAULT_H :: 2

// Lucide's wallpaper: a picture on a wall, for In scene and the planes' rows.
ICON_REF_PLANE :: rune(0xe450)

// The plane's axes in the world for axis view `plane`: the screen's right and up in that
// view, and the way it faces, toward that view's eye (camera.orbit_axis_view's turns).
refs_plane_axes :: proc(plane: Ref_Plane) -> (right, up, facing: Vec3) {
	switch plane {
	case .None, .Front: return {1, 0, 0}, {0, 1, 0}, {0, 0, 1}
	case .Back:         return {-1, 0, 0}, {0, 1, 0}, {0, 0, -1}
	case .Right:        return {0, 0, -1}, {0, 1, 0}, {1, 0, 0}
	case .Left:         return {0, 0, 1}, {0, 1, 0}, {-1, 0, 0}
	case .Top:          return {1, 0, 0}, {0, 0, -1}, {0, 1, 0}
	case .Bottom:       return {1, 0, 0}, {0, 0, 1}, {0, -1, 0}
	}
	return {1, 0, 0}, {0, 1, 0}, {0, 0, 1}
}

// Place `p`'s plane's width and height in the world: its height set, its width from the
// place's shape on the board (cropped and turned as the board shows it).
refs_plane_size :: proc(p: Ref) -> [2]f32 {
	return {p.plane_h * p.size.x / max(p.size.y, 1e-6), p.plane_h}
}

// The GPU copy plane `p` shows: the grey one once made, when grey; nil while it decodes.
@(private = "file")
refs_plane_texture :: proc(app: ^App, p: Ref) -> render.Texture {
	img := ref_image(&app.scene.refs, p.image)
	if img == nil do return 0
	return img.grey if p.grey && img.grey != 0 else img.texture
}

// Whether place `p` stands on a plane that may be drawn: in the scene, its eye open, a
// picture's, and every place in the view not hidden at once (Show refs).
refs_plane_on :: proc(app: ^App, p: Ref) -> bool {
	return p.plane != .None && !p.plane_off && p.image != 0 && !app.scene.refs.view_off
}

// The planes the renderer draws this frame, in the frame's memory. Each one the main
// view shows marks its picture seen, so the memory limit never makes it small.
refs_planes_frame :: proc(app: ^App) -> []render.Ref_Plane {
	refs := &app.scene.refs
	n := 0
	for p in refs.refs do if refs_plane_on(app, p) do n += 1
	if n == 0 do return nil
	out := make([dynamic]render.Ref_Plane, 0, n, context.temp_allocator)
	forward := render.view_forward(camera.orbit_view(app.camera))
	for p in refs.refs {
		if !refs_plane_on(app, p) do continue
		texture := refs_plane_texture(app, p)
		if texture == 0 do continue
		right, up, facing := refs_plane_axes(p.plane)
		size := refs_plane_size(p)
		plane := render.Ref_Plane {
			texture = texture,
			center  = p.plane_at,
			right   = right * (size.x * 0.5),
			up      = up * (size.y * 0.5),
			facing  = facing,
			uv      = ref_corners(p),
			opacity = p.opacity,
			through = b32(p.through),
			always  = b32(p.plane_any),
		}
		if render.ref_plane_shown(plane, forward) do ref_image(refs, p.image).seen = app.kit.ctx.time
		append(&out, plane)
	}
	return out[:]
}

// Puts the picked pictures on planes facing `plane` (or takes them off with .None), one
// undo step. A picture newly on a plane, or turned to another view, stands as tall as the
// selected object (the shown ones without a selection), through the middle of the
// scene's bounds, the pictures side by side across it.
refs_plane_put :: proc(app: ^App, plane: Ref_Plane) {
	refs := &app.scene.refs
	b := &app.kit.board
	before := refs_clone(refs.refs[:])
	right, up, _ := refs_plane_axes(plane)
	lo, hi, ok := objects_bounds(app, true)
	if !ok do lo, hi, ok = objects_bounds(app, false)
	if !ok do lo, hi = Vec3(-REF_PLANE_DEFAULT_H * 0.5), Vec3(REF_PLANE_DEFAULT_H * 0.5)
	scene_lo, scene_hi, scene_ok := objects_bounds(app, false)
	if !scene_ok do scene_lo, scene_hi = lo, hi
	extent := hi - lo
	tall := abs(linalg.dot(extent, up))
	if tall <= 1e-6 do tall = REF_PLANE_DEFAULT_H
	middle := (scene_lo + scene_hi) * 0.5
	// The pictures newly put go side by side, their row centred on the scene's middle.
	moving := make([dynamic]int, 0, len(refs.refs), context.temp_allocator)
	for &p, i in refs.refs {
		if !board_picked(b, p.id) || p.image == 0 do continue
		if plane == .None {
			p.plane = .None
			continue
		}
		if p.plane == plane do continue
		if p.plane == .None {
			// A picture first put in the scene shows whole, behind the model.
			p.through, p.plane_any, p.plane_off = false, false, false
		}
		p.plane = plane
		p.plane_h = tall
		append(&moving, i)
	}
	total: f32 = 0
	for i in moving do total += refs_plane_size(refs.refs[i]).x
	x := -total * 0.5
	for i in moving {
		p := &refs.refs[i]
		w := refs_plane_size(p^).x
		p.plane_at = middle + right * (x + w * 0.5)
		x += w
	}
	if slice.equal(before, refs.refs[:]) {
		delete(before)
		return
	}
	history_record_refs(app, before, "Reference in scene" if plane != .None else "Reference out of scene")
}

// The view the picked pictures' planes share, None when they share none or stand on none.
refs_picked_plane :: proc(app: ^App) -> (plane: Ref_Plane, any: bool) {
	b := &app.kit.board
	first := true
	for p in app.scene.refs.refs {
		if !board_picked(b, p.id) || p.image == 0 do continue
		if p.plane != .None do any = true
		if first do plane = p.plane
		else if p.plane != plane do plane = .None
		first = false
	}
	return
}

// Where plane `p` shows in the main view, in the interface's points: the box round its
// corners there; false when it does not show in that view or a corner is behind the eye.
refs_plane_rect :: proc(app: ^App, p: Ref) -> (r: ui.Rect, ok: bool) {
	k := &app.kit
	if k.scale <= 0 || app.target.width == 0 || app.target.height == 0 do return
	right, up, facing := refs_plane_axes(p.plane)
	forward := render.view_forward(camera.orbit_view(app.camera))
	if !p.plane_any && -linalg.dot(forward, facing) < render.REF_PLANE_SHOWN_COS do return
	size := [2]f32{f32(app.target.width), f32(app.target.height)}
	view_proj := view_proj_of(app, size)
	half := refs_plane_size(p) * 0.5
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for c in ([4][2]f32{{-1, 1}, {1, 1}, {1, -1}, {-1, -1}}) {
		px, front := gizmo.project(view_proj, p.plane_at + right * (c.x * half.x) + up * (c.y * half.y), size)
		if !front do return
		at := (px + app.ui.viewport_origin) / k.scale
		lo, hi = linalg.min(lo, at), linalg.max(hi, at)
	}
	return {lo.x, lo.y, hi.x - lo.x, hi.y - lo.y}, true
}

// While the References card is open, the picked planes the main view shows take the
// pointer: a drag moves one across its view, from its bottom right corner sizes it about
// its top left, one undo step when it lets go; each is outlined, with its corner. Called
// before the places over the view, which stand above the planes.
refs_planes_view :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	b := &k.board
	if !card_shown(app, .References) {
		b.plane_drag, b.plane_id = .None, 0
		return
	}
	for &p in app.scene.refs.refs {
		if !refs_plane_on(app, p) || !board_picked(b, p.id) do continue
		r, ok := refs_plane_rect(app, p)
		if !ok || r.w < 1 || r.h < 1 do continue
		if !p.locked {
			ui.begin_at(ctx, fmt.tprintf("ref plane %d", p.id), {r.x, r.y}, {width = r.w, height = r.h})
			a := ui.area(ctx, "plane", {r.w, r.h})
			ui.end(ctx)
			refs_plane_input(app, &p, a, r)
			r, ok = refs_plane_rect(app, p)
			if !ok do continue
		}
		ui.stroke_rect(ctx, r, 0, t.accent, 2)
		if !p.locked do ui.fill_circle(ctx, {r.x + r.w, r.y + r.h}, board_corner(ctx) * 0.4, t.accent)
	}
}

// The pointer on picked plane `p`, shown at `r`, through its area `a`.
@(private = "file")
refs_plane_input :: proc(app: ^App, p: ^Ref, a: ui.Area, r: ui.Rect) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	if a.pressed {
		d := a.mouse - [2]f32{r.x + r.w, r.y + r.h}
		corner := d.x * d.x + d.y * d.y <= board_corner(ctx) * board_corner(ctx)
		b.plane_drag = .Size if corner else .Move
		b.plane_id, b.plane_last = p.id, a.mouse
		delete(b.before)
		b.before = refs_clone(app.scene.refs.refs[:])
	}
	if b.plane_id != p.id do return
	if a.held && a.mouse != b.plane_last {
		d := a.mouse - b.plane_last
		right, up, _ := refs_plane_axes(p.plane)
		size := refs_plane_size(p^)
		// The world a point of the screen spans on the plane, from its width there.
		per := size.x / max(r.w, 1e-6)
		#partial switch b.plane_drag {
		case .Move:
			p.plane_at += right * (d.x * per) - up * (d.y * per)
		case .Size:
			// The corner follows the pointer across, keeping the picture's shape and its top
			// left where it was; never smaller than a finger.
			top_left := p.plane_at - right * (size.x * 0.5) + up * (size.y * 0.5)
			least := REF_MIN_SIDE * 2 * per
			w := max(size.x + d.x * per, least)
			p.plane_h = w * p.size.y / max(p.size.x, 1e-6)
			grown := refs_plane_size(p^)
			p.plane_at = top_left + right * (grown.x * 0.5) - up * (grown.y * 0.5)
		}
		b.plane_last = a.mouse
	}
	if !a.held && b.plane_drag != .None {
		if b.before != nil {
			if !slice.equal(b.before, app.scene.refs.refs[:]) {
				history_record_refs(app, b.before, "Move reference in scene" if b.plane_drag == .Move else "Size reference in scene")
				b.moves += 1
			} else do delete(b.before)
			b.before = nil
		}
		b.plane_drag = .None
		b.plane_id = 0
	}
}

// The In scene menu's items: each axis view, Not in scene, then Behind or Through and
// Only in its view for the picked planes, each one undo step.
refs_plane_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	b := &k.board
	if !b.plane_menu do return
	if !card_shown(app, .References) {
		b.plane_menu = false
		return
	}
	if !ui.popover_begin(ctx, "refs plane menu", &b.plane_menu, b.plane_menu_at, .Below, {direction = .Column, gap = 0, padding = ui.MENU_PAD, width = ui.MENU_W}) do return
	defer ui.popover_end(ctx)
	shared, on := refs_picked_plane(app)
	for plane in Ref_Plane.Front ..= Ref_Plane.Bottom {
		if ui.menu_item(ctx, fmt.tprintf("%s##refs plane", REF_PLANE_NAMES[plane]), checked = on && shared == plane) {
			refs_plane_put(app, plane)
			b.plane_menu = false
		}
	}
	if ui.menu_item(ctx, "Not in scene##refs plane", enabled = on) {
		refs_plane_put(app, .None)
		b.plane_menu = false
	}
	ui.divider(ctx, across = true)
	through := refs_picked_all_planes(app, proc(r: Ref) -> bool {return r.through})
	if ui.menu_item(ctx, "Behind the model##refs plane", checked = on && !through, enabled = on, hint = "The model hides it where the model is in front") {
		refs_edit(app, .Behind)
		b.plane_menu = false
	}
	if ui.menu_item(ctx, "Through the model##refs plane", checked = on && through, enabled = on, hint = "Drawn over the model, to check the silhouette") {
		refs_edit(app, .Through)
		b.plane_menu = false
	}
	only := !refs_picked_all_planes(app, proc(r: Ref) -> bool {return r.plane_any})
	if ui.menu_item(ctx, "Only in its view##refs plane", checked = on && only, enabled = on, hint = "Shown while the camera looks along its axis") {
		refs_edit(app, .Plane_Any)
		b.plane_menu = false
	}
}

// Whether every picked place on a plane is as `pick` says, false when none stands on one.
@(private = "file")
refs_picked_all_planes :: proc(app: ^App, pick: proc(r: Ref) -> bool) -> bool {
	b := &app.kit.board
	found := false
	for r in app.scene.refs.refs do if board_picked(b, r.id) && r.plane != .None && r.image != 0 {
		if !pick(r) do return false
		found = true
	}
	return found
}

// The Scene card's rows of the planes, after the lights: one row holding how many there
// are, folded at first, then a row per plane: its view and picture, its eye showing or
// hiding it and its lock, each an undo step; a tap opens the References card with its
// place picked.
scene_ref_rows :: proc(app: ^App, query: string) {
	k := &app.kit
	ctx := &k.ctx
	ol := &k.outliner
	refs := &app.scene.refs
	count := 0
	for p in refs.refs do if p.plane != .None && p.image != 0 do count += 1
	if count == 0 do return
	open := ol.refs_open || query != ""
	was := open
	shown := 0
	for p in refs.refs do if p.plane != .None && p.image != 0 && !p.plane_off do shown += 1
	head_parts := ui.Thumb_Row{glyph = ICON_REF_PLANE, count = -1, compact = true, open = &open, detail = fmt.tprintf("%d shown", shown)}
	if ui.thumb_row(ctx, fmt.tprintf("References · %d##scene refs", count), head_parts).clicked do open = !open
	if open != was && query == "" do ol.refs_open = open
	k.scene_rows += 1
	if !open do return
	for &p in refs.refs {
		if p.plane == .None || p.image == 0 do continue
		img := ref_image(refs, p.image)
		name := img.name if img != nil && img.name != "" else "Picture"
		if query != "" && !strings.contains(strings.to_lower(name, context.temp_allocator), query) && !strings.contains(strings.to_lower(REF_PLANE_NAMES[p.plane], context.temp_allocator), query) do continue
		detail := fmt.tprintf("%s · %s", REF_PLANE_NAMES[p.plane], "through the model" if p.through else "behind the model")
		parts := ui.Thumb_Row{glyph = ICON_REF_PLANE, count = -1, compact = true, detail = detail}
		toggles := [2]ui.Row_Toggle {
			{name = fmt.tprintf("%s %s", "Show" if p.plane_off else "Hide", name), glyph = ui.ICON_EYE_OFF if p.plane_off else ui.ICON_EYE, faint = p.plane_off},
			{name = fmt.tprintf("%s %s", "Unlock" if p.locked else "Lock", name), glyph = ICON_LOCK if p.locked else ICON_LOCK_OPEN, lit = p.locked, faint = !p.locked},
		}
		row := ui.thumb_row(ctx, fmt.tprintf("%s##scene ref %d", name, p.id), parts, dim = p.plane_off, all_toggles = toggles[:])
		if row.toggled >= 0 {
			before := refs_clone(refs.refs[:])
			what := ""
			if row.toggled == 0 {
				p.plane_off = !p.plane_off
				what = "Hide reference in scene" if p.plane_off else "Show reference in scene"
			} else {
				p.locked = !p.locked
				what = "Lock reference" if p.locked else "Unlock reference"
			}
			history_record_refs(app, before, what)
		} else if row.clicked || row.menu {
			b := &k.board
			clear(&b.selected)
			append(&b.selected, p.id)
			card_open(app, .References)
			board_show(app, p.id)
		}
		k.scene_rows += 1
	}
}

// How many pictures stand on planes in the scene, or only those drawn through the model,
// for the exit stats.
refs_plane_count :: proc(app: ^App, through: bool) -> (n: int) {
	for p in app.scene.refs.refs do if p.plane != .None && p.image != 0 && (!through || p.through) do n += 1
	return
}
