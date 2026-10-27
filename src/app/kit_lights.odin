package main

import "core:fmt"
import "core:math"
import "core:math/linalg"

import "../ui"

// The Scene palette's Lights section: the light sphere, the light it edits, its strength
// and colour, the ambient light, and under More options whether the lights stay with the
// camera or the scene and the turn of the whole set (lights.odin).

// The light sphere's height, in points.
LIGHT_SPHERE_SIZE :: 176
// The sphere's preview mesh: rings out from the middle, and points round each.
@(private = "file")
SPHERE_RINGS :: 10
@(private = "file")
SPHERE_SEGMENTS :: 40

// A press on the light sphere, between frames: where it went down, whether it became a
// drag, and the light it went down on (-1 for none) and whether that one was already the
// picked light, which a tap then sends behind or brings to the front.
Light_Sphere_State :: struct {
	from:       [2]f32,
	moved:      bool,
	hit:        int,
	was_picked: bool,
	flips:      int, // lights sent behind or brought to the front by a tap, for the exit stats
}

kit_lights :: proc(app: ^App) {
	ctx := &app.kit.ctx
	kit_light_sphere(app)
	names := [LIGHT_COUNT]string{"Light 1", "Light 2", "Light 3", "Light 4"}
	if picked := ui.tabs(ctx, "light picked", names[:], app.light_pick); picked >= 0 do app.light_pick = picked
	light := &app.lights[app.light_pick]
	_ = ui.switch_row(ctx, "On", &light.on)
	_ = ui.slider(ctx, "Intensity", &light.strength, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", light.strength))
	_ = ui.slider(ctx, "Ambient", &app.light_ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", app.light_ambient))
	if kit_more(app, .Lights) {
		_ = kit_color(app, fmt.tprintf("light %d colour", app.light_pick + 1), &light.color, linear = true)
		fixed := app.lights_fixed
		if ui.switch_row(ctx, "Fixed to the scene", &fixed) do lights_fix(app, fixed)
		_ = ui.slider(ctx, "Turn all", &app.light_turn, -180, 180, .Linear, fmt.tprintf("%+.0f°", app.light_turn))
		_ = ui.slider(ctx, "Height all", &app.light_height, -90, 90, .Linear, fmt.tprintf("%+.0f°", app.light_height))
		if ui.button(ctx, "Reset lights", .Bordered) do lights_reset(app)
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Drag on the sphere to move the picked light; tap it to send it behind the model or bring it back. Fixed to the scene, the lights stay put while the camera goes round, as on a turntable; otherwise they turn with the camera. MatCaps carry their own light.")
}

// The light sphere: a ball lit by the lights as the camera sees them, each light that is
// on a numbered marker where it points from (a ring when behind the model), the
// picked one circled. A drag moves the picked light; a tap on it flips its side, a tap on
// another picks that one, and a tap on the empty sphere puts the picked light there.
@(private = "file")
kit_light_sphere :: proc(app: ^App) {
	ctx := &app.kit.ctx
	t := ctx.theme
	a := ui.area(ctx, "light sphere", {0, LIGHT_SPHERE_SIZE})
	radius := min(a.rect.w, a.rect.h) * 0.5 - 8
	centre := [2]f32{a.rect.x + a.rect.w * 0.5, a.rect.y + a.rect.h * 0.5}
	light_sphere_draw(app, centre, radius)

	st := &app.kit.light_sphere
	at := (a.mouse - centre) / radius
	at.y = -at.y
	if a.pressed {
		st.from, st.moved = a.mouse, false
		st.hit = light_sphere_hit(app, centre, radius, a.mouse, t.target * 0.5)
		st.was_picked = st.hit == app.light_pick
		if st.hit >= 0 do app.light_pick = st.hit
	}
	pick := app.light_pick
	place :: proc(app: ^App, i: int, at: [2]f32) {
		light_set_view_dir(app, i, light_sphere_dir(at, light_view_dir(app, i).z >= 0))
		app.lights[i].on = true
	}
	if a.held {
		if !st.moved && linalg.length(a.mouse - st.from) > t.slop do st.moved = true
		if st.moved do place(app, pick, at)
	}
	if a.clicked && !st.moved {
		if st.hit >= 0 {
			if st.was_picked {
				light_flip(app, pick)
				st.flips += 1
			}
		} else if linalg.length(at) <= 1 {
			place(app, pick, at)
		}
	}
}

// The light whose marker is nearest `p` within `reach` points, among those that are on;
// -1 for none.
light_sphere_hit :: proc(app: ^App, centre: [2]f32, radius: f32, p: [2]f32, reach: f32) -> int {
	best, at := reach, -1
	for light, i in app.lights {
		if !light.on do continue
		if d := linalg.length(light_marker(app, i, centre, radius) - p); d <= best do best, at = d, i
	}
	return at
}

// Where light `i`'s marker sits on the sphere drawn at `centre`: its direction as the
// camera sees it, so one behind the model shows at the same place as its mirror in front.
light_marker :: proc(app: ^App, i: int, centre: [2]f32, radius: f32) -> [2]f32 {
	d := light_view_dir(app, i)
	return centre + [2]f32{d.x, -d.y} * radius
}

@(private = "file")
light_sphere_draw :: proc(app: ^App, centre: [2]f32, radius: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	if radius <= 4 do return
	// The ball, lit on the CPU at its mesh's points: a grey clay with the ambient light and
	// each light that is on, so the preview shows what the lights do to a form.
	COUNT :: 1 + SPHERE_RINGS * SPHERE_SEGMENTS
	points: [COUNT][2]f32
	colors: [COUNT]ui.Color
	indices: [(SPHERE_SEGMENTS + (SPHERE_RINGS - 1) * SPHERE_SEGMENTS * 2) * 3]u32
	view: [LIGHT_COUNT][3]f32
	for &d, i in view do d = light_view_dir(app, i)
	shade :: proc(app: ^App, view: [LIGHT_COUNT][3]f32, at: [2]f32) -> ui.Color {
		n := [3]f32{at.x, at.y, math.sqrt(max(1 - at.x * at.x - at.y * at.y, 0))}
		c := [3]f32{0.12, 0.12, 0.12} * app.light_ambient
		for light, i in app.lights {
			if !light.on do continue
			c += light.color * (light.strength * 0.7 * max(linalg.dot(n, view[i]), 0))
		}
		c *= 0.8
		return {u8(srgb_encode(c.r) * 255 + 0.5), u8(srgb_encode(c.g) * 255 + 0.5), u8(srgb_encode(c.b) * 255 + 0.5), 255}
	}
	points[0], colors[0] = centre, shade(app, view, {})
	for ring in 1 ..= SPHERE_RINGS {
		// Rings crowd toward the outline, where the shading turns fastest.
		r := math.sin(f32(ring) / SPHERE_RINGS * math.PI * 0.5)
		for s in 0 ..< SPHERE_SEGMENTS {
			angle := f32(s) / SPHERE_SEGMENTS * 2 * math.PI
			at := [2]f32{math.cos(angle), math.sin(angle)} * r
			i := 1 + (ring - 1) * SPHERE_SEGMENTS + s
			points[i] = centre + [2]f32{at.x, -at.y} * radius
			colors[i] = shade(app, view, at)
		}
	}
	n := 0
	for s in 0 ..< SPHERE_SEGMENTS {
		indices[n], indices[n + 1], indices[n + 2] = 0, u32(1 + s), u32(1 + (s + 1) % SPHERE_SEGMENTS)
		n += 3
	}
	for ring in 1 ..< SPHERE_RINGS {
		inner, outer := 1 + (ring - 1) * SPHERE_SEGMENTS, 1 + ring * SPHERE_SEGMENTS
		for s in 0 ..< SPHERE_SEGMENTS {
			s1 := (s + 1) % SPHERE_SEGMENTS
			a, b, c, d := u32(inner + s), u32(inner + s1), u32(outer + s), u32(outer + s1)
			indices[n], indices[n + 1], indices[n + 2] = a, c, d
			indices[n + 3], indices[n + 4], indices[n + 5] = a, d, b
			n += 6
		}
	}
	ui.fill_mesh(ctx, points[:], colors[:], indices[:n])
	ui.stroke_circle(ctx, centre, radius, t.border_strong, 1)

	// The markers, those behind first so the ones in front cover them.
	for front in ([2]bool{false, true}) {
		for light, i in app.lights {
			if !light.on || (view[i].z >= 0) != front do continue
			p := light_marker(app, i, centre, radius)
			shown := light.color
			for &c in shown do c = srgb_encode(min(c, 1))
			col := ui.Color{u8(shown.r * 255 + 0.5), u8(shown.g * 255 + 0.5), u8(shown.b * 255 + 0.5), 255}
			if front {
				ui.fill_circle(ctx, p, 9, col)
				ui.stroke_circle(ctx, p, 9, t.shadow, 1.5)
			} else {
				ui.fill_circle(ctx, p, 9, {0, 0, 0, 110})
				ui.stroke_circle(ctx, p, 8, col, 2)
			}
			ink := ui.Color{20, 20, 22, 255} if front && shown.r + shown.g + shown.b > 1.5 else ui.Color{240, 240, 240, 255}
			ui.text(ctx, fmt.tprintf("%d", i + 1), p.x, p.y, t.caption_size, ink, .Semibold, .Center)
			if i == app.light_pick do ui.stroke_circle(ctx, p, 13, t.accent, 2)
		}
	}
}
