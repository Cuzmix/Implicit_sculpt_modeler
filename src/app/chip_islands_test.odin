package main

import "core:strings"
import "core:testing"

import "../ui"

// The chip bar's islands are a setting: written as chip_island lines, read back, and a line
// this version cannot take (another section, a number that is not one) leaves the section in
// the bar. A workspace's layout neither writes them nor puts them back.
@(test)
chip_islands_read_back :: proc(t: ^testing.T) {
	a: Kit_State
	a.islands[.Undo] = [2]f32{600, 300}
	a.islands[.Search] = [2]f32{20.5, 60}
	out := strings.builder_make(context.temp_allocator)
	chip_islands_save(&a, &out)
	text := strings.to_string(out)
	testing.expect_value(t, text, "chip_island undo 600 300\nchip_island search 20.5 60\n")
	testing.expect_value(t, chip_islands_text(&a), "undo:600:300,search:20:60")
	b: Kit_State
	for line in strings.split_lines(text, context.temp_allocator) do chip_island_read(&b, strings.fields(line, context.temp_allocator))
	testing.expect_value(t, b.islands, a.islands)
	testing.expect(t, !strings.contains(kit_layout_text(&b), "chip_island"))
	kit_layout_put(&b, "hidden\n")
	testing.expect_value(t, b.islands, a.islands)
	c: Kit_State
	for line in ([]string{"chip_island tray 1 2", "chip_island undo NaN 0", "chip_island menu 0 inf", "chip_island end 4"}) do chip_island_read(&c, strings.fields(line, context.temp_allocator))
	testing.expect(t, chip_islands_none(&c))
	testing.expect_value(t, chip_islands_text(&c), "none")
	free_all(context.temp_allocator)
}

// A section let go over the bar (or just past its edge) goes back in it; let go elsewhere
// it stands where its outline was, under the bar's band, mirrored for a left hand.
@(test)
chip_sections_drop_where_they_are_let_go :: proc(t: ^testing.T) {
	app: App
	defer results_destroy(&app)
	defer ui.destroy(&app.kit.ctx)
	k := &app.kit
	ctx := &k.ctx
	ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	ui.begin_anchored(ctx, "top bar", .Start, .Start, {TOP_BAR_INSET, TOP_BAR_TOP}, {width = 1584, height = TOP_BAR_H - TOP_BAR_TOP})
	ui.end(ctx)
	ui.frame_end(ctx)
	ui.frame_begin(ctx, {window = {1600, 900}, pixel_density = 1, dt = 1.0 / 60})
	testing.expect_value(t, chip_island_drop(&app, {500, 10, 90, 44}, {540, 30}), nil)
	testing.expect_value(t, chip_island_drop(&app, {500, 50, 90, 44}, {540, TOP_BAR_H + CHIP_BAR_REACH - 2}), nil)
	testing.expect_value(t, chip_island_drop(&app, {500.4, 300.6, 90, 44}, {540, 320}), [2]f32{500, 301})
	// Let go just under the bar's reach, it still stands under the band.
	at := chip_island_drop(&app, {500, 40, 90, 44}, {540, TOP_BAR_H + CHIP_BAR_REACH + 40}).?
	testing.expect_value(t, at.y, chip_island_top())
	ctx.mirror = true
	testing.expect_value(t, chip_island_drop(&app, {500, 300, 90, 44}, {540, 320}), [2]f32{1010, 300})
	ctx.mirror = false
	ui.frame_end(ctx)
	free_all(context.temp_allocator)
}

// The top bar's islands snap to the third of the bar under the pointer, counted from the
// start side, and trade places with the island there; the order is written only when it
// differs from the bar as it comes, and a line not naming each island once is refused.
@(test)
top_islands_snap_and_read_back :: proc(t: ^testing.T) {
	bar := ui.Rect{8, 4, 1200, 48}
	testing.expect_value(t, top_island_slot(bar, 100, false), 0)
	testing.expect_value(t, top_island_slot(bar, 600, false), 1)
	testing.expect_value(t, top_island_slot(bar, 1100, false), 2)
	testing.expect_value(t, top_island_slot(bar, 1100, true), 0)
	testing.expect_value(t, top_island_slot({}, 1100, false), 1)
	testing.expect_value(t, top_order_put(TOP_ORDER_DEFAULT, .File, 2), [3]Top_Island{.App, .Work, .File})
	testing.expect_value(t, top_order_put(TOP_ORDER_DEFAULT, .App, 1), [3]Top_Island{.File, .App, .Work})
	testing.expect_value(t, top_order_put(TOP_ORDER_DEFAULT, .Work, 1), TOP_ORDER_DEFAULT)

	a: Kit_State
	testing.expect_value(t, top_order(&a), TOP_ORDER_DEFAULT)
	out := strings.builder_make(context.temp_allocator)
	top_order_save(&a, &out)
	testing.expect_value(t, strings.to_string(out), "")
	a.top_order = {.Work, .App, .File}
	top_order_save(&a, &out)
	text := strings.to_string(out)
	testing.expect_value(t, text, "top_order work app file\n")
	b: Kit_State
	top_order_read(&b, strings.fields(text, context.temp_allocator))
	testing.expect_value(t, top_order_text(&b), "work,app,file")
	c: Kit_State
	for line in ([]string{"top_order work work file", "top_order work app", "top_order work app tray"}) do top_order_read(&c, strings.fields(line, context.temp_allocator))
	testing.expect_value(t, top_order_text(&c), "file,work,app")
}
