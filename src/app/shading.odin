package main

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

import "../render"
import "../ui"

// Viewport shading, in four looks picked from one row: Clay, quick shading to sculpt in,
// lit by a MatCap that turns with the view; Lit, the same clay shading lit by the scene's
// lights, to check them; Full, the objects' own materials whole with their textures, which
// the Render switch renders (Rendered); and Flat, every colour as it is with no light, for
// painting. The view's Colour takes the paint, the textures and the materials' colours
// toward clay, so the form reads under them, and its Colour from shows each object in a
// colour of its own instead. The passes that check the form (Normals, Curvature...) show
// over the look, as Blender's viewport passes do.
//
// A view's shading is its own (View_Shading): the main view keeps it in Passes, and each
// other view (a view pane, the second view, a view window) in its Second_View, shown while
// its pass is Shaded, its Render pass being its Rendered; the space's layout writes
// them. The objects keep only their materials: each frame the draw items are made once, as
// their materials say, and shading_items rewrites each view's copy of them by its shading,
// from what each item was made of (Item_From).

Shading_Mode :: enum u8 {
	// Lit first, as the zero value is what a view starts in.
	Lit,
	Clay,
	Full,
	Flat,
	// Full with the Render switch on (or a view's Render pass): shown, never picked as a
	// look of its own.
	Rendered,
}

// The looks in the order the row lists them.
@(rodata)
SHADING_LOOKS := [?]Shading_Mode{.Clay, .Lit, .Full, .Flat}

@(rodata)
SHADING_MODE_NAMES := [Shading_Mode]string {
	.Clay     = "Clay",
	.Lit      = "Lit",
	.Full     = "Full",
	.Flat     = "Flat",
	.Rendered = "Rendered",
}

// What each look is for, shown under the looks so a newcomer knows what the names mean:
// the first sentence on the line, the rest when the line is tapped.
@(rodata)
SHADING_MODE_HINTS := [Shading_Mode]string {
	.Clay     = "Plain MatCap clay that reads every form, for sculpting. The light turns with the view, so no side is ever dark; pick the MatCap below.",
	.Lit      = "The studio lights and the objects' colours, for judging forms under light. The lights stay put while the view turns.",
	.Full     = "Materials, paint and textures under the environment, for painting and looking at the finished surface. The Render switch below turns on the path tracer.",
	.Flat     = "Colours with no light at all, for checking paint, textures and the outline.",
	.Rendered = "The path tracer's picture of the full look, refined while the view is still.",
}

@(rodata)
SHADING_MODE_ICONS := [Shading_Mode]rune {
	.Clay     = ICON_SHADING,
	.Lit      = ui.ICON_SUN,
	.Full     = ICON_MATERIAL,
	.Flat     = ICON_CONTRAST,
	.Rendered = ICON_SPARKLES,
}

// Where each object's colour comes from: its material (with its paint and textures), or a
// colour of its own, to tell the objects apart.
Colour_From :: enum u8 {
	Material,
	Object,
}

@(rodata)
COLOUR_FROM_NAMES := [Colour_From]string {
	.Material = "Material",
	.Object   = "Object",
}

// The clay Lit and Full take colours toward at Colour 0: a light clay grey for the
// selected object, a darker one for the rest.
SHADING_CLAY :: [4]f32{0.62, 0.62, 0.62, 1}
SHADING_CLAY_IDLE :: [4]f32{0.5, 0.5, 0.52, 1}

View_Shading :: struct {
	// The look picked; Rendered is never kept here, as the Render switch says it
	// (shading_mode_shown), and picking it puts Full here.
	mode:   Shading_Mode,
	from:   Colour_From,
	// How far the colours are taken toward clay, 0 to 1: the view's Colour is one less
	// this, so a fresh view (zero) shows them whole.
	grey:   f32,
	// Clay's MatCap, as Material.matcap counts them; 0 for the default, Grey.
	matcap: int,
}

// Clay's MatCap until one is picked: Grey, Blender's default's look.
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

// The look view shading `s` shows: for the main view Rendered while the Render switch is
// on, else the one picked; another view's (`pane`) is its own, the switch being the main
// view's.
shading_mode_shown :: proc(app: ^App, s: View_Shading, pane := false) -> Shading_Mode {
	if !pane && render_switch_on(app) do return .Rendered
	return s.mode
}

// The look second view `sv` shows, with `ok` false while it shows a pass that checks the
// form or the studio render instead: its own look while Shaded, Rendered while it shows
// Render.
second_shading_mode :: proc(sv: ^Second_View) -> (m: Shading_Mode, ok: bool) {
	#partial switch sv.pass {
	case .Shaded: return sv.shading.mode, true
	case .Render: return .Rendered, true
	}
	return
}

// The shading the main draw shows: the main view's, or while a view pane is worked in
// (grid_work) that pane's, Full standing for its Render pass and for a pass that checks
// the form; `pane` says which.
main_draw_shading :: proc(app: ^App) -> (s: View_Shading, pane: bool) {
	g := &app.kit.grid
	if g.work == 0 do return app.kit.passes.shading, false
	sv := grid_view(g, g.work)
	if sv.pass == .Shaded do return sv.shading, true
	return {mode = .Full}, true
}

// Whether any view showing now is in look `m`: the main view, a view pane or a view window.
shading_mode_anywhere :: proc(app: ^App, m: Shading_Mode) -> bool {
	if main_shading_mode(app) == m do return true
	g := &app.kit.grid
	for i in 1 ..< grid_panes(g) do if pane_shows_view(g, i) {
		if shown, ok := second_shading_mode(grid_view(g, i)); ok && shown == m do return true
	}
	for w in app.view_windows.open {
		if w == nil do continue
		if shown, ok := second_shading_mode(&w.view); ok && shown == m do return true
	}
	return false
}

// The main view's look as it shows now.
main_shading_mode :: proc(app: ^App) -> Shading_Mode {
	return shading_mode_shown(app, app.kit.passes.shading)
}

// Picks look `m` for the main view: Rendered puts the Render switch on (at the quality it
// was last on) over Full; any other puts it off.
shading_mode_set :: proc(app: ^App, m: Shading_Mode) {
	s := &app.kit.passes.shading
	if m == .Rendered {
		s.mode = .Full
		if !render_switch_on(app) do render_set(app, true, app.render_quality)
	} else {
		s.mode = m
		if render_switch_on(app) do render_set(app, false, app.render_quality)
	}
	// A look is what the view shows, so a pass that checks the form gives way to it.
	pass_set(&app.kit, .Shaded)
}

// The MatCap texture Clay shades with, the default while the one picked is gone (a content
// pack's taken away).
shading_matcap :: proc(app: ^App, s: View_Shading) -> render.Texture {
	if s.matcap != 0 {
		if tex := material_matcap(app, {matcap = s.matcap}); tex != 0 do return tex
	}
	return material_matcap(app, {matcap = SHADING_MATCAP_DEFAULT})
}

// The pass a view in shading `s` draws its items in, where the pass picked is `p`: a pass
// that checks the form as it is; otherwise Flat unlit, or the shading as the materials say.
shading_pass :: proc(app: ^App, s: View_Shading, p: render.View_Pass, pane := false) -> render.View_Pass {
	if p != .Shaded do return p
	if shading_mode_shown(app, s, pane) == .Flat do return .Unlit
	return .Shaded
}

// Whether the objects' textured previews are wanted when no texture view is picked: a view
// in Full or Rendered shows the base colour map, as Blender's Material Preview does.
shading_wants_textures :: proc(app: ^App) -> bool {
	return shading_mode_anywhere(app, .Full) || shading_mode_anywhere(app, .Rendered)
}

// The texture view the frame draws the textured previews in: the one picked, else
// Textured where the main view's look shows materials whole.
texture_view_shown :: proc(app: ^App) -> render.Texture_View {
	if app.texture_view != .Off do return app.texture_view
	return .Textured if shading_wants_textures(app) else .Off
}

// Object `obj`'s own colour for Colour from Object: a light, muted hue of its own, stepped
// round the colour wheel by the golden angle so neighbours differ.
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
// shading `s`. Clay, Lit and Flat show physically based materials as classic ones and a
// texture only while a texture view is picked; Clay shades every object by the view's
// MatCap, white in the material's colour as the MatCap balls are (an object's own MatCap
// material still shades it), and Lit and Flat by the lights or none; Full and Rendered keep
// the materials whole and show the textured previews. The Colour takes every look but
// Flat's and Rendered's colours toward clay (the path tracer renders them whole).
shading_items :: proc(app: ^App, items: []render.Draw_Item, froms: []Item_From, s: View_Shading, pane := false) {
	mode := shading_mode_shown(app, s, pane)
	for &d, i in items {
		f := froms[i] if i < len(froms) else {}
		if f.obj == nil {
			if mode != .Full && mode != .Rendered {
				if d.texture_view == .Off do d.textured = nil
				d.surface = {}
			}
			continue
		}
		m := f.material
		switch mode {
		case .Clay, .Lit, .Flat:
			// A texture shows only while a texture view is picked, or Peel lays the object
			// flat (object_texture_view).
			if d.texture_view == .Off do d.textured = nil
			d.surface = {}
			// A physically based material shows its colour with the classic shading.
			if m.roughness > 0 do m.shading = {}
			if s.from == .Object {
				c := shading_object_color(f.obj)
				m.selected, m.idle = c, {c.r * 0.82, c.g * 0.82, c.b * 0.84, 1}
			}
			if mode == .Clay {
				if s.from == .Material do m.selected, m.idle = {1, 1, 1, 1}, MATCAP_IDLE
				d.matcap = shading_matcap(app, s)
			} else if mode == .Flat {
				d.matcap = 0
			}
			d.material = m.shading
			if s.from == .Object || mode == .Clay {
				d.color = material_draw_tint(app, f.obj, f.index, m)
				if d.textured != nil do d.color = textured_color(d.color, m, f.base_map && d.texture_view == .Textured)
			}
		case .Full, .Rendered:
			// The textured preview's base colour stands for the material's.
			if d.textured != nil && d.texture_view == .Off {
				d.texture_view = .Textured
				d.color = textured_color(f.tint, f.material, f.base_map)
			}
		}
		if s.grey > 0 && mode != .Flat && mode != .Rendered {
			// Clay's clay is the MatCap as it is, white; the others' a clay grey.
			clay := m
			clay.selected, clay.idle = SHADING_CLAY, SHADING_CLAY_IDLE
			if mode == .Clay do clay.selected, clay.idle = {1, 1, 1, 1}, MATCAP_IDLE
			c := material_draw_tint(app, f.obj, f.index, clay)
			d.fade = {c.r, c.g, c.b, clamp(s.grey, 0, 1)}
		}
	}
}

// Which kind of tool the main view's look follows while Each tool keeps its look is on
// (look_group_frame): sculpting, painting, or lighting while the Lights section shows.
Look_Group :: enum u8 {Sculpt, Paint, Lights}

@(rodata)
LOOK_GROUP_WORDS := [Look_Group]string {
	.Sculpt = "sculpt",
	.Paint  = "paint",
	.Lights = "lights",
}

@(rodata)
LOOK_GROUP_TITLES := [Look_Group]string {
	.Sculpt = "sculpting",
	.Paint  = "painting",
	.Lights = "lighting",
}

// Each group's look until the person picks another: sculpting and painting as a fresh
// view shows, and lighting in Full, where the lights' reflections on the materials show.
@(rodata)
LOOK_GROUP_DEFAULTS := [Look_Group]View_Shading {
	.Sculpt = {},
	.Paint  = {},
	.Lights = {mode = .Full},
}

// The look of group `g` as it stands: the one shown for the group the view is in, the
// one kept for the others.
look_of :: proc(k: ^Kit_State, g: Look_Group) -> ^View_Shading {
	return &k.passes.shading if g == k.passes.group else &k.passes.looks[g]
}

// The group the main view's look follows this frame: Lights while the Lights section is on
// screen, otherwise the tool's, which the Paint brush makes Paint and every other tool
// Sculpt; Mask and Smooth, which both kinds of work use, keep the tool's group as it was.
// Sculpt alone while Each tool keeps its look is off.
look_group_now :: proc(app: ^App) -> Look_Group {
	k := &app.kit
	if !k.look_per_tool {
		k.passes.tool_group = .Sculpt
		return .Sculpt
	}
	if app.tool != .Brush do k.passes.tool_group = .Sculpt
	else if app.brush.kind == .Paint do k.passes.tool_group = .Paint
	else if app.brush.kind != .Mask && app.brush.kind != .Smooth do k.passes.tool_group = .Sculpt
	return .Lights if lights_section_shown(app) else k.passes.tool_group
}

// At the start of a frame: a change of group keeps the look shown as the old group's and
// shows the new group's, the Render switch going off for a look other than Full. The
// layout holds every group's look, so a change of group is no change of layout.
look_group_frame :: proc(app: ^App) {
	k := &app.kit
	g := look_group_now(app)
	if g == k.passes.group do return
	k.passes.looks[k.passes.group] = k.passes.shading
	k.passes.shading = k.passes.looks[g]
	k.passes.group = g
	k.passes.group_switches += 1
	if k.passes.shading.mode != .Full && render_switch_on(app) do render_set(app, false, app.render_quality)
}

// The shading's lines in a layout, one a group (`shading <group> <look> <colour from>
// <grey> <matcap>`), each written only when it is not that group's default.
shading_layout_line :: proc(k: ^Kit_State) -> string {
	out := strings.builder_make(context.temp_allocator)
	for g in Look_Group {
		s := look_of(k, g)^
		if s != LOOK_GROUP_DEFAULTS[g] do fmt.sbprintf(&out, "shading %s %s\n", LOOK_GROUP_WORDS[g], shading_words(s))
	}
	return strings.to_string(out)
}

// Every group's look as it starts, before a layout's lines are read.
shading_layout_clear :: proc(k: ^Kit_State) {
	k.passes.looks = LOOK_GROUP_DEFAULTS
	k.passes.shading = LOOK_GROUP_DEFAULTS[k.passes.group]
}

// Shading `s` as a layout's words: `<look> <colour from> <grey> <matcap>`.
shading_words :: proc(s: View_Shading) -> string {
	return fmt.tprintf("%v %v %.2f %d", s.mode, s.from, s.grey, s.matcap)
}

// Second view `sv`'s shading as words after its pass in a layout's line, a space first;
// none for a fresh view's.
second_shading_words :: proc(sv: ^Second_View) -> string {
	if sv.shading == {} do return ""
	return fmt.tprintf(" %s", shading_words(sv.shading))
}

// Reads a layout's shading line: its group's word, then the look's words.
shading_layout_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) < 2 do return
	for g in Look_Group do if f[1] == LOOK_GROUP_WORDS[g] do shading_words_read(look_of(k, g), f[2:])
}

// Reads shading words `f` into `s`; a word naming nothing keeps what was there, and
// Rendered is never read, as the Render switch (or a view's Render pass) says it.
shading_words_read :: proc(s: ^View_Shading, f: []string) {
	if len(f) > 0 do for m in Shading_Mode do if m != .Rendered && fmt.tprint(m) == f[0] do s.mode = m
	if len(f) > 1 do for c in Colour_From do if fmt.tprint(c) == f[1] do s.from = c
	if len(f) > 2 {
		if g, ok := strconv.parse_f32(f[2]); ok do s.grey = clamp(g, 0, 1)
	}
	if len(f) > 3 {
		if n, ok := strconv.parse_int(f[3]); ok && n >= 0 do s.matcap = n
	}
}
