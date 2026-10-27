package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"

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

// The icon of each kind of light: a sun, a bulb and a lamp hanging from the ceiling.
@(rodata)
LIGHT_KIND_ICONS := [Light_Kind]rune {
	.Sun   = ui.ICON_SUN,
	.Point = ICON_LIGHTBULB,
	.Spot  = ICON_LAMP_CEILING,
}
ICON_LIGHTBULB :: rune(0xe1c2)
ICON_LAMP_CEILING :: rune(0xe2d9)

kit_lights :: proc(app: ^App) {
	ctx := &app.kit.ctx
	set := &app.scene.lights
	// Everything changed here, from a press to its release, is one undo step, named by
	// what made it.
	before := set^
	what := "Lights"
	defer {
		lights_settle(app)
		if set^ != before do light_drag_changed(app, before, what)
	}
	app.light_pick = clamp(app.light_pick, 0, max(int(set.count) - 1, 0))
	kit_light_sphere(app)
	// The list: each light's kind, name and what it moves with, its eye switching it on or
	// off, as the Scene palette lists objects.
	for &l, i in set.lights[:set.count] {
		toggles := [1]ui.Row_Toggle{{name = "Switch off" if l.on else "Switch on", glyph = ui.ICON_EYE if l.on else ui.ICON_EYE_OFF, faint = !l.on}}
		detail := fmt.tprintf("%s, %s", LIGHT_KIND_LABELS[l.kind], "in the scene" if l.space == .Scene else "with the camera")
		row := ui.tree_row(ctx, fmt.tprintf("%s##light row %d", light_name(i), i), detail, i == app.light_pick, all_toggles = toggles[:], glyph = LIGHT_KIND_ICONS[l.kind], dim = !l.on)
		if row.toggled == 0 do l.on = !l.on
		else if row.clicked do app.light_pick = i
	}
	// Add, then one button a kind sharing the rest of the width, each showing the kind's
	// icon and name.
	add_w := ui.text_width(ctx, "Add", ctx.theme.text_size)
	each := (ui.fill_width(ctx) - add_w - 3 * 8) / 3
	ui.begin(ctx, "light add", {direction = .Row, gap = 8, center = true})
	ui.label(ctx, "Add")
	for kind in Light_Kind {
		label := fmt.tprintf("%s##add %s light", LIGHT_KIND_LABELS[kind], strings.to_lower(LIGHT_KIND_LABELS[kind], context.temp_allocator))
		if ui.button(ctx, label, .Bordered, width = each, glyph = LIGHT_KIND_ICONS[kind], enabled = set.count < LIGHT_COUNT) {
			_ = light_add(app, kind)
			what = "Add light"
		}
	}
	ui.end(ctx)
	if set.count <= 0 {
		_ = ui.slider(ctx, "Ambient", &set.ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", set.ambient))
		ui.paragraph(ctx, "The scene has no lights: its ambient light and the environment light it.")
		return
	}
	light := &set.lights[app.light_pick]
	_ = ui.slider(ctx, "Intensity", &light.strength, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", light.strength))
	_ = ui.slider(ctx, "Ambient", &set.ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", set.ambient))
	if kit_more(app, .Lights) {
		_ = kit_color(app, fmt.tprintf("light %d colour", app.light_pick + 1), &light.color, linear = true)
		if kind := ui.tabs(ctx, "light kind", LIGHT_KIND_LABELS[:], int(light.kind)); kind >= 0 do light.kind = Light_Kind(kind)
		if light.kind == .Spot {
			_ = ui.slider(ctx, "Cone", &light.cone, LIGHT_CONE_MIN, LIGHT_CONE_MAX, .Linear, fmt.tprintf("%.0f°", light.cone))
			_ = ui.slider(ctx, "Soft edge", &light.blend, 0, 1, .Linear, fmt.tprintf("%.0f%%", light.blend * 100))
		}
		ui.label(ctx, "Moves with")
		if space := ui.tabs(ctx, "light space", LIGHT_SPACE_LABELS[:], int(light.space)); space >= 0 do light_set_space(app, app.light_pick, Light_Space(space))
		if ui.button(ctx, fmt.tprintf("Delete %s", light_name(app.light_pick)), .Bordered, .Danger, glyph = ui.ICON_TRASH) {
			light_delete(app, app.light_pick)
			what = "Delete light"
		}
		fixed := lights_fixed(app)
		if ui.switch_row(ctx, "All fixed to the scene", &fixed) do lights_fix(app, fixed)
		_ = ui.slider(ctx, "Turn all", &app.light_turn, -180, 180, .Linear, fmt.tprintf("%+.0f°", app.light_turn))
		_ = ui.slider(ctx, "Height all", &app.light_height, -90, 90, .Linear, fmt.tprintf("%+.0f°", app.light_height))
		if ui.button(ctx, "Use as starting lights", .Bordered) {
			app.start_lights = set^
			report(app, Kit_Section.Lights, {}, "New scenes start with these lights")
		}
		if ui.button(ctx, "Reset lights", .Bordered) do set^ = LIGHTS_DEFAULT
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Drag on the sphere to move the picked light; tap it to send it behind the model or bring it back. A sun shines from a direction; a point light and a spot shine from where they are, brighter close up. A light moving with the camera keeps lighting the model the same way while it turns; one in the scene stays put, as on a turntable. The lights are saved with the scene. MatCaps carry their own light.")
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
	if app.scene.lights.count <= 0 do return

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
		app.scene.lights.lights[i].on = true
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
	set := &app.scene.lights
	for light, i in set.lights[:set.count] {
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
	set := &app.scene.lights
	view: [LIGHT_COUNT][3]f32
	for &d, i in view[:set.count] do d = light_view_dir(app, i)
	shade :: proc(app: ^App, view: [LIGHT_COUNT][3]f32, at: [2]f32) -> ui.Color {
		n := [3]f32{at.x, at.y, math.sqrt(max(1 - at.x * at.x - at.y * at.y, 0))}
		set := &app.scene.lights
		c := [3]f32{0.12, 0.12, 0.12} * set.ambient
		for light, i in set.lights[:set.count] {
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
		for light, i in set.lights[:set.count] {
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
