package main

import "core:fmt"
import "core:strings"

import "../ui"

// Lens's Material card (panels P4, round 3's Materials mock): Materials, Matcaps and
// Environment as tabs of one card, as the look cards are kept together. Matcaps and
// Materials are grids of real spheres, four across and big enough for a finger: a MatCap
// shows its own picture (ui.image_disc over the texture it shades with), a lit material
// a ball in its colour. A press on a sphere and a slide over the others shows each on the
// objects as the finger passes, as Nomad's material scrub does; lifting keeps the one under
// the finger, sliding off the grid puts back what the objects had (Material_Preview). Under
// the grid, Apply to says which objects take it: the selected ones, the selected one's
// folder, or every object. Matcaps has Import (Load MatCap) by its head; Materials has
// Roughness for a lit material; Environment is the Environment section.

// Materials first: the Render workspace, where the card shows, lights its objects.
Material_Tab :: enum u8 {
	Materials,
	Matcaps,
	Environment,
}

@(rodata)
MATERIAL_TAB_NAMES := [Material_Tab]string {
	.Materials   = "Materials",
	.Matcaps     = "Matcaps",
	.Environment = "Environment",
}

// Spheres a row of the grid holds, the gap between them, and the room under each for its
// name, in points.
MATERIAL_ACROSS :: 4
MATERIAL_GAP :: 8
MATERIAL_LABEL_H :: 18

// KIT_MATCAP_IMAGE + a Material.matcap value is that MatCap's picture, for kit_draws.
KIT_MATCAP_IMAGE :: KIT_LAYER_PICTURES_IMAGE + 1
KIT_MATCAP_IMAGE_END :: KIT_MATCAP_IMAGE + 2 * PACK_MATCAP

// What the card keeps between frames: its tab, whether a press on a sphere is under way,
// and the sphere it shows (its index + 1 in this frame's list; 0 for none).
Material_Card :: struct {
	tab:      Material_Tab,
	pressing: bool,
	shown:    int,
	label:    string, // what the shown sphere is called, for the line under the grid (not owned)
}

// One sphere of a grid: the material it puts on and its name.
@(private = "file")
Material_Ball :: struct {
	material: Material,
	label:    string,
}

// The card's content.
kit_lens_material :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	mc := &k.material_card
	width := ui.fill_width(ctx)
	tabs: [len(Material_Tab)]string
	for name, i in MATERIAL_TAB_NAMES do tabs[i] = name
	if picked := ui.tabs(ctx, "material card tabs", tabs[:], int(mc.tab)); picked >= 0 {
		if mc.pressing do material_scrub_end(app, false)
		mc.tab = Material_Tab(picked)
	}
	if mc.tab == .Environment {
		kit_environment(app)
		return
	}
	sel := selected_object(app)
	m := object_material(app, sel) if sel != nil else current_material(app)
	balls := material_balls(app, mc.tab)
	if mc.tab == .Matcaps {
		ui.begin(ctx, "material card matcaps head", {direction = .Row, gap = 6, center = true, width = width})
		ui.label(ctx, fmt.tprintf("%d MatCaps", len(balls)), t.small_size, t.text_secondary)
		ui.spacer(ctx, ui.row_room(ctx) - 100 - 6)
		if ui.button(ctx, "Import##material card", .Bordered, glyph = ui.ICON_IMAGE, width = 100) do file_dialog(app, .Matcap)
		ui.end(ctx)
	}
	material_grid(app, balls, m, width)
	if mc.pressing {
		ui.label(ctx, fmt.tprintf("Previewing %s: lift to keep it, slide off to go back", mc.label) if mc.shown != 0 else "Slide back onto a sphere, or lift to keep what was there", t.small_size, t.text_secondary)
	}
	// Roughness edits a lit material in use, which makes it Custom, as the section's
	// sliders do; a MatCap's picture holds its sheen, so it has none.
	if mc.tab == .Materials && m.matcap == 0 {
		if m.roughness == 0 do m.roughness = CUSTOM_ROUGHNESS
		if ui.slider(ctx, "Roughness##lens material", &m.roughness, 0.04, 1, .Linear, fmt.tprintf("%.2f", m.roughness)) {
			m.label = "Custom"
			app.ui.scene_command = {kind = .Material, material = m, material_to = app.ui.material_to}
		}
	}
	ui.label(ctx, "Apply to", t.small_size, t.text_tertiary)
	targets := [len(Material_Target)]string{"Selected", "Its folder", "Every object"}
	if picked := ui.tabs(ctx, "material apply to", targets[:], int(app.ui.material_to)); picked >= 0 do app.ui.material_to = Material_Target(picked)
}

// The spheres a tab shows: the built-in MatCaps, the loaded image and every content pack's
// (Matcaps); the lit presets, Custom and the content packs' materials (Materials).
@(private = "file")
material_balls :: proc(app: ^App, tab: Material_Tab) -> []Material_Ball {
	out := make([dynamic]Material_Ball, context.temp_allocator)
	if tab == .Matcaps {
		for i in FIRST_MATCAP ..< len(MATERIALS) {
			append(&out, Material_Ball{MATERIALS[i], strings.trim_suffix(string(MATERIALS[i].label), " MatCap")})
		}
		if app.matcap_image != nil do append(&out, Material_Ball{{label = "Custom", selected = {1, 1, 1, 1}, idle = MATCAP_IDLE, matcap = MATCAP_IMAGE}, "Imported"})
		for pm, k in app.library.matcaps {
			if pm.gone || pm.failed do continue
			append(&out, Material_Ball{{label = "Custom", selected = {1, 1, 1, 1}, idle = MATCAP_IDLE, matcap = PACK_MATCAP + k}, pm.stem})
		}
		// The packs' pictures are made when first shown (pack_matcaps_settle).
		app.library.matcaps_wanted = true
		return out[:]
	}
	for i in 0 ..< FIRST_MATCAP do append(&out, Material_Ball{MATERIALS[i], string(MATERIALS[i].label)})
	if app.custom.label != nil && app.custom.matcap == 0 do append(&out, Material_Ball{app.custom, "Custom"})
	for pm in app.library.materials {
		if pm.gone do continue
		append(&out, Material_Ball{pm.material, pm.name})
	}
	return out[:]
}

// Whether ball `b` is the material `m` in use.
@(private = "file")
material_ball_on :: proc(b: Material_Ball, m: Material) -> bool {
	if b.material.matcap != 0 || m.matcap != 0 {
		return b.material.matcap == m.matcap && b.material.pack == m.pack
	}
	if m.pack > 0 || b.material.pack > 0 do return m.pack == b.material.pack
	return material_index(m) == material_index(b.material)
}

// The grid of `balls`, the one in use (`m`) ringed, with the scrub: see the file's head.
@(private = "file")
material_grid :: proc(app: ^App, balls: []Material_Ball, m: Material, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	mc := &k.material_card
	side := (width - MATERIAL_GAP * (MATERIAL_ACROSS - 1)) / MATERIAL_ACROSS
	rects := make([]ui.Rect, len(balls), context.temp_allocator)
	held := false
	for first := 0; first < len(balls); first += MATERIAL_ACROSS {
		ui.begin(ctx, fmt.tprintf("material card %v row %d", mc.tab, first), {direction = .Row, gap = MATERIAL_GAP})
		for n in first ..< min(first + MATERIAL_ACROSS, len(balls)) {
			b := balls[n]
			a := ui.area(ctx, fmt.tprintf("%s##material card %v %d", b.label, mc.tab, n), {side, side + MATERIAL_LABEL_H})
			rects[n] = a.rect
			held ||= a.held
			r := side * 0.5 - 5
			c := [2]f32{a.rect.x + side * 0.5, a.rect.y + side * 0.5}
			on := material_ball_on(b, m)
			if a.hovered && ctx.input.pointer != .Finger && !on do ui.stroke_circle(ctx, c, r + 2.5, ui.color_fade(t.text_tertiary, 0.6), 1)
			if b.material.matcap != 0 {
				ui.fill_circle(ctx, c, r, t.fill)
				ui.image_disc(ctx, c, r, KIT_MATCAP_IMAGE + u64(b.material.matcap), material_swatch(b.material))
			} else {
				ui.fill_ball(ctx, c, r, material_swatch(b.material))
			}
			if on do ui.stroke_circle(ctx, c, r + 3, t.accent, 2)
			name := ui.text_fit(ctx, b.label, t.caption_size, side)
			ui.text(ctx, name, c.x, a.rect.y + side + MATERIAL_LABEL_H * 0.5 - 2, t.caption_size, t.accent if on else t.text_secondary, .Regular, .Center)
			ui.tip(ctx, a.id, a.rect, b.label)
		}
		ui.end(ctx)
	}
	if held {
		// The sphere under the finger now, wherever the press began.
		under := 0
		for r, n in rects do if ui.rect_contains(r, ctx.input.mouse) do under = n + 1
		mc.pressing = true
		if under != mc.shown {
			if under != 0 {
				mc.label = balls[under - 1].label
				app.ui.scene_command = {kind = .Material, material = balls[under - 1].material, material_to = app.ui.material_to, preview = .Show}
			} else {
				app.ui.scene_command = {kind = .Material, material_to = app.ui.material_to, preview = .Back}
			}
			mc.shown = under
		}
	} else if mc.pressing {
		material_scrub_end(app, true)
	}
}

// Ends a scrub: keeps the material shown (`keep`, and one is shown), or puts back what
// the objects had.
material_scrub_end :: proc(app: ^App, keep: bool) {
	mc := &app.kit.material_card
	mc.pressing = false
	preview := Material_Preview.Keep if keep && mc.shown != 0 else .Back
	mc.shown = 0
	app.ui.scene_command = {kind = .Material, material_to = app.ui.material_to, preview = preview}
}
