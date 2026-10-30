package main

import "core:fmt"
import "core:math"
import "core:strconv"

import "../render"

// Viewport shading, in Blender's four modes: Wireframe, every polygon's edges over a plain
// fill that hides the edges behind it; Solid, quick shading to sculpt in, lit by the studio
// lights, by a MatCap or not at all (Flat), each object in its material's colour, a colour
// of its own or one grey; Material Preview, the objects' own materials whole, with their
// textures; Rendered, Material Preview with the Render switch on. The passes that check the
// form (Normals, Curvature...) show over the mode, as Blender's viewport passes do.
//
// A view's shading is its own (View_Shading): the main view keeps it in Passes, which the
// workspace's layout writes. The objects keep only their materials: each frame the draw
// items are made once, as their materials say, and shading_items rewrites the main view's
// copy of them by its shading, from what each item was made of (Item_From).

Shading_Mode :: enum u8 {
	// Solid first, as the zero value is what a view starts in.
	Solid,
	Wireframe,
	Material_Preview,
	Rendered,
}

// The modes in the order the menus list them, Blender's.
@(rodata)
SHADING_MODE_ORDER := [Shading_Mode]Shading_Mode{.Solid = .Wireframe, .Wireframe = .Solid, .Material_Preview = .Material_Preview, .Rendered = .Rendered}

@(rodata)
SHADING_MODE_NAMES := [Shading_Mode]string {
	.Wireframe        = "Wireframe",
	.Solid            = "Solid",
	.Material_Preview = "Material Preview",
	.Rendered         = "Rendered",
}

@(rodata)
SHADING_MODE_ICONS := [Shading_Mode]rune {
	.Wireframe        = ICON_WIREFRAME,
	.Solid            = ICON_SHADING,
	.Material_Preview = ICON_MATERIAL,
	.Rendered         = ICON_SPARKLES,
}

// How Solid lights the objects: the studio lights; a MatCap, the same for every object;
// or no light at all, each colour shown as it is.
Solid_Lighting :: enum u8 {
	Studio,
	MatCap,
	Flat,
}

@(rodata)
SOLID_LIGHTING_NAMES := [Solid_Lighting]string {
	.Studio = "Studio",
	.MatCap = "MatCap",
	.Flat   = "Flat",
}

// The colour Solid shows each object in: its material's, a colour of its own (to tell the
// objects apart), or one light grey for all.
Solid_Color :: enum u8 {
	Material,
	Object,
	Single,
}

@(rodata)
SOLID_COLOR_NAMES := [Solid_Color]string {
	.Material = "Material",
	.Object   = "Object",
	.Single   = "Single",
}

// Solid's Single colour, a light clay grey.
SOLID_SINGLE :: [4]f32{0.62, 0.62, 0.62, 1}

View_Shading :: struct {
	// The mode picked; Rendered is never kept here, as the Render switch says it
	// (shading_mode_shown), and picking it puts Material Preview here.
	mode:     Shading_Mode,
	lighting: Solid_Lighting,
	color:    Solid_Color,
	// Solid's MatCap, as Material.matcap counts them; 0 for the default, Grey.
	matcap:   int,
}

// Solid's MatCap until one is picked: Grey, Blender's default's look.
SHADING_MATCAP_DEFAULT :: 3

// What a draw item was made from, for shading_items to make it again for a view's shading:
// the object (nil for none), its index, the colour it was tinted before any texture, its
// material, and whether its textured preview has a base colour map.
Item_From :: struct {
	obj:      ^Object,
	index:    int,
	tint:     [4]f32,
	material: Material,
	base_map: bool,
}

// The mode view shading `s` shows: Rendered while the Render switch is on, else the one
// picked.
shading_mode_shown :: proc(app: ^App, s: View_Shading) -> Shading_Mode {
	if render_switch_on(app) do return .Rendered
	return s.mode
}

// The main view's mode as it shows now.
main_shading_mode :: proc(app: ^App) -> Shading_Mode {
	return shading_mode_shown(app, app.kit.passes.shading)
}

// Picks mode `m` for the main view: Rendered puts the Render switch on (at the quality it
// was last on) over Material Preview; any other puts it off.
shading_mode_set :: proc(app: ^App, m: Shading_Mode) {
	s := &app.kit.passes.shading
	if m == .Rendered {
		s.mode = .Material_Preview
		if !render_switch_on(app) do render_set(app, true, app.render_quality)
	} else {
		s.mode = m
		if render_switch_on(app) do render_set(app, false, app.render_quality)
	}
	// A mode is what the view shows, so a pass that checks the form gives way to it.
	pass_set(&app.kit, .Shaded)
}

// Picks Solid's lighting `l`, and Solid with it.
solid_lighting_set :: proc(app: ^App, l: Solid_Lighting) {
	shading_mode_set(app, .Solid)
	app.kit.passes.shading.lighting = l
}

// The MatCap texture Solid's MatCap lighting shades with, the default while the one picked
// is gone (a content pack's taken away).
shading_matcap :: proc(app: ^App, s: View_Shading) -> render.Texture {
	if s.matcap != 0 {
		if tex := material_matcap(app, {matcap = s.matcap}); tex != nil do return tex
	}
	return material_matcap(app, {matcap = SHADING_MATCAP_DEFAULT})
}

// The name of the MatCap Solid shades with.
shading_matcap_name :: proc(app: ^App, s: View_Shading) -> string {
	i := s.matcap if s.matcap > 0 && s.matcap <= len(MATCAP_RECIPES) else SHADING_MATCAP_DEFAULT
	if s.matcap == MATCAP_IMAGE && app.matcap_image != nil do return "Imported"
	if s.matcap >= PACK_MATCAP {
		if mc, ok := pack_matcap_at(app, s.matcap - PACK_MATCAP); ok do return mc.stem
	}
	return string(MATCAP_RECIPES[i - 1].label)
}

// The pass a view in shading `s` draws its items in, where the pass picked is `p`: a pass
// that checks the form as it is; otherwise Wireframe's plain fill, Solid's Flat lighting
// unlit, or the shading as the materials say.
shading_pass :: proc(app: ^App, s: View_Shading, p: render.View_Pass) -> render.View_Pass {
	if p != .Shaded do return p
	switch shading_mode_shown(app, s) {
	case .Wireframe: return .Wire
	case .Solid:     if s.lighting == .Flat do return .Unlit
	case .Material_Preview, .Rendered:
	}
	return .Shaded
}

// Whether a view shows its objects' textured previews when no texture view is picked:
// Material Preview and Rendered show the base colour map, as Blender's do.
shading_wants_textures :: proc(app: ^App) -> bool {
	m := main_shading_mode(app)
	return m == .Material_Preview || m == .Rendered
}

// The texture view the frame draws the textured previews in: the one picked, else
// Textured where the main view's mode shows materials whole.
texture_view_shown :: proc(app: ^App) -> render.Texture_View {
	if app.texture_view != .Off do return app.texture_view
	return .Textured if shading_wants_textures(app) else .Off
}

// Whether a view wants every object's polygon edges: the main view in Wireframe.
shading_wire :: proc(app: ^App) -> bool {
	return main_shading_mode(app) == .Wireframe && app.kit.grid.work == 0
}

// Object `obj`'s own colour in Solid's Object colour: a light, muted hue of its own,
// stepped round the colour wheel by the golden angle so neighbours differ.
shading_object_color :: proc(obj: ^Object) -> [4]f32 {
	hue := math.mod(f32(obj.id) * 0.618034, 1)
	// A pastel: the hue's colour taken two thirds of the way to a light grey.
	c: [3]f32
	for k in 0 ..< 3 {
		x := math.abs(math.mod(hue * 6 + f32(4 - 2 * k), 6) - 3) - 1
		c[k] = 0.68 + 0.22 * (clamp(x, 0, 1) - 0.5)
	}
	return {c[0], c[1], c[2], 1}
}

// Rewrites draw items `items`, made as their materials say from `froms`, for a view in
// shading `s`. Wireframe leaves the fill plain and draws every edge; Solid shows the
// colour asked for, physically based materials as classic ones, and lights it by the
// studio (an object's own MatCap material still shades it), the view's MatCap or nothing;
// Material Preview and Rendered keep the materials whole and show the textured previews.
shading_items :: proc(app: ^App, items: []render.Draw_Item, froms: []Item_From, s: View_Shading) {
	mode := shading_mode_shown(app, s)
	for &d, i in items {
		f := froms[i] if i < len(froms) else {}
		switch mode {
		case .Wireframe:
			d.paint, d.groups, d.slots, d.matcap = false, false, nil, nil
			d.textured, d.texture_view = nil, .Off
			// A level with polygon edges and a cage draw those; the rest their triangles'.
			if !d.cage_lines do d.wireframe = true
		case .Solid:
			// Solid shows a texture only while a texture view is picked.
			if app.texture_view == .Off do d.textured, d.texture_view = nil, .Off
			d.surface = {}
			if f.obj == nil do continue
			m := f.material
			// A physically based material shows its colour with the classic shading.
			if m.roughness > 0 do m.shading = {}
			switch s.color {
			case .Material:
			case .Object:
				c := shading_object_color(f.obj)
				m.selected, m.idle = c, {c.r * 0.82, c.g * 0.82, c.b * 0.84, 1}
			case .Single:
				m.selected, m.idle = SOLID_SINGLE, {0.5, 0.5, 0.52, 1}
			}
			if s.lighting == .MatCap {
				// The view's MatCap on every object, tinted by the colour picked; in the
				// material's colour, a MatCap is shown white, as the MatCap balls are.
				if s.color == .Material do m.selected, m.idle = {1, 1, 1, 1}, MATCAP_IDLE
				d.matcap = shading_matcap(app, s)
			} else if s.lighting == .Flat {
				d.matcap = nil
			}
			d.material = m.shading
			if s.color != .Material || s.lighting == .MatCap {
				d.color = material_draw_tint(app, f.obj, f.index, m)
				if d.textured != nil do d.color = textured_color(d.color, m, f.base_map && d.texture_view == .Textured)
			}
		case .Material_Preview, .Rendered:
			// The textured preview's base colour stands for the material's.
			if d.textured != nil && d.texture_view == .Off {
				d.texture_view = .Textured
				d.color = textured_color(f.tint, f.material, f.base_map)
			}
		}
	}
}

// The shading's line in a layout (`shading <mode> <lighting> <colour> <matcap>`), written
// only when it is not a fresh view's.
shading_layout_line :: proc(k: ^Kit_State) -> string {
	s := k.passes.shading
	if s == {} do return ""
	return fmt.tprintf("shading %v %v %v %d\n", s.mode, s.lighting, s.color, s.matcap)
}

// Reads a layout's shading line's words; a word naming nothing keeps what was there.
shading_layout_read :: proc(k: ^Kit_State, f: []string) {
	s := &k.passes.shading
	if len(f) > 1 do for m in Shading_Mode do if m != .Rendered && fmt.tprint(m) == f[1] do s.mode = m
	if len(f) > 2 do for l in Solid_Lighting do if fmt.tprint(l) == f[2] do s.lighting = l
	if len(f) > 3 do for c in Solid_Color do if fmt.tprint(c) == f[3] do s.color = c
	if len(f) > 4 {
		if n, ok := strconv.parse_int(f[4]); ok && n >= 0 do s.matcap = n
	}
}
