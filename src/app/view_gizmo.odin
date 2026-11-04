package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:time"

import "../camera"
import "../geom"
import "../ui"

// The view gizmo under the top bar at the pen side, in one of three styles: the world's
// axes as balls (Blender's), a cube that names its faces (Nomad's and Fusion's), or a
// model that turns with the view (ZBrush's head, or a light copy of one of the person's
// own objects). Each is dragged to turn the view, tapped to look from where the tap
// lands and spun by the pen's roll; holding it, or a right click, picks the style
// (Bar_Pop_Kind.View_Gizmo), as Settings > Camera > VIEW GIZMO does. Axes and Cube are
// drawn by the interface itself, with no pass on the GPU; Model is the head's picture
// (nav_head.odin).

// What the view gizmo shows.
View_Gizmo :: enum u8 {
	Axes,
	Cube,
	Model,
}

@(rodata)
VIEW_GIZMO_NAMES := [View_Gizmo]string {
	.Axes  = "Axes",
	.Cube  = "Cube",
	.Model = "Model",
}

// Which model the Model style turns: the built-in head, or the person's own.
Gizmo_Model :: enum u8 {
	Head,
	Own,
}

// The Axes and Cube styles' square, in points: a little wider than the head, so the six
// balls stay a finger apart.
VIEW_GIZMO_SIZE :: 72

// The balls' distance from the middle and their radius, as shares of the square: the
// letters readable, the minus balls clear of the plus ones at any turn.
GIZMO_BALL_AT :: 0.34
GIZMO_BALL_R :: 0.105

// A ball takes a tap this far out, times its radius, so a finger's tap on its rim counts.
GIZMO_BALL_REACH :: 1.6

// The cube's half side, as a share of the square: its corner to corner at most 0.47 of it.
GIZMO_CUBE_HALF :: 0.27

// How far across a cube face, from its middle (0) to its edge (1), the face's own target
// ends and its edges' and corners' begin: the outer fifth each side, as Fusion's
// ViewCube gives its edges.
GIZMO_CUBE_ZONE :: 0.6

// The most triangles a person's own model keeps: enough for a creature's silhouette in a
// gizmo 64 points across, little enough to draw in no time (about half a megabyte).
VIEW_MODEL_TRIANGLES :: 20000

// One ball of the Axes style: where it is drawn, how near the eye, and the direction it
// looks from.
Gizmo_Ball :: struct {
	at:    [2]f32,
	depth: f32, // toward the eye, -1 to 1
	axis:  int,
	minus: bool,
}

// The six balls in square `r`, turned as `basis` (the camera's right, up and back),
// back to front: the order they are drawn in.
gizmo_balls :: proc(r: ui.Rect, right, up, back: geom.Vec3) -> (balls: [6]Gizmo_Ball) {
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	reach := min(r.w, r.h) * GIZMO_BALL_AT
	for i in 0 ..< 6 {
		axis, s := i / 2, f32(-1 if i % 2 == 1 else 1)
		balls[i] = {at = c + reach * s * [2]f32{right[axis], -up[axis]}, depth = s * back[axis], axis = axis, minus = s < 0}
	}
	// A stable sort, so two balls at one depth keep the axes' order.
	slice.stable_sort_by(balls[:], proc(a, b: Gizmo_Ball) -> bool {return a.depth < b.depth})
	return
}

// The direction a tap at `at` on square `r` looks from in the Axes style: the front-most
// ball within reach, or the opposite side for the ball already facing the eye, as Blender
// flips the view. False off every ball.
gizmo_axes_pick :: proc(r: ui.Rect, right, up, back: geom.Vec3, at: [2]f32, reach: f32 = GIZMO_BALL_REACH) -> (from: geom.Vec3, ok: bool) {
	balls := gizmo_balls(r, right, up, back)
	radius := min(r.w, r.h) * GIZMO_BALL_R * reach
	#reverse for b in balls {
		if linalg.length(b.at - at) > radius do continue
		from[b.axis] = -1 if b.minus else 1
		if b.depth > 0.999 do from = -from
		return from, true
	}
	return
}

// One face of the cube: its outward normal and its own right and up as seen from outside,
// with the name it shows.
Cube_Face :: struct {
	normal, u, v: geom.Vec3,
	name:         string,
}

@(rodata)
CUBE_FACES := [6]Cube_Face {
	{{0, 0, 1}, {1, 0, 0}, {0, 1, 0}, "Front"},
	{{0, 0, -1}, {-1, 0, 0}, {0, 1, 0}, "Back"},
	{{1, 0, 0}, {0, 0, -1}, {0, 1, 0}, "Right"},
	{{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}, "Left"},
	{{0, 1, 0}, {1, 0, 0}, {0, 0, -1}, "Top"},
	{{0, -1, 0}, {1, 0, 0}, {0, 0, 1}, "Bottom"},
}

// A cube face as drawn in square `r`: its middle and the screen directions (points) of its
// own right and up from there to its edges, and how squarely it faces the eye (0 edge on).
Cube_Face_Drawn :: struct {
	face:     int,
	middle:   [2]f32,
	u, v:     [2]f32,
	facing:   f32,
}

// The faces turned toward the eye, at most three, which in a parallel view never overlap.
gizmo_cube_faces :: proc(r: ui.Rect, right, up, back: geom.Vec3) -> (faces: [3]Cube_Face_Drawn, count: int) {
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	half := min(r.w, r.h) * GIZMO_CUBE_HALF
	screen :: proc(d, right, up: geom.Vec3, half: f32) -> [2]f32 {return half * [2]f32{linalg.dot(d, right), -linalg.dot(d, up)}}
	for f, i in CUBE_FACES {
		facing := linalg.dot(f.normal, back)
		if facing <= 0.02 || count == len(faces) do continue
		faces[count] = {i, c + screen(f.normal, right, up, half), screen(f.u, right, up, half), screen(f.v, right, up, half), facing}
		count += 1
	}
	return
}

// Where `at` lands on cube face `f` as drawn: across its right and up, -1 to 1 each way
// inside it.
@(private = "file")
cube_face_coords :: proc(f: Cube_Face_Drawn, at: [2]f32) -> (a, b: f32, ok: bool) {
	p := at - f.middle
	det := f.u.x * f.v.y - f.u.y * f.v.x
	if abs(det) < 1e-6 do return
	a = (p.x * f.v.y - p.y * f.v.x) / det
	b = (f.u.x * p.y - f.u.y * p.x) / det
	return a, b, abs(a) <= 1.04 && abs(b) <= 1.04
}

// The part of the cube under `at`: the face, and which of its edges or corners (-1, 0 or 1
// across and up, 0 0 its middle), with the direction that part looks from. False off it.
gizmo_cube_pick :: proc(r: ui.Rect, right, up, back: geom.Vec3, at: [2]f32) -> (face: int, zone: [2]int, from: geom.Vec3, ok: bool) {
	faces, count := gizmo_cube_faces(r, right, up, back)
	for f in faces[:count] {
		a, b := cube_face_coords(f, at) or_continue
		zone = {zone_of(a), zone_of(b)}
		cf := CUBE_FACES[f.face]
		from = cf.normal + f32(zone.x) * cf.u + f32(zone.y) * cf.v
		return f.face, zone, from, true
	}
	return
	zone_of :: proc(x: f32) -> int {return 0 if abs(x) <= GIZMO_CUBE_ZONE else (1 if x > 0 else -1)}
}

// Lays the gizmo out under the top bar on the pen side, left of whatever stands at that
// side's top, where the pen reaches it and ZBrush, Blender and Nomad all keep theirs: the
// top right for the right-handed.
kit_nav_head :: proc(app: ^App) {
	ctx := &app.kit.ctx
	ui.begin_anchored(ctx, "navigation head", .End, .Start, {lens_nav_offset(app), TOP_BAR_H + 6}, {direction = .Column})
	size := [2]f32{VIEW_GIZMO_SIZE, VIEW_GIZMO_SIZE} if app.nav.view_gizmo != .Model else {NAV_HEAD_W, NAV_HEAD_H}
	nav_head_place(app, size)
	ui.end(ctx)
}

// Places the gizmo, `size` points, in the container being laid out, and answers a tap (a
// view from where it lands), a drag (a turn), the pen's roll (a spin) and a hold or right
// click (the style's popover). For the Model style, records where the head is drawn, in
// physical pixels, for the renderer to size its texture.
nav_head_place :: proc(app: ^App, size: [2]f32) {
	k := &app.kit
	ctx := &k.ctx
	a := ui.area(ctx, "navigation head", size)
	pen_zone(app, a.rect, .Nav_Head)
	// Holding it, or a right click, picks the style beside it; asked before anything is
	// drawn over it, while the area is still the widget last laid out.
	if ui.secondary(ctx) do bar_pop_toggle(app, .View_Gizmo, a.rect, .Below_End)
	style := app.nav.view_gizmo
	// On whole pixels, so the head's texture shows pixel for pixel.
	d := ctx.input.pixel_density
	px := [4]f32{math.round(a.rect.x * d), math.round(a.rect.y * d), math.round(a.rect.w * d), math.round(a.rect.h * d)}
	r := ui.Rect{px[0] / d, px[1] / d, px[2] / d, px[3] / d}
	if a.hovered || a.held {
		c := ctx.theme.fill_pressed if a.held else ctx.theme.fill_hover
		ui.fill_circle(ctx, {r.x + r.w * 0.5, r.y + r.h * 0.5}, min(r.w, r.h) * 0.5, c)
	}
	right, up, back := camera.orbit_basis(app.camera)
	n := &k.nav
	pointing := a.hovered && !n.turned
	switch style {
	case .Axes:
		gizmo_axes_draw(ctx, r, right, up, back, a.mouse, pointing)
	case .Cube:
		gizmo_cube_draw(ctx, r, right, up, back, a.mouse, pointing)
		if app.nav.gizmo_axes do nav_axes_draw(app, r)
	case .Model:
		k.nav.size = {u32(px[2]), u32(px[3])}
		k.nav.placed = true
		ui.image(ctx, r, KIT_NAV_HEAD_IMAGE)
		if app.nav.gizmo_axes do nav_axes_draw(app, r)
	}

	// The pen's roll over it spins the view about the scene's up axis, clockwise turning
	// the model clockwise seen from above, as a turntable under the model would.
	if roll := ui.hover_roll(ctx, a.id, a.hovered); roll != 0 {
		camera.orbit_spin(&app.camera, math.to_radians(roll))
		ui.roll_hint(ctx, "Spin")
	}
	if a.pressed {
		n.from, n.last, n.turned = a.mouse, a.mouse, false
		orbit_latch(app)
	}
	if a.held {
		if !n.turned && linalg.length(a.mouse - n.from) > ctx.theme.slop do n.turned = true
		if n.turned && a.mouse != n.last {
			camera.orbit_rotate(&app.camera, (a.mouse - n.last) * k.scale, orbit_settings(app))
			app.coach_seen += {.Turn}
		}
		n.last = a.mouse
	}
	if !a.clicked || n.turned do return
	from: geom.Vec3
	on := false
	switch style {
	case .Axes:
		from, on = gizmo_axes_pick(r, right, up, back, a.mouse)
	case .Cube:
		_, _, from, on = gizmo_cube_pick(r, right, up, back, a.mouse)
	case .Model:
		at := [2]f32{(a.mouse.x - r.x) / r.w * 2 - 1, 1 - (a.mouse.y - r.y) / r.h * 2}
		side: camera.Axis_View
		if side, on = nav_head_side(camera.orbit_rotation(app.camera), at, r.w / r.h); on {
			command_run(app, .View_Axis, int(side))
			n.taps += 1
		}
		return
	}
	if on {
		nav_look_from(app, from)
		n.taps += 1
	}
}

// Looks from direction `from` (world space, toward the eye), gliding there as the view
// commands do: along an axis it is that axis's view (View_Axis), so the top view has the
// back at the top of the screen as the keys give it.
nav_look_from :: proc(app: ^App, from: geom.Vec3) {
	zeros := 0
	axis := 0
	for i in 0 ..< 3 {
		if from[i] == 0 do zeros += 1
		else do axis = i
	}
	if zeros == 2 {
		plus := from[axis] > 0
		side: camera.Axis_View
		switch axis {
		case 0: side = .Right if plus else .Left
		case 1: side = .Top if plus else .Bottom
		case:   side = .Front if plus else .Back
		}
		command_run(app, .View_Axis, int(side))
		return
	}
	before := camera_ease_begin(app)
	camera.orbit_look_from(&app.camera, from)
	camera_ease_from(app, before)
}

// The Axes style: lines from the middle to the plus balls, the balls back to front, the
// plus ones solid with their letter and the minus ones as tinted rings, and a ring round
// the ball a tap would take.
@(private = "file")
gizmo_axes_draw :: proc(ctx: ^ui.Context, r: ui.Rect, right, up, back: geom.Vec3, mouse: [2]f32, pointing: bool) {
	balls := gizmo_balls(r, right, up, back)
	c := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
	radius := min(r.w, r.h) * GIZMO_BALL_R
	hot: geom.Vec3
	if pointing do hot, _ = gizmo_axes_pick(r, right, up, back, mouse)
	letters := [3]string{"X", "Y", "Z"}
	for b in balls {
		col := NAV_AXIS_COLORS[b.axis]
		if !b.minus {
			line := col
			if b.depth < -0.2 do line.a = 150
			ui.line(ctx, c, b.at, line, 2)
			ui.fill_circle(ctx, b.at, radius, col)
			ui.text(ctx, letters[b.axis], b.at.x, b.at.y, radius * 1.45, {18, 20, 24, 255}, .Semibold, .Center)
		} else {
			ui.fill_circle(ctx, b.at, radius, ui.color_fade(col, 0.35))
			ui.stroke_circle(ctx, b.at, radius - 0.75, col, 1.5)
		}
		looks: geom.Vec3
		looks[b.axis] = -1 if b.minus else 1
		if b.depth > 0.999 do looks = -looks
		if pointing && hot == looks do ui.stroke_circle(ctx, b.at, radius + 1.5, {255, 255, 255, 230}, 1.5)
	}
}

// The Cube style: its faces turned toward the eye, tinted by their axis and shaded by how
// squarely they face it, each with its name laid onto it, and the part a tap would take
// (the face's middle, an edge or a corner) lit.
@(private = "file")
gizmo_cube_draw :: proc(ctx: ^ui.Context, r: ui.Rect, right, up, back: geom.Vec3, mouse: [2]f32, pointing: bool) {
	faces, count := gizmo_cube_faces(r, right, up, back)
	hot_face, hot_zone := -1, [2]int{}
	if pointing {
		if f, z, _, on := gizmo_cube_pick(r, right, up, back, mouse); on do hot_face, hot_zone = f, z
	}
	half := min(r.w, r.h) * GIZMO_CUBE_HALF
	for f in faces[:count] {
		cf := CUBE_FACES[f.face]
		axis := 0 if cf.normal.x != 0 else (1 if cf.normal.y != 0 else 2)
		quad :: proc(f: Cube_Face_Drawn, a0, a1, b0, b1: f32) -> [4][2]f32 {
			return {f.middle + a0 * f.u + b0 * f.v, f.middle + a1 * f.u + b0 * f.v, f.middle + a1 * f.u + b1 * f.v, f.middle + a0 * f.u + b1 * f.v}
		}
		// The axis's colour lightened toward white, darker as the face turns away.
		base := NAV_AXIS_COLORS[axis]
		shade := 0.7 + 0.3 * f.facing
		tint: ui.Color
		for i in 0 ..< 3 do tint[i] = u8((f32(base[i]) * 0.6 + 255 * 0.4) * shade)
		tint.a = 255
		pts := quad(f, -1, 1, -1, 1)
		ui.fill_convex(ctx, pts[:], tint)
		ui.polyline(ctx, pts[:], {16, 19, 23, 150}, 1, closed = true)
		if f.face == hot_face {
			span :: proc(z: int) -> (lo, hi: f32) {
				switch z {
				case -1: return -1, -GIZMO_CUBE_ZONE
				case 1:  return GIZMO_CUBE_ZONE, 1
				}
				return -GIZMO_CUBE_ZONE, GIZMO_CUBE_ZONE
			}
			a0, a1 := span(hot_zone.x)
			b0, b1 := span(hot_zone.y)
			lit := quad(f, a0, a1, b0, b1)
			ui.fill_convex(ctx, lit[:], {255, 255, 255, 120})
		}
		// The name, laid out flat, then mapped onto the face; a face
		// seen nearly edge on fades its name out.
		if f.facing < 0.12 do continue
		size := half * 0.62
		width := ui.text_width(ctx, cf.name, size, .Semibold)
		if width > half * 1.7 do size *= half * 1.7 / width
		ink := ui.Color{16, 19, 23, u8(255 * min(1, (f.facing - 0.12) * 3))}
		// Laid out in the gizmo's middle, so no letter falls outside its clip before the map
		// moves it onto the face.
		mark := ui.vertex_mark(ctx)
		mid := [2]f32{r.x + r.w * 0.5, r.y + r.h * 0.5}
		ui.text(ctx, cf.name, mid.x, mid.y, size, ink, .Semibold, .Center)
		ui.map_since(ctx, mark, mid, f.middle, f.u / half, -f.v / half)
	}
}

// The world's axes as the camera sees them, short lines from the gizmo's bottom-left
// corner, the ones pointing away drawn first and dimmer: beside the Cube and the Model.
@(private = "file")
nav_axes_draw :: proc(app: ^App, r: ui.Rect) {
	ctx := &app.kit.ctx
	right, up, back := camera.orbit_basis(app.camera)
	o := [2]f32{r.x + 7, r.y + r.h - 7}
	LEN :: 9
	order := [3]int{0, 1, 2}
	// Back to front: the axis pointing furthest away first.
	for i in 0 ..< 3 do for j in i + 1 ..< 3 do if back[order[j]] < back[order[i]] do order[i], order[j] = order[j], order[i]
	for i in order {
		tip := o + LEN * [2]f32{right[i], -up[i]}
		c := NAV_AXIS_COLORS[i]
		if back[i] < -0.2 do c.a = 120
		ui.line(ctx, o, tip, c, 1.6)
		ui.fill_circle(ctx, tip, 1.6, c)
	}
}

// The gizmo's choices: its style, the Model style's model and the person's own one, and
// the axes at its corner. Settings > Camera > VIEW GIZMO and the gizmo's own popover both
// draw this.
view_gizmo_controls :: proc(app: ^App) {
	ctx := &app.kit.ctx
	n := &app.nav
	names := [len(View_Gizmo)]string{VIEW_GIZMO_NAMES[.Axes], VIEW_GIZMO_NAMES[.Cube], VIEW_GIZMO_NAMES[.Model]}
	if picked := ui.tabs(ctx, "View gizmo style", names[:], int(n.view_gizmo)); picked >= 0 do n.view_gizmo = View_Gizmo(picked)
	switch n.view_gizmo {
	case .Axes:
		ui.paragraph(ctx, "The world's axes as balls: tap one to look from that side, and the one facing you to look from the other side.")
	case .Cube:
		ui.paragraph(ctx, "A cube that names its sides: tap a face, an edge or a corner to look from it, the edges and corners at 45 degrees.")
	case .Model:
		ui.paragraph(ctx, "A model that turns with the view: tap a side of it to look from that side.")
		models := [len(Gizmo_Model)]string{"Head", "Your model"}
		if picked := ui.tabs(ctx, "View gizmo model", models[:], int(n.gizmo_model)); picked >= 0 do n.gizmo_model = Gizmo_Model(picked)
		if n.gizmo_model == .Own {
			if len(app.view_model.indices) == 0 do ui.paragraph(ctx, "No model of yours yet: select an object and use it.")
			else do ui.paragraph(ctx, fmt.tprintf("%s, %d triangles.", app.view_model_name, len(app.view_model.indices) / 3))
		}
		if ui.button(ctx, "Use selected object", .Bordered, enabled = selected_object(app) != nil) do view_model_take(app)
	}
	if n.view_gizmo != .Axes do _ = ui.switch_row(ctx, "Axes at its corner", &n.gizmo_axes)
}

// The gizmo's popover, beside it: the same choices as Settings.
kit_view_gizmo_pop :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	p := &k.bar_pop
	if !ui.popover_begin(ctx, "view gizmo pop", &p.open, p.at, p.side, {direction = .Column, gap = 6, padding = 12, width = 280}) do return
	defer ui.popover_end(ctx)
	ui.caption(ctx, "VIEW GIZMO")
	view_gizmo_controls(app)
}

// Makes the person's own model from the selected object: its lowest level, turned as the
// object is in the scene, simplified to VIEW_MODEL_TRIANGLES, centred and sized to a unit
// round its middle as the head is, and kept beside the settings for the next run.
view_model_take :: proc(app: ^App) {
	obj := selected_object(app)
	if obj == nil do return
	if obj.voxel != nil || len(obj.levels.levels) == 0 {
		_ = ui.toast(&app.kit.ctx, "Voxel objects can't be the gizmo's model yet; remesh it first.", .Warning)
		return
	}
	start := time.tick_now()
	src := obj.levels.levels[0].mesh
	m: geom.Mesh
	if len(src.indices) / 3 > VIEW_MODEL_TRIANGLES {
		out, _, ok := geom.mesh_decimate(src, VIEW_MODEL_TRIANGLES, &app.pool)
		if !ok {
			_ = ui.toast(&app.kit.ctx, "That object could not be simplified for the gizmo.", .Warning)
			return
		}
		m = out
	} else {
		m.positions = slice.clone_to_dynamic(src.positions[:])
		m.indices = slice.clone_to_dynamic(src.indices[:])
	}
	if !view_model_fit(&m, transform_rotation(obj.transform)) {
		geom.mesh_destroy(&m)
		return
	}
	resize(&m.normals, len(m.positions))
	geom.mesh_recompute_normals(&m)
	geom.mesh_destroy(&app.view_model)
	delete(app.view_model_name)
	app.view_model, app.view_model_name = m, fmt.aprint(object_label(obj))
	app.nav.view_gizmo, app.nav.gizmo_model = .Model, .Own
	app.view_model_serial += 1
	log.infof("view gizmo model: %s, %d triangles in %.1f ms", app.view_model_name, len(m.indices) / 3, time.duration_milliseconds(time.tick_since(start)))
	if path := view_model_path(app.settings_file); path != "" do if !view_model_save(app.view_model, app.view_model_name, path) do log.warnf("could not keep the gizmo's model in %s", path)
	if app.settings_file != "" do _ = settings_save(app, app.settings_file)
}

// Turns `m` by `rotation`, then moves it to its bounds' middle and scales it so its
// furthest point is a unit away, as the head is. False for a mesh with no size.
view_model_fit :: proc(m: ^geom.Mesh, rotation: matrix[3, 3]f32) -> bool {
	if len(m.positions) == 0 || len(m.indices) < 3 do return false
	lo, hi := geom.Vec3{max(f32), max(f32), max(f32)}, geom.Vec3{min(f32), min(f32), min(f32)}
	for &p in m.positions {
		p = rotation * p
		lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	}
	mid := (lo + hi) * 0.5
	far: f32 = 0
	for p in m.positions do far = max(far, linalg.length(p - mid))
	if far < 1e-9 do return false
	for &p in m.positions do p = (p - mid) / far
	return true
}

// The person's own gizmo model's file, beside the settings file (as the library is), or ""
// when the run keeps no settings.
view_model_path :: proc(settings: string) -> string {
	if settings == "" do return ""
	dir, base := filepath.split(settings)
	name := VIEW_MODEL_FILE if base == SETTINGS_FILE else fmt.tprintf("%s-%s", filepath.stem(base), VIEW_MODEL_FILE)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

VIEW_MODEL_FILE :: "view_model.bin"

// The file starts with this, then the name's length, the vertex and triangle counts (u32
// each), the name, the positions and the indices, all little-endian as every device the
// app runs on is.
VIEW_MODEL_MAGIC :: [4]u8{'S', 'V', 'G', 'M'}

// The name of the object it was made from is cut at this many bytes.
VIEW_MODEL_NAME_MAX :: 256

@(private = "file")
View_Model_Head :: struct #packed {
	magic:     [4]u8,
	name:      u32,
	vertices:  u32,
	triangles: u32,
}

// Writes the model to `path`. False when the file could not be written.
view_model_save :: proc(m: geom.Mesh, name: string, path: string) -> bool {
	label := name[:min(len(name), VIEW_MODEL_NAME_MAX)]
	head := View_Model_Head{VIEW_MODEL_MAGIC, u32(len(label)), u32(len(m.positions)), u32(len(m.indices) / 3)}
	data := make([dynamic]u8, 0, size_of(head) + len(label) + len(m.positions) * size_of(geom.Vec3) + len(m.indices) * 4, context.temp_allocator)
	append(&data, ..slice.bytes_from_ptr(&head, size_of(head)))
	append(&data, label)
	append(&data, ..slice.to_bytes(m.positions[:]))
	append(&data, ..slice.to_bytes(m.indices[:len(m.indices) / 3 * 3]))
	return os.write_entire_file(path, data[:]) == nil
}

// Reads a model view_model_save wrote. A missing, damaged or foreign file is refused: not
// ok, with nothing to free.
view_model_load :: proc(path: string, allocator := context.allocator) -> (m: geom.Mesh, name: string, ok: bool) {
	if path == "" do return
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || len(data) < size_of(View_Model_Head) do return
	head := (^View_Model_Head)(raw_data(data))^
	if head.magic != VIEW_MODEL_MAGIC || head.name > VIEW_MODEL_NAME_MAX || head.vertices == 0 || head.triangles == 0 do return
	if head.vertices > 4 * VIEW_MODEL_TRIANGLES || head.triangles > VIEW_MODEL_TRIANGLES do return
	want := size_of(View_Model_Head) + int(head.name) + int(head.vertices) * size_of(geom.Vec3) + int(head.triangles) * 12
	if len(data) != want do return
	at := size_of(View_Model_Head)
	label := string(data[at:][:head.name])
	at += int(head.name)
	positions := slice.reinterpret([]geom.Vec3, data[at:][:int(head.vertices) * size_of(geom.Vec3)])
	at += int(head.vertices) * size_of(geom.Vec3)
	indices := slice.reinterpret([]u32, data[at:][:int(head.triangles) * 12])
	for i in indices do if i >= head.vertices do return
	for p in positions do for c in p do if !(abs(c) <= 2) do return
	context.allocator = allocator
	m.positions = slice.clone_to_dynamic(positions)
	m.indices = slice.clone_to_dynamic(indices)
	m.normals = make([dynamic]geom.Vec3, len(positions))
	geom.mesh_recompute_normals(&m)
	return m, fmt.aprint(label), true
}
