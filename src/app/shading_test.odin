package main

import "core:strings"
import "core:testing"

import "../render"

// Each look rewrites the main view's copy of an item from what it was made of: Lit shows a
// metal's colour with the classic shading, Clay shades it by the MatCap in white, Flat
// draws in its own pass, Full keeps the material whole, Colour from Object gives each
// object a colour of its own, and the Colour takes the colours toward clay in every look
// but Flat.
@(test)
shading_looks_rewrite_items :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer results_destroy(app)
	obj := Object{id = 3}
	gold, _ := material_by_name("gold")
	m := MATERIALS[gold]
	made := render.Draw_Item{color = m.selected, material = m.shading, surface = {m.metallic, m.roughness}, paint = true}
	from := []Item_From{{obj = &obj, index = 0, tint = m.selected, material = m}}
	shade :: proc(app: ^App, made: render.Draw_Item, from: []Item_From, s: View_Shading) -> render.Draw_Item {
		items := []render.Draw_Item{made}
		shading_items(app, items, from, s)
		return items[0]
	}

	lit := shade(app, made, from, {})
	testing.expect_value(t, lit.surface, [2]f32{})
	testing.expect_value(t, lit.color, m.selected)
	testing.expect_value(t, lit.fade, [4]f32{})
	testing.expect(t, lit.paint)
	testing.expect_value(t, shading_pass(app, {}, .Shaded), render.View_Pass.Shaded)

	clay := shade(app, made, from, {mode = .Clay})
	testing.expect_value(t, clay.color, [4]f32{1, 1, 1, 1})
	object := shade(app, made, from, {from = .Object})
	testing.expect_value(t, object.color, shading_object_color(&obj))
	testing.expect(t, shading_object_color(&obj) != shading_object_color(&Object{id = 4}))

	grey := shade(app, made, from, {grey = 0.25})
	testing.expect_value(t, grey.fade, [4]f32{SHADING_CLAY.r, SHADING_CLAY.g, SHADING_CLAY.b, 0.25})
	testing.expect_value(t, grey.color, m.selected)
	clay_grey := shade(app, made, from, {mode = .Clay, grey = 1})
	testing.expect_value(t, clay_grey.fade, [4]f32{1, 1, 1, 1})

	flat := View_Shading{mode = .Flat, grey = 1}
	testing.expect_value(t, shade(app, made, from, flat).fade, [4]f32{})
	testing.expect_value(t, shading_pass(app, flat, .Shaded), render.View_Pass.Unlit)
	// A pass that checks the form shows over any look.
	testing.expect_value(t, shading_pass(app, flat, .Normals), render.View_Pass.Normals)

	full := shade(app, made, from, {mode = .Full})
	testing.expect_value(t, full.surface, made.surface)
	testing.expect_value(t, shading_pass(app, {mode = .Full}, .Shaded), render.View_Pass.Shaded)
}

// Each group's look and its options go in a space's layout and come back from it, a
// group's default writing nothing; a layout without the lines puts every group back to its
// default.
@(test)
shading_is_kept_in_the_layout :: proc(t: ^testing.T) {
	a: Kit_State
	shading_layout_clear(&a)
	testing.expect_value(t, shading_layout_line(&a), "")
	a.passes.shading = {mode = .Clay, from = .Object, grey = 0.75, matcap = 5}
	a.passes.looks[.Paint] = {mode = .Flat}
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "shading sculpt Clay Object 0.75 skin\nshading paint Flat Material 0.00 -\n"), "the groups' looks are not written")
	b: Kit_State
	kit_layout_put(&b, text)
	testing.expect_value(t, b.passes.shading, a.passes.shading)
	testing.expect_value(t, b.passes.looks[.Paint], View_Shading{mode = .Flat})
	testing.expect_value(t, b.passes.looks[.Lights], View_Shading{})
	kit_layout_put(&b, "")
	testing.expect_value(t, b.passes.shading, View_Shading{})
	testing.expect_value(t, b.passes.looks, LOOK_GROUP_DEFAULTS)
	// Rendered is the Render switch's, never a layout's.
	shading_layout_read(&b, []string{"shading", "sculpt", "Rendered"})
	testing.expect_value(t, b.passes.shading.mode, Shading_Mode.Lit)
}

// Picking the Paint brush shows painting's look and back on a sculpting brush sculpting's,
// each keeping the look picked while it showed; Mask keeps the group it came from, and with
// Each tool keeps its look off the view keeps one look. None of it changes the layout.
@(test)
each_tool_keeps_its_look :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	k.look_per_tool = true
	shading_layout_clear(k)
	app.tool, app.brush.kind = .Brush, .Clay
	look_group_frame(app)
	k.passes.shading.mode = .Clay
	layout := kit_layout_text(k)
	app.brush.kind = .Paint
	look_group_frame(app)
	testing.expect_value(t, k.passes.group, Look_Group.Paint)
	testing.expect_value(t, k.passes.shading.mode, Shading_Mode.Lit)
	k.passes.shading.mode = .Flat
	app.brush.kind = .Mask
	look_group_frame(app)
	testing.expect_value(t, k.passes.shading.mode, Shading_Mode.Flat)
	app.brush.kind = .Draw
	look_group_frame(app)
	testing.expect_value(t, k.passes.shading.mode, Shading_Mode.Clay)
	app.brush.kind = .Paint
	look_group_frame(app)
	testing.expect_value(t, k.passes.shading.mode, Shading_Mode.Flat)
	k.look_per_tool = false
	look_group_frame(app)
	testing.expect_value(t, k.passes.shading.mode, Shading_Mode.Clay)
	k.passes.looks[.Paint].mode = .Flat
	testing.expect(t, strings.contains(kit_layout_text(k), "shading paint Flat"), "painting's look left the layout")
	k.passes.looks[.Paint] = {}
	testing.expect_value(t, kit_layout_text(k), layout)
	testing.expect_value(t, k.passes.group_switches, 4)
}

// A view pane keeps its own shading in the layout's pane line, after its pass; a line
// without it is a fresh view's, Lit.
@(test)
pane_shading_is_kept_in_the_layout :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	_, _ = grid_set(k, .Side_By_Side)
	grid_view(&k.grid, 1).shading = {mode = .Flat, grey = 0.5}
	text := kit_layout_text(k)
	testing.expect(t, strings.contains(text, "pane 1 Front Shaded Flat Material 0.50 -\n"), "the pane's shading is not written")
	grid_view(&k.grid, 1).shading = {}
	kit_layout_put(k, text)
	testing.expect_value(t, grid_view(&k.grid, 1).shading, View_Shading{mode = .Flat, grey = 0.5})
	kit_layout_put(k, "panes v500 0 1\npane 1 Top Shaded\n")
	testing.expect_value(t, grid_view(&k.grid, 1).shading, View_Shading{})
}

// A view's Shows list names its look while it shows Shaded, Rendered for its Render pass
// and the pass otherwise; picking a look keeps its options.
@(test)
second_shows_names_modes_and_passes :: proc(t: ^testing.T) {
	sv := Second_View{pass = .Shaded, shading = {grey = 0.5}}
	testing.expect_value(t, second_shows_name(&sv), "Lit")
	second_shows_set(&sv, 0)
	testing.expect_value(t, second_shows_name(&sv), "Clay")
	testing.expect_value(t, sv.shading.grey, f32(0.5))
	second_shows_set(&sv, 4)
	testing.expect_value(t, sv.pass, Second_Pass.Render)
	testing.expect_value(t, second_shows_name(&sv), "Rendered")
	testing.expect_value(t, second_shows_index(&sv), 4)
	sv.pass = .Curvature
	testing.expect_value(t, second_shows_name(&sv), "Curvature")
	testing.expect_value(t, SECOND_SHOWS[second_shows_index(&sv)].pass, Second_Pass.Curvature)
	// Every pass is in the list once.
	for p in Second_Pass {
		n := 0
		for e in SECOND_SHOWS do if e.pass == p do n += 1
		testing.expect_value(t, n, 4 if p == .Shaded else 1)
	}
}

// A layout names a content pack's MatCap by its pack and file, so a run with other packs
// installed (the list in another order) finds the same picture, and one without that pack
// falls back to Grey clay and counts it for its one warning. Built-ins and the loaded image
// keep their own words.
@(test)
layout_matcaps_survive_other_packs :: proc(t: ^testing.T) {
	make_library :: proc(parts: ..[2]string) -> (lib: Library) {
		for p in parts do append(&lib.matcaps, Pack_Matcap{pack = p[0], stem = p[1]})
		return
	}
	first := make_library({"clay-kit", "warm red"}, {"studio", "chalk"})
	defer delete(first.matcaps)
	a: Kit_State
	a.library = &first
	look_of(&a, .Sculpt)^ = {mode = .Clay, matcap = PACK_MATCAP + 1}
	look_of(&a, .Paint)^ = {mode = .Clay, matcap = PACK_MATCAP}
	look_of(&a, .Lights)^ = {mode = .Clay, matcap = MATCAP_IMAGE}
	text := shading_layout_line(&a)
	testing.expect(t, strings.contains(text, "pack:studio/chalk"), text)
	testing.expect(t, strings.contains(text, "pack:clay-kit/warm%20red"), text)

	// The same packs in another order, and one more.
	other := make_library({"extra", "glass"}, {"studio", "chalk"}, {"clay-kit", "warm red"})
	defer delete(other.matcaps)
	b: Kit_State
	b.library = &other
	for line in strings.split_lines(text, context.temp_allocator) {
		if line != "" do shading_layout_read(&b, strings.fields(line, context.temp_allocator))
	}
	testing.expect_value(t, look_of(&b, .Sculpt).matcap, PACK_MATCAP + 1)
	testing.expect_value(t, look_of(&b, .Paint).matcap, PACK_MATCAP + 2)
	testing.expect_value(t, look_of(&b, .Lights).matcap, MATCAP_IMAGE)
	testing.expect_value(t, b.matcaps_missing, 0)

	// Without the studio pack: Grey clay, the default, said once.
	fewer := make_library({"clay-kit", "warm red"})
	defer delete(fewer.matcaps)
	c: Kit_State
	c.library = &fewer
	for line in strings.split_lines(text, context.temp_allocator) {
		if line != "" do shading_layout_read(&c, strings.fields(line, context.temp_allocator))
	}
	testing.expect_value(t, look_of(&c, .Sculpt).matcap, 0)
	testing.expect_value(t, look_of(&c, .Paint).matcap, PACK_MATCAP)
	testing.expect_value(t, c.matcaps_missing, 1)

	// A built-in by its word, and a number, which no layout writes, read as the default.
	testing.expect_value(t, shading_matcap_key(nil, 3), "grey-clay")
	m, missing := shading_matcap_from_key(nil, "grey-clay")
	testing.expect(t, m == 3 && !missing)
	m, missing = shading_matcap_from_key(nil, "3")
	testing.expect(t, m == 0 && !missing)
}
