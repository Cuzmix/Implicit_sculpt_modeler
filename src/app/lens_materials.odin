package main

import "core:fmt"
import "core:hash"
import "core:strings"

import "../geom"
import "../render"
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
	.Favourites = "Starred",
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
	scene:    bool, // the shelf shows In this scene instead of the library
	editing:  bool,
	before:   Material,
	// The atlas cells the balls are drawn into (render.material_balls_draw): what each shows
	// and whether it is drawn, kept across frames so a ball is drawn once; `look` is the
	// lights and look they were drawn under, and `frame` counts the frames the card showed.
	slots:    [dynamic]Ball_Slot, // render.BALL_SLOTS of them once the card first shows; freed by kit_destroy
	look:     u64,
	frame:    int,
	drew:     bool, // the card showed this frame, so its cells may be drawn
	favorite_changes: int, // for the exit stats
}

// One cell of the balls' atlas: the material it shows, the key of what it was asked to
// draw (its values and the look), whether it is drawn, and the frame it was last shown.
Ball_Slot :: struct {
	material: Material,
	key:      u64,
	drawn:    bool,
	used:     int,
}

// The cell that shows `m`, keeping or taking one: the cell already keyed to it, else the
// one shown longest ago, which is then drawn anew. `drawn` says the cell can be shown.
material_ball_slot :: proc(app: ^App, m: Material) -> (slot: int, drawn: bool) {
	mc := &app.kit.material_card
	if len(mc.slots) == 0 do resize(&mc.slots, render.BALL_SLOTS)
	request := material_ball_request(app, 0, m)
	key := hash.fnv64a(([^]u8)(&request)[:size_of(request)], mc.look)
	oldest := 0
	for &s, i in mc.slots {
		if s.key == key {
			s.used = mc.frame
			return i, s.drawn
		}
		if s.used < mc.slots[oldest].used do oldest = i
	}
	mc.slots[oldest] = {material = m, key = key, used = mc.frame}
	return oldest, false
}

// Each frame after the interface, where a command buffer is open: the lights and look are
// keyed, so a change to them draws every ball again; then the cells the card showed this
// frame and not yet drawn go to material_balls_frame, a few at a time while the view is
// still, in the order the card asked for them.
material_card_balls_frame :: proc(app: ^App, cmd: render.Cmd) {
	mc := &app.kit.material_card
	// Nothing is drawn, or kept up to date, while the card is not on screen.
	if !mc.drew do return
	mc.drew = false
	lights, look, style := viewport_lights(app), viewport_look(app), viewport_style(app)
	key := hash.fnv64a(([^]u8)(&lights)[:size_of(lights)])
	key = hash.fnv64a(([^]u8)(&look)[:size_of(look)], key)
	key = hash.fnv64a(([^]u8)(&style)[:size_of(style)], key)
	if key != mc.look {
		mc.look = key
		for &s in mc.slots do s = {}
	}
	requests := make([dynamic]render.Ball_Request, 0, len(mc.slots), context.temp_allocator)
	cells := make([dynamic]int, 0, len(mc.slots), context.temp_allocator)
	for &s, i in mc.slots {
		if s.key == 0 || s.drawn || s.used != mc.frame do continue
		append(&requests, material_ball_request(app, i, s.material))
		append(&cells, i)
	}
	n := material_balls_frame(app, cmd, requests[:])
	for i in cells[:n] do mc.slots[i].drawn = true
}

// Ball `m` filling the circle at `c` of radius `r`: its cell of the atlas once drawn (the
// sphere fills the cell all but a small margin, material_ball_camera), the kit's shaded
// disc in its colour until then.
material_ball_draw :: proc(app: ^App, c: [2]f32, r: f32, m: Material) {
	ctx := &app.kit.ctx
	slot, drawn := material_ball_slot(app, m)
	if !drawn {
		if m.matcap != 0 {
			ui.fill_circle(ctx, c, r, ctx.theme.fill)
			ui.image_disc(ctx, c, r, KIT_MATCAP_IMAGE + u64(m.matcap), material_swatch(m))
		} else {
			ui.fill_ball(ctx, c, r, material_swatch(m))
		}
		return
	}
	// A see-through ball shows what is behind it, which in its cell is nothing: a quiet disc
	// stands behind it, as glass is shown on a backdrop.
	if m.layers.transmission_weight > 0 do ui.fill_circle(ctx, c, r, ctx.theme.fill)
	half := r * 1.04
	lo, hi := render.ball_uv(slot)
	ui.image_part(ctx, {c.x - half, c.y - half, 2 * half, 2 * half}, KIT_MATERIAL_BALLS_IMAGE, lo, hi)
	// A hairline rim, so a dark material (rubber) keeps its outline on a dark card.
	ui.stroke_circle(ctx, c, r, ctx.theme.border, 1)
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
	mc.frame += 1
	mc.drew = true
	if mc.category == 0 do mc.category = int(material_category(m)) + 1
	material_preview_row(app, m, sel, width)
	if mc.editing {
		material_edit(app, m)
		return
	}
	// Where the spheres come from, apart from what kind they are: the library's presets and
	// packs by category, or the materials the scene's objects wear.
	sources := [2]string{"Library", "In this scene"}
	if picked := ui.tabs(ctx, "material source", sources[:], 1 if mc.scene else 0); picked >= 0 {
		if mc.pressing do material_scrub_end(app, false)
		mc.scene = picked == 1
	}
	if mc.scene {
		material_scene(app, m, width)
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
	material_ball_draw(app, c, side * 0.5 - ui.SPACE_XS, m)
	ui.begin(ctx, "material preview words", {direction = .Column, gap = ui.SPACE_2XS, width = width - side - ui.SPACE_L})
	name := string(m.label) if m.label != nil else "Custom"
	// What the file called it, while the object wears what the import gave it (an import's
	// material is Custom, as no preset; a preset picked since shows the preset's name).
	if sel != nil && name == "Custom" do name = imported_name(sel, 0, name)
	ui.label(ctx, name, t.title_size, t.text, .Semibold)
	ui.label(ctx, material_values_line(m), t.small_size, t.text_secondary)
	who := "New objects take it"
	if sel != nil {
		n := 0
		for obj in app.scene.objects do if object_in_selection(app, obj) do n += 1
		who = fmt.tprintf("On %s", object_label(sel)) if n <= 1 else fmt.tprintf("On %d objects", n)
	}
	ui.label(ctx, who, t.small_size, t.text_tertiary)
	if mc.editing {
		// Back and Reset side by side, so the way out and the way back are always in sight
		// however long the layers run.
		ui.begin(ctx, "material edit head", {direction = .Row, gap = ui.SPACE_S})
		if ui.button(ctx, "Shelf##material", .Bordered, glyph = ui.ICON_CHEVRON_LEFT) do mc.editing = false
		if ui.button(ctx, "Reset##material edit", .Flat, glyph = ui.ICON_UNDO) {
			app.ui.scene_command = {kind = .Material, material = mc.before, material_to = app.ui.material_to}
		}
		ui.end(ctx)
	} else if ui.button(ctx, "Edit##material", .Bordered, glyph = ui.ICON_PENCIL, width = 0) {
		mc.editing, mc.before = true, m
	}
	ui.end(ctx)
	ui.end(ctx)
}

// What a material is, in a line short enough for the card: its category (or MatCap), then
// the layers it has. The numbers are the sliders' to show, in Edit.
material_values_line :: proc(m: Material) -> string {
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&parts, "MatCap" if m.matcap != 0 else MATERIAL_CATEGORY_NAMES[material_category(m)])
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
	// One well holding two rows of four, so the eight read as one choice with one chosen,
	// and the columns line up.
	ACROSS :: 4
	pad := f32(ui.SPACE_2XS)
	cell := (width - 2 * pad - (ACROSS - 1) * pad) / ACROSS
	ui.begin(ctx, "material categories", {direction = .Column, gap = ui.SPACE_2XS, padding = ui.SPACE_2XS, background = .Track, radius = t.radius_medium, width = width})
	for first := 0; first < len(Material_Category); first += ACROSS {
		ui.begin(ctx, fmt.tprintf("material categories %d", first / ACROSS), {direction = .Row, gap = ui.SPACE_2XS})
		for c in Material_Category(first) ..= Material_Category(first + ACROSS - 1) {
			name := MATERIAL_CATEGORY_NAMES[c]
			if ui.toggle_button(ctx, name, mc.category == int(c) + 1, cell, tooltip = name) {
				if mc.pressing do material_scrub_end(app, false)
				mc.category = int(c) + 1
			}
		}
		ui.end(ctx)
	}
	ui.end(ctx)
}

// Edit: the material's values, each change sent as a Custom material to the objects Apply
// to names. Surface first, then each layer as a switch that shows its controls while on,
// then Thin film and the specular under More (Reset is beside Shelf, in the head).
@(private = "file")
material_edit :: proc(app: ^App, m: Material) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
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
	// The maps the file named for this material, as the import read them.
	if sel := selected_object(app); sel != nil {
		for e in sel.imported {
			if e.group != 0 do continue
			for name, which in e.maps do if name != "" do ui.label(ctx, fmt.tprintf("%v map · %s", which, name), t.small_size, t.text_secondary)
		}
	}
	ui.paragraph(ctx, "Each layer adds to the surface under it, as in OpenPBR: light under the skin, a clear coat, cloth's sheen, light through glass, light given off. Full render shows them all.", color = t.text_secondary)
}

// The layers' switches and controls; true when one changed.
@(private = "file")
material_layers_edit :: proc(app: ^App, l: ^geom.Material_Layers) -> (changed: bool) {
	ctx := &app.kit.ctx
	// A layer turned on gets weight 1 and, where its colour is black, white: whoever turns
	// a lobe on writes its colour (geom.Material_Layers).
	// While on, its controls follow in an inset well (group_end closes it), so they read as
	// the layer's and not the surface's.
	layer :: proc(ctx: ^ui.Context, name: string, weight: ^f32, color: ^[3]f32, changed: ^bool) -> bool {
		on := weight^ > 0
		if ui.switch_row(ctx, name, &on) {
			weight^ = 1 if on else 0
			if on && color != nil && color^ == {} do color^ = 1
			changed^ = true
		}
		if weight^ <= 0 do return false
		group_begin(ctx, name)
		return true
	}
	group_begin :: proc(ctx: ^ui.Context, name: string) {
		ui.begin(ctx, fmt.tprintf("%s layer", name), {direction = .Column, gap = ui.SPACE_S, padding = ui.SPACE_M, background = .Track, radius = ctx.theme.radius_medium, width = ui.fill_width(ctx)})
	}
	ui.label(ctx, "Surface layers", ctx.theme.small_size, ctx.theme.text_tertiary)
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
		ui.end(ctx)
	}
	if layer(ctx, "Coat", &l.coat_weight, nil, &changed) {
		changed |= weight(ctx, "Coat weight", &l.coat_weight)
		changed |= ui.slider(ctx, "Coat roughness", &l.coat_roughness, 0, 1, .Linear, fmt.tprintf("%.2f", l.coat_roughness))
		ui.end(ctx)
	}
	if layer(ctx, "Sheen", &l.sheen_weight, &l.sheen_color, &changed) {
		changed |= weight(ctx, "Sheen weight", &l.sheen_weight)
		changed |= kit_color(app, "Sheen colour", &l.sheen_color, linear = true, sliders = false)
		rough := l.sheen_roughness if l.sheen_roughness > 0 else geom.LAYER_SHEEN_ROUGHNESS
		if ui.slider(ctx, "Sheen roughness", &rough, 0.05, 1, .Linear, fmt.tprintf("%.2f", rough)) {
			l.sheen_roughness = rough
			changed = true
		}
		ui.end(ctx)
	}
	if layer(ctx, "Transmission", &l.transmission_weight, &l.transmission_color, &changed) {
		changed |= weight(ctx, "Transmission weight", &l.transmission_weight)
		changed |= kit_color(app, "Transmission colour", &l.transmission_color, linear = true, sliders = false)
		thin := l.thin_walled > 0
		if ui.switch_row(ctx, "Thin sheet", &thin) {
			l.thin_walled = 1 if thin else 0
			changed = true
		}
		ui.end(ctx)
	}
	glow := l.emission_luminance > 0
	if ui.switch_row(ctx, "Glow", &glow) {
		l.emission_luminance = 1 if glow else 0
		if glow && l.emission_color == {} do l.emission_color = 1
		changed = true
	}
	if glow {
		group_begin(ctx, "Glow")
		changed |= kit_color(app, "Glow colour", &l.emission_color, linear = true, sliders = false)
		changed |= ui.slider(ctx, "Glow brightness", &l.emission_luminance, 0.01, 10, .Logarithmic, fmt.tprintf("%.2f", l.emission_luminance))
		ui.end(ctx)
	}
	if kit_more(app, .Material) {
		if layer(ctx, "Thin film", &l.thin_film_weight, nil, &changed) {
			nm := l.thin_film_thickness if l.thin_film_thickness > 0 else geom.LAYER_THIN_FILM_THICKNESS
			if ui.slider(ctx, "Film thickness", &nm, 100, 1500, .Linear, fmt.tprintf("%.0f nm", nm)) {
				l.thin_film_thickness = nm
				changed = true
			}
			ui.end(ctx)
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

// In this scene: each object that has a material, its name a row that selects it (lit
// while it is the selected one), then its own material and each of its groups', by the
// names the file gave them where the import read their values. The spheres act as every
// shelf's do: a tap puts that material on what Apply to names, a slide tries each.
@(private = "file")
material_scene :: proc(app: ^App, m: Material, width: f32) {
	ctx := &app.kit.ctx
	t := ctx.theme
	sel := selected_object(app)
	any := false
	for obj, k in app.scene.objects {
		if obj.material.label == nil do continue
		any = true
		balls := make([dynamic]Material_Ball, 0, 1 + len(obj.group_materials), context.temp_allocator)
		append(&balls, Material_Ball{obj.material, imported_name(obj, 0, string(obj.material.label))})
		for e in obj.group_materials do append(&balls, Material_Ball{e.material, imported_name(obj, e.group, fmt.tprintf("Group %d", e.group))})
		head := object_label(obj)
		if len(balls) > 1 do head = fmt.tprintf("%s · %d materials", head, len(balls))
		if ui.menu_item(ctx, fmt.tprintf("%s##scene object %d", head, k), glyph = ui.ICON_FRAME, highlight = obj == sel) {
			ids := [1]int{obj.id}
			selection_set(app, ids[:])
		}
		material_grid(app, balls[:], m, width, fmt.tprintf("scene object %d", k))
	}
	if !any do ui.paragraph(ctx, "No object has a material yet.", color = t.text_secondary)
	ui.paragraph(ctx, "Tap an object's name to select it; tap a material to put it on the selection, as on the shelf. An imported one keeps its file's name.")
}

// What the file named the material on group `group` of `obj`, or `fallback`.
imported_name :: proc(obj: ^Object, group: u16, fallback: string) -> string {
	// Only where the import read its values: one the file named but left empty shows the
	// default the object wears, by that default's name.
	for e in obj.imported do if e.group == group && e.name != "" && e.valued do return e.name
	return fallback
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
	// Every Custom one (edited, or an import's) shares the index: those match by value.
	if material_index(m) == CUSTOM_MATERIAL || material_index(b.material) == CUSTOM_MATERIAL {
		return b.material.selected == m.selected && b.material.metallic == m.metallic && b.material.roughness == m.roughness && b.material.layers == m.layers
	}
	return material_index(m) == material_index(b.material)
}

// The grid of `balls`, the one in use (`m`) ringed, with the scrub: see the file's head.
@(private = "file")
material_grid :: proc(app: ^App, balls: []Material_Ball, m: Material, width: f32, name := "material card") {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	mc := &k.material_card
	side := (width - MATERIAL_GAP * (MATERIAL_ACROSS - 1)) / MATERIAL_ACROSS
	rects := make([]ui.Rect, len(balls), context.temp_allocator)
	held := false
	for first := 0; first < len(balls); first += MATERIAL_ACROSS {
		ui.begin(ctx, fmt.tprintf("%s row %d", name, first), {direction = .Row, gap = MATERIAL_GAP})
		for n in first ..< min(first + MATERIAL_ACROSS, len(balls)) {
			b := balls[n]
			a := ui.area(ctx, fmt.tprintf("%s##%s %d", b.label, name, n), {side, side + MATERIAL_LABEL_H})
			rects[n] = a.rect
			held ||= a.held
			r := side * 0.5 - 5
			c := [2]f32{a.rect.x + side * 0.5, a.rect.y + side * 0.5}
			on := material_ball_on(b, m)
			if a.hovered && ctx.input.pointer != .Finger && !on do ui.stroke_circle(ctx, c, r + 2.5, ui.color_fade(t.text_tertiary, 0.6), 1)
			material_ball_draw(app, c, r, b.material)
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
			shown_name := ui.text_fit(ctx, b.label, t.caption_size, side)
			ui.text(ctx, shown_name, c.x, a.rect.y + side + MATERIAL_LABEL_H * 0.5 - 2, t.caption_size, t.accent if on else t.text_secondary, .Regular, .Center)
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
