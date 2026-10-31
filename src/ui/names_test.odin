package ui

import "core:strings"
import "core:testing"

@(private = "file")
still :: proc() -> Input {
	return {mouse = {-1, -1}, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60}
}

// A bar of two buttons, a panel holding a row of tabs and a dimmed button, and a button
// clipped out of sight, in one frame.
@(private = "file")
named_frame :: proc(ctx: ^Context, undo_label: string) {
	frame_begin(ctx, still())
	begin_anchored(ctx, "bar", .Start, .Start, {16, 16}, {direction = .Row, gap = 8})
	_ = icon_button(ctx, undo_label, ICON_UNDO)
	_ = icon_button(ctx, "Redo", ICON_REDO, enabled = false)
	end(ctx)
	begin_anchored(ctx, "panel", .End, .Start, {16, 16}, {width = 300})
	_ = tabs(ctx, "Shading", {"Solid", "Material"}, 0)
	_ = button(ctx, "Apply", enabled = false)
	end(ctx)
	begin_anchored(ctx, "hidden", .Start, .Start, {16, 300}, {height = 1, clip = true})
	_ = icon_button(ctx, "Out of sight", ICON_UNDO)
	end(ctx)
	frame_end(ctx)
}

// With the map on, a control is found by its shown label or its "##" key, with or without
// the containers it sits in, dimmed ones too, from the frame last finished; a control
// clipped out of sight, a wrong container and an unknown name are not found; with the map
// off nothing is recorded.
@(test)
names_find_controls_by_label_key_and_path :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	named_frame(&ctx, "Undo stroke##undo")
	_, count := named_find(&ctx, "Redo")
	testing.expect_value(t, count, 0)

	names_show(&ctx, true)
	named_frame(&ctx, "Undo stroke##undo")
	named_frame(&ctx, "Undo stroke##undo")
	by_label, n1 := named_find(&ctx, "undo stroke")
	by_key, n2 := named_find(&ctx, "bar/undo")
	testing.expect_value(t, n1, 1)
	testing.expect_value(t, n2, 1)
	testing.expect_value(t, by_label, by_key)
	testing.expect(t, by_label.x >= 16 && by_label.y >= 16 && by_label.w > 0, "the button's rectangle")
	redo, n3 := named_find(&ctx, "Redo")
	testing.expect_value(t, n3, 1)
	testing.expect(t, redo.x > by_label.x, "Redo lies right of Undo")
	_, n4 := named_find(&ctx, "panel/Shading/Material")
	testing.expect_value(t, n4, 1)
	_, n5 := named_find(&ctx, "Apply")
	testing.expect_value(t, n5, 1)
	_, n6 := named_find(&ctx, "bar/Material")
	testing.expect_value(t, n6, 0)
	_, n7 := named_find(&ctx, "Out of sight")
	testing.expect_value(t, n7, 0)
	_, n8 := named_find(&ctx, "Nothing")
	testing.expect_value(t, n8, 0)

	b := strings.builder_make(context.temp_allocator)
	names_write(&ctx, &b)
	written := strings.to_string(b)
	testing.expect(t, strings.contains(written, "bar/Undo stroke##undo\t"), written)
	testing.expect(t, strings.contains(written, "panel/Shading/Material\t"), written)
	free_all(context.temp_allocator)
}
