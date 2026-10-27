package main

import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"
import "../render"

@(test)
a_layout_holds_the_pass_but_never_a_peek :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	k: Kit_State
	bars_reset(&k)
	panels_default(&k)
	k.inspector = true
	shaded := kit_layout_text(&k)
	testing.expect(t, shaded == built_in_layout(.Sculpt), "Shaded writes a pass line")
	testing.expect(t, !strings.contains(shaded, "pass"), "Shaded writes a pass line")

	// A pass is written and read back; a peek changes what shows, never the layout.
	pass_set(&k, .Curvature)
	text := kit_layout_text(&k)
	testing.expect(t, strings.contains(text, "pass Curvature\n"), "the pass is not written")
	k.passes.chip_held = true
	testing.expect_value(t, viewport_pass(&k), render.View_Pass.Shaded)
	testing.expect(t, kit_layout_text(&k) == text, "a peek changed the layout")

	// Putting a layout ends the peek and sets its pass, Shaded where it names none.
	kit_layout_put(&k, shaded)
	testing.expect(t, k.passes.pass == .Shaded && !k.passes.chip_held, "a layout without a pass kept one, or the peek")
	kit_layout_put(&k, text)
	testing.expect_value(t, k.passes.pass, render.View_Pass.Curvature)
}

@(test)
last_pass_flips_between_two_passes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	a: App
	k := &a.kit
	// With no other pass yet a peek shows Normals; then the last one.
	testing.expect_value(t, pass_peeked(k), render.View_Pass.Normals)
	command_run(&a, .View_Pass, int(render.View_Pass.Depth))
	testing.expect_value(t, k.passes.pass, render.View_Pass.Depth)
	testing.expect_value(t, pass_peeked(k), render.View_Pass.Shaded)
	// Picking the pass shown leaves it; Last pass flips back.
	command_run(&a, .View_Pass, int(render.View_Pass.Depth))
	testing.expect_value(t, k.passes.pass, render.View_Pass.Depth)
	command_run(&a, .View_Pass_Last)
	testing.expect_value(t, k.passes.pass, render.View_Pass.Shaded)
	testing.expect_value(t, pass_peeked(k), render.View_Pass.Depth)
	testing.expect_value(t, k.passes.switches, 2)
	// A recording takes every frame in the pass picked, peek or not.
	k.passes.key_held = true
	testing.expect_value(t, viewport_pass(k), render.View_Pass.Depth)
	k.passes.recording = true
	testing.expect_value(t, viewport_pass(k), render.View_Pass.Shaded)

	// Keymaps and scripts name a pass by its enum name.
	id, arg, ok := command_from_name("View_Pass:Silhouette")
	testing.expect(t, ok && id == .View_Pass && render.View_Pass(arg) == .Silhouette, "View_Pass:Silhouette names no pass")
	_, reserved := chord_reserved({key = sdl.K_GRAVE})
	testing.expect(t, reserved, "backquote, which peeks, can be bound")
}

@(test)
pass_items_mark_every_draw_and_shaded_clears_them :: proc(t: ^testing.T) {
	m: render.Mesh_Buffers
	// With nothing to measure, Depth's range is the plain 0 to 1.
	items := []render.Draw_Item{{mesh = &m}}
	view := render.Mat4(1)
	pass_items(items, view, .Depth)
	testing.expect_value(t, items[0].pass, [4]f32{f32(render.View_Pass.Depth), 0, 1, 0})
	pass_items(items, view, .Shaded)
	testing.expect_value(t, items[0].pass, [4]f32{})
}
