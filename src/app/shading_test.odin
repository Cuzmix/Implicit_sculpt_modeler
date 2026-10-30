package main

import "core:strings"
import "core:testing"

import "../render"

// Each mode rewrites the main view's copy of an item from what it was made of: Solid shows
// a metal's colour with the classic shading and its MatCap and colour choices, Flat and
// Wireframe draw in their own passes, Wireframe draws every edge with no paint, and Material
// Preview keeps the material whole.
@(test)
shading_modes_rewrite_items :: proc(t: ^testing.T) {
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

	solid := shade(app, made, from, {})
	testing.expect_value(t, solid.surface, [2]f32{})
	testing.expect_value(t, solid.color, m.selected)
	testing.expect(t, solid.paint)
	testing.expect_value(t, shading_pass(app, {}, .Shaded), render.View_Pass.Shaded)

	single := shade(app, made, from, {color = .Single})
	testing.expect_value(t, single.color, SOLID_SINGLE)
	object := shade(app, made, from, {color = .Object})
	testing.expect_value(t, object.color, shading_object_color(&obj))
	testing.expect(t, shading_object_color(&obj) != shading_object_color(&Object{id = 4}))

	flat := View_Shading{lighting = .Flat}
	testing.expect_value(t, shading_pass(app, flat, .Shaded), render.View_Pass.Unlit)
	// A pass that checks the form shows over any mode.
	testing.expect_value(t, shading_pass(app, flat, .Normals), render.View_Pass.Normals)

	wire := shade(app, made, from, {mode = .Wireframe})
	testing.expect(t, wire.wireframe && !wire.paint)
	testing.expect_value(t, shading_pass(app, {mode = .Wireframe}, .Shaded), render.View_Pass.Wire)

	preview := shade(app, made, from, {mode = .Material_Preview})
	testing.expect_value(t, preview.surface, made.surface)
	testing.expect_value(t, shading_pass(app, {mode = .Material_Preview}, .Shaded), render.View_Pass.Shaded)
}

// The mode and Solid's options go in a workspace's layout and come back from it, a fresh
// view's writing nothing; a layout without the line puts a view back to Solid.
@(test)
shading_is_kept_in_the_layout :: proc(t: ^testing.T) {
	a: Kit_State
	testing.expect_value(t, shading_layout_line(&a), "")
	a.passes.shading = {mode = .Wireframe, lighting = .MatCap, color = .Object, matcap = 5}
	text := kit_layout_text(&a)
	b: Kit_State
	kit_layout_put(&b, text)
	testing.expect_value(t, b.passes.shading, a.passes.shading)
	kit_layout_put(&b, "")
	testing.expect_value(t, b.passes.shading, View_Shading{})
	// Rendered is the Render switch's, never a layout's.
	shading_layout_read(&b, []string{"shading", "Rendered"})
	testing.expect_value(t, b.passes.shading.mode, Shading_Mode.Solid)
}

// A view pane keeps its own shading in the layout's pane line, after its pass; a line
// without it (a layout from before) is a fresh view's, Solid.
@(test)
pane_shading_is_kept_in_the_layout :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	_, _ = grid_set(k, .Side_By_Side)
	k.grid.views[0].shading = {mode = .Wireframe, lighting = .Flat}
	text := kit_layout_text(k)
	testing.expect(t, strings.contains(text, "pane 1 Front Shaded Wireframe Flat Material 0\n"), "the pane's shading is not written")
	k.grid.views[0].shading = {}
	kit_layout_put(k, text)
	testing.expect_value(t, k.grid.views[0].shading, View_Shading{mode = .Wireframe, lighting = .Flat})
	kit_layout_put(k, "panes v500 0 1\npane 1 Top Shaded\n")
	testing.expect_value(t, k.grid.views[0].shading, View_Shading{})
}

// A view's Shows list names its shading mode while it shows Shaded, Rendered for its Render
// pass and the pass otherwise; picking a mode keeps Solid's options.
@(test)
second_shows_names_modes_and_passes :: proc(t: ^testing.T) {
	sv := Second_View{pass = .Shaded, shading = {lighting = .MatCap}}
	testing.expect_value(t, second_shows_name(&sv), "Solid")
	second_shows_set(&sv, 0)
	testing.expect_value(t, second_shows_name(&sv), "Wireframe")
	testing.expect_value(t, sv.shading.lighting, Solid_Lighting.MatCap)
	second_shows_set(&sv, 3)
	testing.expect_value(t, sv.pass, Second_Pass.Render)
	testing.expect_value(t, second_shows_name(&sv), "Rendered")
	testing.expect_value(t, second_shows_index(&sv), 3)
	sv.pass = .Curvature
	testing.expect_value(t, second_shows_name(&sv), "Curvature")
	testing.expect_value(t, SECOND_SHOWS[second_shows_index(&sv)].pass, Second_Pass.Curvature)
	// Every pass is in the list once.
	for p in Second_Pass {
		n := 0
		for e in SECOND_SHOWS do if e.pass == p do n += 1
		testing.expect_value(t, n, 3 if p == .Shaded else 1)
	}
}
