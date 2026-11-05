package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:strings"

import "../ui"
import "../geom"

// The Lights card, the one Lights interface (the Lights card, the view
// rail and the Shading menu open it): the light sphere; each light a row with its
// colour, name, kind, temperature and intensity and its eye, as Marmoset's and Blender's
// light lists; Add a light of each kind and Lights follow the camera; the picked light's
// kind, strength, colour, size and spot cone; presets for whole rigs; and under More
// options its highlight, shadows, name, what it moves with, and the ambient light and the
// turn of the whole set (lights.odin).

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

// The icon of each kind of light: a sun, a bulb, a lamp hanging from the ceiling and a
// frame for a softbox's face.
@(rodata)
LIGHT_KIND_ICONS := [Light_Kind]rune {
	.Sun   = ui.ICON_SUN,
	.Point = ICON_LIGHTBULB,
	.Spot  = ICON_LAMP_CEILING,
	.Area  = ui.ICON_FRAME,
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
	typed: ui.Id
	defer {
		lights_settle(app)
		if set^ != before do light_drag_changed(app, before, what, typed)
	}
	app.light_pick = clamp(app.light_pick, 0, max(int(set.count) - 1, 0))
	kit_light_sphere(app)
	for &l, i in set.lights[:set.count] do light_row(app, &l, i)
	// Add, then one button a kind sharing the rest of the width, each showing the kind's
	// icon and name.
	add_w := ui.text_width(ctx, "Add", ctx.theme.text_size)
	kinds :: f32(len(Light_Kind))
	each := (ui.fill_width(ctx) - add_w - kinds * 8) / kinds
	ui.begin(ctx, "light add", {direction = .Row, gap = ui.SPACE_M, center = true})
	ui.label(ctx, "Add")
	for kind in Light_Kind {
		label := fmt.tprintf("%s##add %s light", LIGHT_KIND_LABELS[kind], strings.to_lower(LIGHT_KIND_LABELS[kind], context.temp_allocator))
		if ui.button(ctx, label, .Bordered, width = each, glyph = LIGHT_KIND_ICONS[kind], enabled = set.count < LIGHT_COUNT) {
			_ = light_add(app, kind)
			what = "Add light"
		}
	}
	ui.end(ctx)
	// The lights stay with the camera, so the model is lit the same way as it turns, or
	// with the scene, as on a turntable: every light at once, kept where it is on screen.
	follow := !lights_fixed(app)
	if ui.switch_row(ctx, "Lights follow the camera", &follow) do lights_fix(app, !follow)
	if set.count <= 0 {
		_ = ui.slider(ctx, "Ambient", &set.ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", set.ambient))
		ui.paragraph(ctx, "The scene has no lights: its ambient light and the environment light it.")
		return
	}
	light := &set.lights[app.light_pick]
	// The picked light's own settings show whole, its kind, strength, colour and size, so
	// the card reads as a lamp's: More keeps its name, what it moves with and the set's.
	// Under its name, so its kind's tabs never read as more of the Add buttons above.
	ui.caption(ctx, strings.to_upper(light_name(set, app.light_pick), context.temp_allocator))
	if kind := ui.tabs(ctx, "light kind", LIGHT_KIND_LABELS[:], int(light.kind)); kind >= 0 do light.kind = Light_Kind(kind)
	_ = ui.slider(ctx, "Intensity", &light.strength, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", light.strength))
	// The colour it shines in: picked, or a colour temperature, as a lamp is bought.
	shown := light_rgb(light^)
	if kit_color(app, fmt.tprintf("light %d colour", app.light_pick + 1), &shown, linear = true) do light.color, light.kelvin = shown, 0
	warm := light.kelvin > 0
	if ui.switch_row(ctx, "Colour temperature", &warm) do light.kelvin = 6500 if warm else 0
	if light.kelvin > 0 do _ = ui.slider(ctx, "Temperature", &light.kelvin, LIGHT_KELVIN_MIN, LIGHT_KELVIN_MAX, .Logarithmic, fmt.tprintf("%.0f K", light.kelvin))
	// Its size, which broadens and softens its highlights: a sun's angle in the sky, a
	// lamp's radius, its slider reaching half the camera's distance or the radius set.
	if light.kind == .Sun {
		_ = ui.slider(ctx, "Angle", &light.angle, 0, LIGHT_ANGLE_MAX, .Linear, fmt.tprintf("%.1f°", light.angle))
	} else if light.kind == .Area {
		// A softbox's face: a rectangle's width and height or a disc's diameter, the
		// sliders reaching the camera's distance or the size set.
		if v := ui.tabs(ctx, "area shape", {"Rectangle", "Disc"}, 1 if light.disc else 0); v >= 0 do light.disc = v == 1
		widest := clamp(max(light.width, light.height, app.camera.distance), 1e-3, LIGHT_RADIUS_MAX)
		_ = ui.slider(ctx, "Diameter" if light.disc else "Width", &light.width, LIGHT_AREA_MIN, widest, .Logarithmic, fmt.tprintf("%.2f", light.width))
		if !light.disc do _ = ui.slider(ctx, "Height", &light.height, LIGHT_AREA_MIN, widest, .Logarithmic, fmt.tprintf("%.2f", light.height))
	} else {
		widest := clamp(max(light.radius, app.camera.distance * 0.5), 1e-3, LIGHT_RADIUS_MAX)
		_ = ui.slider(ctx, "Radius", &light.radius, 0, widest, .Linear, fmt.tprintf("%.2f", light.radius))
	}
	if light.kind == .Spot {
		_ = ui.slider(ctx, "Cone", &light.cone, LIGHT_CONE_MIN, LIGHT_CONE_MAX, .Linear, fmt.tprintf("%.0f°", light.cone))
		_ = ui.slider(ctx, "Soft edge", &light.blend, 0, 1, .Linear, fmt.tprintf("%.0f%%", light.blend * 100))
	}
	if light.kind != .Sun && light.pos != {} {
		// How far it stands from the orbit's centre, the depth a marker's drag keeps.
		far := light_center_distance(app, app.light_pick)
		near_end, far_end := app.camera.distance * LIGHT_DISTANCE_MIN, app.camera.distance * LIGHT_DISTANCE_MAX
		moved := clamp(far, near_end, far_end)
		if ui.slider(ctx, "Distance", &moved, near_end, far_end, .Logarithmic, fmt.tprintf("%.2f", far)) do light_set_center_distance(app, app.light_pick, moved)
	}
	_ = ui.switch_row(ctx, "Place highlight", &app.ui.light_place, keys = command_hint(app, .Place_Light))
	// A spot turned to shine at the selected object's middle, where it stands, as
	// Marmoset's aim and a theatre's follow spot.
	if (light.kind == .Spot || light.kind == .Area) && light.pos != {} {
		if ui.button(ctx, "Aim at the selected object", .Bordered, glyph = LIGHT_KIND_ICONS[light.kind], enabled = selected_object(app) != nil) {
			if light_aim_at_selected(app, app.light_pick) do what = "Aim light"
		}
	}
	if kit_more(app, .Lights) {
		// Under More options, as the section shows five controls before them: how much shine
		// the light gives, as a lamp's specular in Blender (none makes a fill that lights the
		// forms without a highlight), and whether it casts the studio's and render mode's
		// shadows.
		highlight := light.shine + 1
		if ui.slider(ctx, "Highlight", &highlight, 0, 2, .Linear, fmt.tprintf("%.0f%%", highlight * 100)) do light.shine = highlight - 1
		shadows := !light.no_shadows
		if ui.switch_row(ctx, "Shadows", &shadows) do light.no_shadows = !shadows
		// Its name, typed: the typing is one undo step until the field lets the keys go.
		name_field := fmt.tprintf("name##light %d", app.light_pick + 1)
		if ui.text_field(ctx, name_field, light.name[:LIGHT_NAME - 1], hint = fmt.tprintf("Light %d", app.light_pick + 1)) {
			what = "Rename light"
			typed = ui.id_of(ctx, name_field)
		}
		ui.label(ctx, "Moves with")
		if space := ui.tabs(ctx, "light space", LIGHT_SPACE_LABELS[:], int(light.space)); space >= 0 do light_set_space(app, app.light_pick, Light_Space(space))
		if ui.button(ctx, fmt.tprintf("Delete %s##delete light", light_name(set, app.light_pick)), .Bordered, .Danger, glyph = ui.ICON_TRASH) {
			light_delete(app, app.light_pick)
			what = "Delete light"
		}
		// Then what holds for every light.
		_ = ui.slider(ctx, "Ambient", &set.ambient, 0, LIGHT_STRENGTH_MAX, .Linear, fmt.tprintf("%.2f", set.ambient))
		_ = ui.slider(ctx, "Turn all", &app.light_turn, -180, 180, .Linear, fmt.tprintf("%+.0f°", app.light_turn))
		_ = ui.slider(ctx, "Height all", &app.light_height, -90, 90, .Linear, fmt.tprintf("%+.0f°", app.light_height))
		if ui.button(ctx, "Use as starting lights", .Bordered) {
			app.start_lights = set^
			report(app, Section.Lights, {}, "New scenes start with these lights")
		}
		if ui.button(ctx, "Reset lights", .Bordered) do set^ = LIGHTS_DEFAULT
		// Whole rigs at once, as KeyShot's and Marmoset's presets: each replaces the lights.
		ui.label(ctx, "Presets")
		// Two a row, so each name has room on a narrow card.
		half := (ui.fill_width(ctx) - 8) * 0.5
		for row in 0 ..< (len(Light_Preset) + 1) / 2 {
			ui.begin(ctx, fmt.tprintf("light presets %d", row), {direction = .Row, gap = ui.SPACE_M})
			for i in row * 2 ..< min(row * 2 + 2, len(Light_Preset)) {
				p := Light_Preset(i)
				if ui.button(ctx, fmt.tprintf("%s##light preset", LIGHT_PRESET_NAMES[p]), .Bordered, width = half) {
					light_preset_apply(app, p)
					what = "Light preset"
				}
			}
			ui.end(ctx)
		}
		kit_more_end(app)
	}
	ui.paragraph(ctx, "Drag on the sphere, or a light's marker in the view, to move it; tap the picked light on the sphere to send it behind the model or bring it back. With Place highlight on, touch the model where the picked light's highlight should be. A sun shines from a direction; a point light and a spot shine from where they are, brighter close up. A light moving with the camera keeps lighting the model the same way while it turns; one in the scene stays put, as on a turntable. The lights are saved with the scene. MatCaps carry their own light.")
}

// A light's row: its colour as a dot (faint while it is off), its name, and its kind,
// temperature and intensity, the picked one tinted; a tap picks it, its eye switches it on
// or off.
@(private = "file")
light_row :: proc(app: ^App, l: ^Light, i: int) {
	ctx := &app.kit.ctx
	t := ctx.theme
	set := &app.scene.lights
	picked := i == app.light_pick
	width := ui.fill_width(ctx)
	name := fmt.tprintf("lens light %d", i)
	if picked {
		if r := ui.prev_rect(ctx, name); r.w > 0 do ui.fill_rect(ctx, r, t.radius_medium, ui.color_fade(t.accent, 0.16))
	}
	ui.begin(ctx, name, {direction = .Row, center = true, gap = 0, width = width, height = LIGHT_ROW_H})
	a := ui.area(ctx, fmt.tprintf("%s##lens light pick %d", light_name(set, i), i), {width - t.target, LIGHT_ROW_H})
	mid := a.rect.y + a.rect.h * 0.5
	if a.hovered && !picked do ui.fill_rect(ctx, a.rect, t.radius_small, t.fill_hover)
	rgb := light_rgb(l^)
	dot := ui.Color{u8(geom.srgb_encode(min(rgb.r, 1)) * 255 + 0.5), u8(geom.srgb_encode(min(rgb.g, 1)) * 255 + 0.5), u8(geom.srgb_encode(min(rgb.b, 1)) * 255 + 0.5), 255}
	ui.fill_circle(ctx, {a.rect.x + 14, mid}, LIGHT_DOT, dot if l.on else ui.color_fade(dot, 0.35))
	fg := t.text if l.on else t.text_secondary
	line := fmt.tprintf("%s · %s", LIGHT_KIND_LABELS[l.kind], light_line(l^))
	line_w := ui.text_width(ctx, line, t.small_size)
	ui.text(ctx, ui.text_fit(ctx, light_name(set, i), t.text_size, a.rect.w - line_w - 44, .Semibold if picked else .Regular), a.rect.x + 30, mid, t.text_size, fg, .Semibold if picked else .Regular)
	ui.text(ctx, line, a.rect.x + a.rect.w - 6, mid, t.small_size, t.text_tertiary, .Regular, .Right)
	if a.clicked do app.light_pick = i
	if ui.icon_button(ctx, fmt.tprintf("%s##light eye %d", "Switch off" if l.on else "Switch on", i), ui.ICON_EYE if l.on else ui.ICON_EYE_OFF, size = t.target) do l.on = !l.on
	ui.end(ctx)
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
			c += light_rgb(light) * (light.strength * 0.7 * max(linalg.dot(n, view[i]), 0))
		}
		c *= 0.8
		return {u8(geom.srgb_encode(c.r) * 255 + 0.5), u8(geom.srgb_encode(c.g) * 255 + 0.5), u8(geom.srgb_encode(c.b) * 255 + 0.5), 255}
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
			shown := light_rgb(light)
			for &c in shown do c = geom.srgb_encode(min(c, 1))
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
