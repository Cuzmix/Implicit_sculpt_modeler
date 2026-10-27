package main

import "core:math/linalg"

import "../camera"
import "../gizmo"
import "../ui"

// The lights in the viewport, while the Scene palette's Lights section shows: a marker
// for each light, as Blender, KeyShot and Marmoset draw their lamps, the picked one
// ringed. A point light or a spot shows where it stands, held at the view's edge when it
// is off screen; a sun, which has only a direction, shows on a large circle round the
// orbit's centre where the light sphere would show it, a ring when it is behind the
// model. A press on a marker picks that light and a drag moves it: a point light or a
// spot across the view at its depth (a spot still aimed where it was), a sun round the
// circle, as on the light sphere. With Place highlight on, a press on the model moves the
// picked light so its highlight lands under the finger, as Marmoset's light placement
// and KeyShot's highlight tool do: a sun turns, a point light or a spot moves round the
// spot at the distance it was, a spot aimed at it. The picked point light or spot also
// has the Move tool's handles about its marker, as Blender's lamps take its axis moves
// and Marmoset's lights their gizmo: an arm along each of the scene's axes moves it
// along that axis, a square between two arms across their plane. Each drag is one undo
// step.

// The Lights section's Distance range, as shares of the camera's distance.
LIGHT_DISTANCE_MIN :: 0.05
LIGHT_DISTANCE_MAX :: 20
// The circle the suns' markers stand on, as a share of the viewport's shorter side.
SUN_MARKER_RADIUS :: 0.42
// How far inside the viewport's edge a marker held there stands, in points.
LIGHT_MARKER_INSET :: 28

// A press on the lights in the viewport, between frames.
Light_Press :: struct {
	active:  bool,
	placing: bool, // Place highlight's, rather than a marker's
	grab:    [2]f32, // the marker less the pointer where the press went down, on screen
	from:    [2]f32, // where the press went down, on screen
	at:      [2]f32, // where a dragged point light or spot was on screen then, off screen too
	depth:   Vec3, // ...and in the scene, which its drag keeps the depth of
	front:   bool, // a dragged sun was in front of the model
	aim:     Vec3, // where a dragged spot was aimed, in the scene
	reach:   f32, // how far a placed point light or spot stays from the surface
	moves:   int, // drags and placements made, for the exit stats
	// A drag of the picked light's handles: which one (None for the marker's drag), how
	// far along its axis the press was, or where it met its plane, in the scene.
	handle:  gizmo.Handle,
	along:   f32,
	met:     Vec3,
	hover:   gizmo.Handle, // the handle under a mouse or pen hovering, drawn lit
}

// How far from a marker's middle its plate reaches, in points (a marker held at the
// edge is smaller).
LIGHT_MARKER_PX :: 15

// Whether the Lights section is what the tray shows, so the markers are up.
lights_section_shown :: proc(app: ^App) -> bool {
	k := &app.kit
	return k.inspector && k.tab == .Scene && tray_section(app, .Scene) == .Lights
}

// Where a point or spot light is in the scene.
light_world_pos :: proc(app: ^App, l: Light) -> Vec3 {
	if l.space == .Scene do return l.pos
	return app.camera.target + linalg.transpose(view_rotation(app)) * (lights_frame(app) * l.pos)
}

// Toward light `i` in the scene's axes, unit length (light_view_axis turned back).
light_world_dir :: proc(app: ^App, i: int) -> Vec3 {
	return linalg.transpose(view_rotation(app)) * light_view_axis(app, i)
}

// Sets light `i`'s direction toward it, `dir`, and with `at` its place, both in the
// scene, keeping the space it moves with.
light_set_world :: proc(app: ^App, i: int, dir: Vec3, at: Maybe(Vec3) = nil) {
	l := &app.scene.lights.lights[i]
	if l.space == .Scene {
		l.dir = dir
		if p, ok := at.?; ok do l.pos = p
		return
	}
	into := linalg.transpose(lights_frame(app)) * view_rotation(app)
	l.dir = into * dir
	if p, ok := at.?; ok do l.pos = into * (p - app.camera.target)
}

// The view's projection times its view, for placing world points over a viewport of `size`.
view_proj_of :: proc(app: ^App, size: [2]f32) -> matrix[4, 4]f32 {
	return camera.orbit_proj(app.camera, size.x / max(size.y, 1)) * camera.orbit_view(app.camera)
}

// How far point or spot light `i` stands from the orbit's centre.
light_center_distance :: proc(app: ^App, i: int) -> f32 {
	return linalg.length(light_world_pos(app, app.scene.lights.lights[i]) - app.camera.target)
}

// Moves point or spot light `i` toward or away from the orbit's centre to `far` from it,
// pointing as it did.
light_set_center_distance :: proc(app: ^App, i: int, far: f32) {
	at := light_world_pos(app, app.scene.lights.lights[i])
	out := at - app.camera.target
	way := linalg.normalize(out) if linalg.length(out) > 1e-6 else light_world_dir(app, i)
	light_set_world(app, i, light_world_dir(app, i), app.camera.target + way * far)
}

// Where a dragged spot is aimed: as far along its direction as the orbit's centre is.
@(private = "file")
spot_aim :: proc(app: ^App, i: int) -> Vec3 {
	at := light_world_pos(app, app.scene.lights.lights[i])
	return at - light_world_dir(app, i) * linalg.length(at - app.camera.target)
}

// Where a sun's marker stands on the circle round the orbit's centre, as the light
// sphere would show it, before light_marker_at keeps it clear of the panel; and whether
// it is in front of the model.
@(private = "file")
sun_marker :: proc(app: ^App, i: int, size: [2]f32) -> (at: [2]f32, front: bool) {
	centre, _ := gizmo.project(view_proj_of(app, size), app.camera.target, size)
	a := light_view_axis(app, i)
	return centre + [2]f32{a.x, -a.y} * (SUN_MARKER_RADIUS * min(size.x, size.y)), a.z >= 0
}

// The part of the viewport a marker may stand in: inside its edge by the inset and
// clear of the bars and the Scene palette round it, which would hide it, in viewport
// points.
light_marker_room :: proc(app: ^App, size: [2]f32) -> (lo, hi: [2]f32) {
	inset := LIGHT_MARKER_INSET * gizmo_scale(app)
	k := &app.kit
	area := ui.safe_area(&k.ctx)
	lo = [2]f32{area.x + kit_left(app), area.y + TOP_BAR_H} * k.scale + inset
	hi = [2]f32{area.x + area.w - kit_right(app), area.y + area.h - dock_stack(app)} * k.scale - inset
	// A window too small for the bars keeps its edge alone.
	if hi.x - lo.x < size.x * 0.25 do lo.x, hi.x = inset, size.x - inset
	if hi.y - lo.y < size.y * 0.25 do lo.y, hi.y = inset, size.y - inset
	panel := ui.prev_rect(&k.ctx, "inspector")
	if panel.w <= 0 do return
	left, right := panel.x * k.scale, (panel.x + panel.w) * k.scale
	// Off the side the palette stands on, unless that leaves too little room to show.
	if left + right > size.x {
		if left - inset - lo.x > size.x * 0.25 do hi.x = left - inset
	} else if hi.x - right - inset > size.x * 0.25 {
		lo.x = right + inset
	}
	return
}

// Light `i`'s marker on screen, in viewport points: whether the light is in front of the
// model (a sun) and whether its marker is held at the edge of the room it has, its
// place being off screen or under the palette.
light_marker_at :: proc(app: ^App, i: int, size: [2]f32) -> (at: [2]f32, front, edge: bool) {
	l := app.scene.lights.lights[i]
	s: [2]f32
	front = true
	if l.kind == .Sun || l.pos == {} {
		s, front = sun_marker(app, i, size)
	} else {
		world := light_world_pos(app, l)
		ok: bool
		s, ok = gizmo.project(view_proj_of(app, size), world, size)
		if !ok {
			// Behind the camera: toward it from the middle of the view, at the edge.
			v := (camera.orbit_view(app.camera) * [4]f32{world.x, world.y, world.z, 1}).xyz
			s = size * 0.5 + [2]f32{v.x, -v.y} * 1e6
		}
	}
	lo, hi := light_marker_room(app, size)
	if s.x >= lo.x && s.x <= hi.x && s.y >= lo.y && s.y <= hi.y do return s, front, false
	// Pulled in along the line from the middle of the room until it is inside.
	mid := (lo + hi) * 0.5
	d := s - mid
	k: f32 = 1
	if d.x != 0 do k = min(k, (hi.x - mid.x) / abs(d.x))
	if d.y != 0 do k = min(k, (hi.y - mid.y) / abs(d.y))
	return mid + d * k, front, true
}

// The handles of point or spot light `i` as they appear on screen, about where it
// stands; not ok for a sun, a light not placed yet, or one whose marker is held at the
// edge of the room, whose place is not where its marker shows.
light_gizmo :: proc(app: ^App, i: int, size: [2]f32) -> (s: gizmo.Screen) {
	set := &app.scene.lights
	if i < 0 || i >= int(set.count) || size.x <= 0 || size.y <= 0 do return
	l := set.lights[i]
	if l.kind == .Sun || l.pos == {} do return
	if _, _, edge := light_marker_at(app, i, size); edge do return
	center := light_world_pos(app, l)
	arm_px := gizmo.ARM_PX * gizmo_scale(app)
	arm := arm_px * camera.orbit_world_per_px(app.camera, center, size.y)
	return gizmo.screen(view_proj_of(app, size), center, arm, -camera.orbit_toward(app.camera, center), size, arm_px)
}

// The picked light's handle under `at` while the Lights section shows: an arm or a plane
// square, never the middle, which is its marker's.
light_gizmo_pick :: proc(app: ^App, at, size: [2]f32) -> gizmo.Handle {
	if !lights_section_shown(app) do return .None
	sc := light_gizmo(app, app.light_pick, size)
	if !sc.ok || linalg.length(at - sc.center) <= LIGHT_MARKER_PX * gizmo_scale(app) do return .None
	h := gizmo.pick(sc, .Move, at, gizmo_radius(app))
	return .None if h == .View else h
}

// Starts a drag of light `i`'s handle `h` from a press at `at`: where the light stands
// and where the press meets the handle's axis or plane. False when it cannot be dragged
// from there (an axis seen end on, a plane edge on).
light_gizmo_begin :: proc(app: ^App, p: ^Light_Press, i: int, h: gizmo.Handle, at, size: [2]f32) -> bool {
	stands := light_world_pos(app, app.scene.lights.lights[i])
	origin, dir := mouse_ray(app.camera, at, size)
	p.handle, p.depth, p.aim = h, stands, spot_aim(app, i)
	#partial switch h {
	case .X, .Y, .Z:
		p.along = gizmo.closest_on_axis(stands, gizmo.AXES[int(h) - int(gizmo.Handle.X)], origin, dir) or_return
	case .YZ, .XZ, .XY:
		p.met = gizmo.ray_plane(origin, dir, stands, gizmo.AXES[int(h) - int(gizmo.Handle.YZ)]) or_return
	case:
		return false
	}
	return true
}

// Moves light `i` by its handle's drag to the pointer at `at`: along the axis, or across
// the plane, from where it stood at the press, a spot still aimed where it was.
light_gizmo_drag :: proc(app: ^App, p: ^Light_Press, i: int, at, size: [2]f32) {
	origin, dir := mouse_ray(app.camera, at, size)
	moved := p.depth
	#partial switch p.handle {
	case .X, .Y, .Z:
		axis := gizmo.AXES[int(p.handle) - int(gizmo.Handle.X)]
		s, ok := gizmo.closest_on_axis(p.depth, axis, origin, dir)
		if !ok do return
		moved += axis * (s - p.along)
	case .YZ, .XZ, .XY:
		k := int(p.handle) - int(gizmo.Handle.YZ)
		hit, ok := gizmo.ray_plane(origin, dir, p.depth, gizmo.AXES[k])
		if !ok do return
		delta := hit - p.met
		// Exactly in the plane, whatever the rounding.
		delta[k] = 0
		moved += delta
	case:
		return
	}
	aim := moved - p.aim
	light_set_world(app, i, linalg.normalize(aim) if linalg.length(aim) > 1e-6 else light_world_dir(app, i), moved)
}

// The light whose marker is nearest `at` within the pointer's reach, the later one where
// two are as near (it is drawn over the other); -1 for none.
light_marker_pick :: proc(app: ^App, at, size: [2]f32) -> int {
	best, best_d := -1, gizmo_radius(app)
	for i in 0 ..< int(app.scene.lights.count) {
		s, _, _ := light_marker_at(app, i, size)
		if d := linalg.length(s - at); d <= best_d do best, best_d = i, d
	}
	return best
}

// Whether a press at `at` lands on a light's marker in the viewport.
light_marker_pressed :: proc(app: ^App, at, size: [2]f32) -> bool {
	return lights_section_shown(app) && (light_marker_pick(app, at, size) >= 0 || light_gizmo_pick(app, at, size) != .None)
}

// Whether a press at `at` is the lights' rather than a tool's: on a marker, or anywhere
// with Place highlight on (a press off the model still turns the view).
lights_take_press :: proc(app: ^App, at, size: [2]f32) -> bool {
	if !lights_section_shown(app) || app.scene.lights.count <= 0 do return false
	return app.ui.light_place || light_marker_pick(app, at, size) >= 0 || light_gizmo_pick(app, at, size) != .None
}

// Moves the picked light so its highlight, seen from the camera, lands on the surface at
// `hit` facing `normal`: toward the light is the view direction mirrored about the
// normal. A point light or a spot stands `reach` from the surface that way, a spot
// aimed at it.
light_place_highlight :: proc(app: ^App, i: int, hit, normal: Vec3, reach: f32) {
	v := linalg.normalize(camera.orbit_eye(app.camera) - hit)
	n := normal
	if linalg.dot(n, v) < 0 do n = -n
	toward := linalg.normalize(2 * linalg.dot(n, v) * n - v)
	if app.scene.lights.lights[i].kind == .Sun {
		light_set_world(app, i, toward)
	} else {
		light_set_world(app, i, toward, hit + toward * reach)
	}
}

// Follows this frame's input for the lights in the viewport. Returns true while a press
// is theirs, so no tool takes it.
lights_viewport_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	p := &app.ui.light_press
	set := &app.scene.lights
	if !p.active do p.hover = light_gizmo_pick(app, input.mouse_pos, input.size) if input.hovered && !input.primary else .None
	if p.active {
		if !input.primary || app.light_pick >= int(set.count) {
			p.active = false
			p.moves += 1
			return true
		}
		i := app.light_pick
		if p.handle != .None {
			light_gizmo_drag(app, p, i, input.mouse_pos, input.size)
			return true
		}
		if p.placing {
			origin, dir := mouse_ray(app.camera, input.mouse_pos, input.size)
			if _, hit, normal, ok := scene_raycast_surface(app, origin, dir); ok do light_place_highlight(app, i, hit, normal, p.reach)
			return true
		}
		if set.lights[i].kind == .Sun || set.lights[i].pos == {} {
			// Round the circle, as on the light sphere, keeping the side it was on.
			centre, _ := gizmo.project(view_proj_of(app, input.size), app.camera.target, input.size)
			at := (input.mouse_pos + p.grab - centre) / (SUN_MARKER_RADIUS * min(input.size.x, input.size.y))
			light_set_view_dir(app, i, light_sphere_dir({at.x, -at.y}, p.front))
			return true
		}
		// Across the view at the depth it had, by as much as the pointer moved; one behind
		// the camera, with no place on screen to move from, stays put.
		if p.depth == {} do return true
		origin, dir := mouse_ray(app.camera, p.at + input.mouse_pos - p.from, input.size)
		forward := linalg.transpose(view_rotation(app)) * Vec3{0, 0, -1}
		along := linalg.dot(dir, forward)
		if abs(along) < 1e-6 do return true
		moved := origin + dir * (linalg.dot(p.depth - origin, forward) / along)
		aim := moved - p.aim
		light_set_world(app, i, linalg.normalize(aim) if linalg.length(aim) > 1e-6 else light_world_dir(app, i), moved)
		return true
	}
	if !input.press || !input.primary || !lights_section_shown(app) || set.count <= 0 do return false
	start := gesture_start(input)
	if app.ui.light_place {
		origin, dir := mouse_ray(app.camera, start, input.size)
		_, hit, normal, ok := scene_raycast_surface(app, origin, dir)
		if !ok do return false
		i := clamp(app.light_pick, 0, int(set.count) - 1)
		app.light_pick = i
		l := set.lights[i]
		// A point light or a spot keeps its distance from the surface it lights.
		reach := app.camera.distance
		if l.kind != .Sun && l.pos != {} do reach = max(linalg.length(light_world_pos(app, l) - hit), 1e-3)
		light_drag_changed(app, set^, "Place highlight")
		p^ = {active = true, placing = true, reach = reach, moves = p.moves}
		set.lights[i].on = true
		light_place_highlight(app, i, hit, normal, reach)
		return true
	}
	// The picked light's handles first: they stand clear of its marker, which another
	// light's may be under.
	if h := light_gizmo_pick(app, start, input.size); h != .None {
		next := Light_Press{active = true, from = start, moves = p.moves}
		if light_gizmo_begin(app, &next, app.light_pick, h, start, input.size) {
			light_drag_changed(app, set^, "Move light")
			p^ = next
			return true
		}
	}
	i := light_marker_pick(app, start, input.size)
	if i < 0 do return false
	app.light_pick = i
	s, front, _ := light_marker_at(app, i, input.size)
	// A sun follows the pointer round its circle from where it stands there, even when
	// its marker is held clear of the palette.
	if l := set.lights[i]; l.kind == .Sun || l.pos == {} do s, front = sun_marker(app, i, input.size)
	light_drag_changed(app, set^, "Move light")
	p^ = {active = true, grab = s - start, from = start, front = front, moves = p.moves}
	if l := set.lights[i]; l.kind != .Sun && l.pos != {} {
		world := light_world_pos(app, l)
		if true_at, seen := gizmo.project(view_proj_of(app, input.size), world, input.size); seen {
			p.at, p.depth = true_at, world
			// A spot keeps shining at the point it was aimed at.
			p.aim = spot_aim(app, i)
		}
	}
	return true
}

// The markers: a dark plate with the kind's icon for each light, faded when it is off,
// a sun behind the model on a lighter plate, one held at the room's edge smaller; the
// picked one ringed in the accent, and a spot's line to where it is aimed.
draw_light_markers :: proc(app: ^App, o: Overlay, size: [2]f32) {
	if !lights_section_shown(app) do return
	set := &app.scene.lights
	t := o.ctx.theme
	vp := view_proj_of(app, size)
	px := gizmo_scale(app)
	// The picked point light's or spot's handles, under the markers.
	if sc := light_gizmo(app, app.light_pick, size); sc.ok {
		p := app.ui.light_press
		draw_move_handles(o, sc, p.handle if p.active && p.handle != .None else p.hover, px)
	}
	for i in 0 ..< int(set.count) {
		l := set.lights[i]
		s, front, edge := light_marker_at(app, i, size)
		alpha: f32 = 1 if l.on else 0.45
		if l.kind == .Spot && l.pos != {} && !edge {
			if e, seen := gizmo.project(vp, spot_aim(app, i), size); seen do overlay_line(o, s, e, overlay_color({1, 0.9, 0.6, 0.6 * alpha}), 1.5 * px)
		}
		r := (12 if edge else LIGHT_MARKER_PX) * px
		shown := light_rgb(l)
		for &c in shown do c = srgb_encode(min(c, 1))
		if front {
			overlay_disc(o, s, r, overlay_color({0.08, 0.08, 0.09, 0.85 * alpha}))
		} else {
			// Behind the model: a lighter plate, so it reads as the far side.
			overlay_disc(o, s, r, overlay_color({0.08, 0.08, 0.09, 0.4 * alpha}))
			alpha *= 0.7
		}
		overlay_circle(o, s, r, overlay_color({shown.r, shown.g, shown.b, alpha}), 2 * px)
		ui.icon(o.ctx, LIGHT_KIND_ICONS[l.kind], s / o.scale, t.icon_small, overlay_color({1, 1, 1, alpha}))
		if i == app.light_pick do overlay_circle(o, s, r + 5 * px, t.accent, 2.5 * px)
	}
}
