package main

import "core:fmt"
import "core:strings"

import "../geom"
import "../ui"

// The Material card (direction A of the materials design, "Shelf", after Substance's
// shelf): the one place a material is picked or changed. On top, what the selected object
// wears, as a big sphere with its name and values, and Edit. Under it the shelf: chips for
// Favourites and each category (Clay, Metal, Glossy, Glass, Skin & wax, Fabric, Glow), which
// a material falls into by its own values (material_category; Clay is shown as Matte,
// so the word does not also name the Clay material and the Clay look), so the presets, Custom and
// the content packs' materials all sort themselves; then the chosen category's spheres,
// four across and big enough for a finger. A press on a sphere and a slide over the others
// shows each on the objects as the finger passes, as Nomad's material scrub does; lifting
// keeps the one under the finger, sliding off the grid puts back what the objects had
// (Material_Preview). Apply to says which objects take it. Edit swaps the shelf for the
// material's values: Surface (colour, Roughness, Metallic) and each layer of OpenPBR's,
// as Blender's Principled panels show them, a switch that opens its few controls when on
// (Subsurface, Coat, Sheen, Transmission, Glow; Thin film and the specular under More).
// Any change makes the material Custom, so a preset is never changed; Reset puts back
// what the objects had when Edit opened. With polygroups, Object or Group over it
// (kit_group_material). MatCaps are no material: they are the Clay look's light, picked
// in the shading list (shading_options). Holding a sphere (a long press, a right click or
// the pen's side button) adds it to the favourites or takes it off, a star on its corner;
// settings.txt keeps them (material_favorite).

// The shelf's categories, in the order its chips show them.
Material_Category :: enum u8 {
	Favourites,
	Clay,
	Metal,
	Glossy,
	Glass,
	Skin,
	Fabric,
	Glow,
}

@(rodata)
MATERIAL_CATEGORY_NAMES := [Material_Category]string {
	.Favourites = "Favourites",
	.Clay       = "Matte",
	.Metal      = "Metal",
	.Glossy     = "Glossy",
	.Glass      = "Glass",
	.Skin       = "Skin & wax",
	.Fabric     = "Fabric",
	.Glow       = "Glow",
}

// The category material `m` falls into, by what shows most: light it gives off, light
// through it, light under its surface, cloth's sheen, a clear coat, metal; then a classic
// material whose light wraps past the shadow line (wax, skin) as Skin & wax, and the rest
// Clay when rough or classic, Glossy when smooth.
material_category :: proc(m: Material) -> Material_Category {
	l := m.layers
	switch {
	case l.emission_luminance > 0:                         return .Glow
	case l.transmission_weight > 0:                        return .Glass
	case l.subsurface_weight > 0:                          return .Skin
	case l.sheen_weight > 0:                               return .Fabric
	case l.coat_weight > 0:                                return .Glossy
	case m.metallic >= 0.5:                                return .Metal
	case m.roughness == 0 && m.shading.w >= SKIN_WRAP:     return .Skin
	case m.roughness == 0 || m.roughness >= CLAY_ROUGHNESS: return .Clay
	}
	return .Glossy
}

// A classic material's wrap from which its light reads as passing under the surface, and
// the roughness from which a lit material reads as clay rather than glossy.
SKIN_WRAP :: 0.3
CLAY_ROUGHNESS :: 0.5

// Spheres a row of the grid holds, the gap between them, and the room under each for its
// name, in points.
MATERIAL_ACROSS :: 4
MATERIAL_GAP :: 8
MATERIAL_LABEL_H :: 18
// How many spheres the favourites hold.
MATERIAL_FAVORITES :: 32

// KIT_MATCAP_IMAGE + a Material.matcap value is that MatCap's picture, for kit_draws.
KIT_MATCAP_IMAGE :: KIT_LAYER_PICTURES_IMAGE + 1
KIT_MATCAP_IMAGE_END :: KIT_MATCAP_IMAGE + 2 * PACK_MATCAP

// What the card keeps between frames: whether a press on a sphere is under way,
// and the sphere it shows (its index + 1 in this frame's list; 0 for none).
Material_Card :: struct {
	pressing: bool,
	shown:    int,
	label:    string, // what the shown sphere is called, for the line under the grid (not owned)
	// The favourite spheres by material_ball_key, in the order added, and whether the grid
	// shows only them.
	favorites:      [MATERIAL_FAVORITES]Brush_Key,
	favorite_count: int,
	// The category the shelf shows, its value + 1 (0 until the card first shows, which then
	// opens on the category of the material in use); whether Edit is open, and what the
	// objects wore when it opened, for Reset.
	category: int,
	editing:  bool,
	before:   Material,
	favorite_changes: int, // for the exit stats
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
	sel := selected_object(app)
	// With polygroups the card sets the object's material or one group's.
	if sel != nil && command_enabled(app, .Pick_Group, 0) {
		targets := [2]string{"Object", "Group"}
		if picked := ui.tabs(ctx, "material target", targets[:], int(app.ui.material_groups)); picked >= 0 do app.ui.material_groups = picked == 1
		if app.ui.material_groups {
			kit_group_material(app, sel)
			return
		}
	}
	m := object_material(app, sel) if sel != nil else current_material(app)
	if mc.category == 0 do mc.category = int(material_category(m)) + 1
	material_preview_row(app, m, sel, width)
	if mc.editing {
		material_edit(app, m)
		return
	}
	material_chips(app, width)
	balls := material_balls(app)
	shown := make([dynamic]Material_Ball, 0, len(balls), context.temp_allocator)
	category := Material_Category(mc.category - 1)
	for b in balls {
		in_it := material_favorite(mc, material_ball_key(app, b)) >= 0 if category == .Favourites else material_category(b.material) == category
		if in_it do append(&shown, b)
	}
	if len(shown) == 0 do ui.paragraph(ctx, "No favourites yet: hold a sphere (or right-click it) to add it." if category == .Favourites else "Nothing in this category yet.", color = t.text_secondary)
	material_grid(app, shown[:], m, width)
	if mc.pressing {
		ui.label(ctx, fmt.tprintf("Previewing %s: lift to keep it, slide off to go back", mc.label) if mc.shown != 0 else "Slide back onto a sphere, or lift to keep what was there", t.small_size, t.text_secondary)
	}
	ui.label(ctx, "Apply to", t.small_size, t.text_tertiary)
	targets := [len(Material_Target)]string{"Selected", "Folder", "Every object"}
	if picked := ui.tabs(ctx, "material apply to", targets[:], int(app.ui.material_to)); picked >= 0 do app.ui.material_to = Material_Target(picked)
	ui.paragraph(ctx, "Slide across the spheres to try each on; lift to keep one. Hold a sphere for Favourites. Edit changes the values, making the material Custom.")
}

// What the selected objects wear (or new objects take, with none selected): a big sphere,
// its name, its values in a line, who wears it, and Edit, or Back to the shelf while editing.
@(private = "file")
material_preview_row :: proc(app: ^App, m: Material, sel: ^Object, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	mc := &k.material_card
	side := t.target * 2
	ui.begin(ctx, "material preview", {direction = .Row, gap = ui.SPACE_L, center = true, width = width})
	a := ui.area(ctx, "material preview ball", {side, side}, drag = false)
	c := [2]f32{a.rect.x + side * 0.5, a.rect.y + side * 0.5}
	if m.matcap != 0 {
		ui.fill_circle(ctx, c, side * 0.5 - ui.SPACE_XS, t.fill)
		ui.image_disc(ctx, c, side * 0.5 - ui.SPACE_XS, KIT_MATCAP_IMAGE + u64(m.matcap), material_swatch(m))
	} else {
		ui.fill_ball(ctx, c, side * 0.5 - ui.SPACE_XS, material_swatch(m))
	}
	ui.begin(ctx, "material preview words", {direction = .Column, gap = ui.SPACE_2XS, width = width - side - ui.SPACE_L})
	ui.label(ctx, string(m.label) if m.label != nil else "Custom", t.title_size, t.text, .Semibold)
	ui.label(ctx, material_values_line(m), t.small_size, t.text_secondary)
	who := "New objects take it"
	if sel != nil {
		n := 0
		for obj in app.scene.objects do if object_in_selection(app, obj) do n += 1
		who = fmt.tprintf("On %s", object_label(sel)) if n <= 1 else fmt.tprintf("On %d objects", n)
	}
	ui.label(ctx, who, t.small_size, t.text_tertiary)
	if mc.editing {
		if ui.button(ctx, "Back to the shelf##material", .Bordered, glyph = ICON_MATERIAL, width = 0) do mc.editing = false
	} else if ui.button(ctx, "Edit##material", .Bordered, glyph = ui.ICON_PENCIL, width = 0) {
		mc.editing, mc.before = true, m
	}
	ui.end(ctx)
	ui.end(ctx)
}

// A material's values in a line: Metal and Rough (or MatCap, or Classic), then its layers.
material_values_line :: proc(m: Material) -> string {
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	switch {
	case m.matcap != 0:    append(&parts, "MatCap")
	case m.roughness == 0: append(&parts, "Classic")
	case:
		if m.metallic > 0 do append(&parts, fmt.tprintf("Metallic %.2f", m.metallic))
		append(&parts, fmt.tprintf("Roughness %.2f", m.roughness))
	}
	l := m.layers
	if l.subsurface_weight > 0 do append(&parts, "Subsurface")
	if l.coat_weight > 0 do append(&parts, "Coat")
	if l.sheen_weight > 0 do append(&parts, "Sheen")
	if l.transmission_weight > 0 do append(&parts, "Transmission")
	if l.emission_luminance > 0 do append(&parts, "Glow")
	if l.thin_film_weight > 0 do append(&parts, "Film")
	return strings.join(parts[:], " · ", context.temp_allocator)
}

// The category chips, as many to a row as fit, then the next row: a tap shows that
// category's spheres.
@(private = "file")
material_chips :: proc(app: ^App, width: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	mc := &k.material_card
	_ = t
	// Two rows of four, each a segmented control as wide as the card, so the columns line
	// up and the chosen one is marked as every choice is.
	ACROSS :: 4
	for first := 0; first < len(Material_Category); first += ACROSS {
		names: [ACROSS]string
		for i in 0 ..< ACROSS do names[i] = MATERIAL_CATEGORY_NAMES[Material_Category(first + i)]
		at := mc.category - 1 - first
		if picked := ui.tabs(ctx, fmt.tprintf("material categories %d", first / ACROSS), names[:], at if at >= 0 && at < ACROSS else -1); picked >= 0 {
			if mc.pressing do material_scrub_end(app, false)
			mc.category = first + picked + 1
		}
	}
	_ = width
}

// Edit: the material's values, each change sent as a Custom material to the objects Apply
// to names. Surface first, then each layer as a switch that shows its controls while on,
// then Thin film and the specular under More, and Reset.
@(private = "file")
material_edit :: proc(app: ^App, m: Material) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	mc := &k.material_card
	m := m
	lit := m.matcap == 0
	// A classic preset has no roughness yet, so it starts rough.
	if m.roughness == 0 && lit do m.roughness = CUSTOM_ROUGHNESS
	changed := kit_color(app, "material colour", (^[3]f32)(&m.selected), linear = true, sliders = false)
	if lit {
		changed |= ui.slider(ctx, "Roughness##lens material", &m.roughness, 0.04, 1, .Linear, fmt.tprintf("%.2f", m.roughness))
		changed |= ui.slider(ctx, "Metallic", &m.metallic, 0, 1, .Linear, fmt.tprintf("%.2f", m.metallic))
		changed |= material_layers_edit(app, &m.layers)
	}
	if changed {
		m.label = "Custom"
		app.ui.scene_command = {kind = .Material, material = m, material_to = app.ui.material_to}
	}
	if ui.button(ctx, "Reset##material edit", .Bordered, glyph = ui.ICON_UNDO, width = ui.fill_width(ctx)) {
		app.ui.scene_command = {kind = .Material, material = mc.before, material_to = app.ui.material_to}
	}
	ui.paragraph(ctx, "Each layer adds to the surface under it, as in OpenPBR: light under the skin, a clear coat, cloth's sheen, light through glass, light given off. Full render shows them all.", color = t.text_secondary)
}

// The layers' switches and controls; true when one changed.
@(private = "file")
material_layers_edit :: proc(app: ^App, l: ^geom.Material_Layers) -> (changed: bool) {
	ctx := &app.kit.ctx
	// A layer turned on gets weight 1 and, where its colour is black, white: whoever turns
	// a lobe on writes its colour (geom.Material_Layers).
	layer :: proc(ctx: ^ui.Context, name: string, weight: ^f32, color: ^[3]f32, changed: ^bool) -> bool {
		on := weight^ > 0
		if ui.switch_row(ctx, name, &on) {
			weight^ = 1 if on else 0
			if on && color != nil && color^ == {} do color^ = 1
			changed^ = true
		}
		return weight^ > 0
	}
	ui.label(ctx, "Layers", ctx.theme.small_size, ctx.theme.text_tertiary)
	weight :: proc(ctx: ^ui.Context, name: string, v: ^f32) -> bool {
		return ui.slider(ctx, name, v, 0.01, 1, .Linear, fmt.tprintf("%.2f", v^))
	}
	if layer(ctx, "Subsurface", &l.subsurface_weight, &l.subsurface_color, &changed) {
		changed |= weight(ctx, "Subsurface weight", &l.subsurface_weight)
		changed |= kit_color(app, "Subsurface colour", &l.subsurface_color, linear = true, sliders = false)
		scale := l.subsurface_scale if l.subsurface_scale > 0 else geom.LAYER_SUBSURFACE_SCALE
		if ui.slider(ctx, "Subsurface depth", &scale, 0.002, 0.5, .Logarithmic, fmt.tprintf("%.3f", scale)) {
			l.subsurface_scale = scale
			changed = true
		}
	}
	if layer(ctx, "Coat", &l.coat_weight, nil, &changed) {
		changed |= weight(ctx, "Coat weight", &l.coat_weight)
		changed |= ui.slider(ctx, "Coat roughness", &l.coat_roughness, 0, 1, .Linear, fmt.tprintf("%.2f", l.coat_roughness))
	}
	if layer(ctx, "Sheen", &l.sheen_weight, &l.sheen_color, &changed) {
		changed |= weight(ctx, "Sheen weight", &l.sheen_weight)
		changed |= kit_color(app, "Sheen colour", &l.sheen_color, linear = true, sliders = false)
		rough := l.sheen_roughness if l.sheen_roughness > 0 else geom.LAYER_SHEEN_ROUGHNESS
		if ui.slider(ctx, "Sheen roughness", &rough, 0.05, 1, .Linear, fmt.tprintf("%.2f", rough)) {
			l.sheen_roughness = rough
			changed = true
		}
	}
	if layer(ctx, "Transmission", &l.transmission_weight, &l.transmission_color, &changed) {
		changed |= weight(ctx, "Transmission weight", &l.transmission_weight)
		changed |= kit_color(app, "Transmission colour", &l.transmission_color, linear = true, sliders = false)
		thin := l.thin_walled > 0
		if ui.switch_row(ctx, "Thin sheet", &thin) {
			l.thin_walled = 1 if thin else 0
			changed = true
		}
	}
	glow := l.emission_luminance > 0
	if ui.switch_row(ctx, "Glow", &glow) {
		l.emission_luminance = 1 if glow else 0
		if glow && l.emission_color == {} do l.emission_color = 1
		changed = true
	}
	if glow {
		changed |= kit_color(app, "Glow colour", &l.emission_color, linear = true, sliders = false)
		changed |= ui.slider(ctx, "Glow brightness", &l.emission_luminance, 0.01, 10, .Logarithmic, fmt.tprintf("%.2f", l.emission_luminance))
	}
	if kit_more(app, .Material) {
		if layer(ctx, "Thin film", &l.thin_film_weight, nil, &changed) {
			nm := l.thin_film_thickness if l.thin_film_thickness > 0 else geom.LAYER_THIN_FILM_THICKNESS
			if ui.slider(ctx, "Film thickness", &nm, 100, 1500, .Linear, fmt.tprintf("%.0f nm", nm)) {
				l.thin_film_thickness = nm
				changed = true
			}
		}
		ior := l.specular_ior if l.specular_ior > 0 else geom.LAYER_SPECULAR_IOR
		if ui.slider(ctx, "Specular IOR", &ior, 1, 3, .Linear, fmt.tprintf("%.2f", ior)) {
			l.specular_ior = ior
			changed = true
		}
		kit_more_end(app)
	}
	return
}

// The spheres the card shows: the lit presets, Custom and the content packs' materials.
@(private = "file")
material_balls :: proc(app: ^App) -> []Material_Ball {
	out := make([dynamic]Material_Ball, context.temp_allocator)
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
		ui.begin(ctx, fmt.tprintf("material card row %d", first), {direction = .Row, gap = MATERIAL_GAP})
		for n in first ..< min(first + MATERIAL_ACROSS, len(balls)) {
			b := balls[n]
			a := ui.area(ctx, fmt.tprintf("%s##material card %d", b.label, n), {side, side + MATERIAL_LABEL_H})
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
			key := material_ball_key(app, b)
			if material_favorite(mc, key) >= 0 {
				// On a disc of the card's colour, so it reads over any sphere.
				at := [2]f32{c.x + r * 0.74, c.y - r * 0.74}
				ui.fill_circle(ctx, at, 9, t.surface)
				ui.icon(ctx, ui.ICON_STAR, at, t.icon_small - 4, MATERIAL_STAR_COLOR)
			}
			if ui.secondary(ctx) {
				added := material_favorite_toggle(mc, key)
				report(app, nil, {.Quiet}, "%s %s the favourites", b.label, "added to" if added else "taken off")
			}
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

// The favourite star's gold, as the mock draws it.
MATERIAL_STAR_COLOR :: ui.Color{243, 181, 74, 255}

// What names ball `b` in the favourites: a preset's or built-in MatCap's label, "Custom",
// "Imported", or a content pack's part as `material:<id>/<name>` or `matcap:<id>/<stem>`.
@(private = "file")
material_ball_key :: proc(app: ^App, b: Material_Ball) -> string {
	m := b.material
	refs := material_refs(app, m)
	switch {
	case refs.material != "":       return fmt.tprintf("material:%s", refs.material)
	case refs.matcap != "":         return fmt.tprintf("matcap:%s", refs.matcap)
	case m.matcap == MATCAP_IMAGE:  return "Imported"
	}
	return string(m.label) if m.label != nil else "Custom"
}

// Where `key` is among the favourites, or -1.
material_favorite :: proc(mc: ^Material_Card, key: string) -> int {
	for &k, i in mc.favorites[:mc.favorite_count] do if brush_key_text(&k) == key do return i
	return -1
}

// Adds `key` to the favourites, or takes it off when it is one; true when it was added.
material_favorite_toggle :: proc(mc: ^Material_Card, key: string) -> bool {
	mc.favorite_changes += 1
	if i := material_favorite(mc, key); i >= 0 {
		copy(mc.favorites[i:], mc.favorites[i + 1:mc.favorite_count])
		mc.favorite_count -= 1
		return false
	}
	if key == "" || mc.favorite_count == MATERIAL_FAVORITES do return false
	brush_key_set(&mc.favorites[mc.favorite_count], key)
	mc.favorite_count += 1
	return true
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
