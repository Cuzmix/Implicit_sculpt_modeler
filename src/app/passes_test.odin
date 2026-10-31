package main

import "core:strings"
import "core:testing"
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
	_, reserved := chord_reserved({key = KEY_GRAVE})
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

@(test)
a_wipe_packs_its_line_and_right_pass_into_the_last_field :: proc(t: ^testing.T) {
	m: render.Mesh_Buffers
	items := []render.Draw_Item{{mesh = &m}}
	view := render.Mat4(1)
	// The shader takes the line as floor((w - 1) / 8) and the right pass as what is left.
	pass_items(items, view, .Shaded, .Normals, 960)
	w := items[0].pass.w - 1
	line := f32(int(w / 8))
	testing.expect_value(t, items[0].pass.x, f32(render.View_Pass.Shaded))
	testing.expect_value(t, line, f32(960))
	testing.expect_value(t, int(w - line * 8 + 0.5), int(render.View_Pass.Normals))
	// Depth on the right measures the range though the left side is Shaded.
	pass_items(items, view, .Shaded, .Depth, 0)
	testing.expect_value(t, items[0].pass, [4]f32{f32(render.View_Pass.Shaded), 0, 1, 1 + f32(render.View_Pass.Depth)})
	// With no wipe the last field is 0, which the shader reads as off.
	pass_items(items, view, .Normals)
	testing.expect_value(t, items[0].pass.w, f32(0))
}

@(test)
the_wipe_line_stays_inside_the_view :: proc(t: ^testing.T) {
	testing.expect_value(t, wipe_line_px(0.5, 1600), f32(800))
	testing.expect_value(t, wipe_line_px(0, 1600), f32(80))
	testing.expect_value(t, wipe_line_px(1, 1600), f32(1520))
	k: Kit_State
	wipe_toggle(&k)
	testing.expect(t, wipe_shown(&k) && k.passes.wipe_at == 0.5, "the first wipe starts in the middle")
	k.passes.wipe_at = 0.7
	wipe_toggle(&k)
	wipe_toggle(&k)
	testing.expect_value(t, k.passes.wipe_at, f32(0.7))
	k.passes.recording = true
	testing.expect(t, !wipe_shown(&k), "a wipe shows while recording")
}
