package ui

import "core:testing"

// A window of 800 by 600 points with the pointer off it.
@(private = "file")
still :: proc() -> Input {
	return {mouse = {-1, -1}, window = {800, 600}, pixel_density = 1, dt = 1.0 / 60}
}

// A row of icon buttons and a scrolled-away one, in one frame.
@(private = "file")
labelled_frame :: proc(ctx: ^Context, input: Input) {
	frame_begin(ctx, input)
	begin_anchored(ctx, "bar", .Start, .Start, {16, 16}, {direction = .Row, gap = 8})
	_ = icon_button(ctx, "Undo", ICON_UNDO, keys = "Ctrl+Z")
	_ = icon_button(ctx, "Redo", ICON_REDO, keys = "Ctrl+Shift+Z")
	end(ctx)
	// A container 1 point tall that clips: its button is hidden, so it gets no tag.
	begin_anchored(ctx, "hidden", .Start, .Start, {16, 300}, {height = 1, clip = true})
	_ = icon_button(ctx, "Hidden", ICON_UNDO)
	end(ctx)
	frame_end(ctx)
}

// While the labels show, every control with a tooltip gets its tag at once, no pointer
// resting on it, one for each control shown; a control clipped away whole gets none, the
// tags come in one after another, and with the labels off nothing is tagged.
@(test)
labels_name_every_shown_control :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	labelled_frame(&ctx, still())
	testing.expect_value(t, ctx.labels.drawn, 0)
	plain := len(ctx.draw.vertices)

	labels_show(&ctx, true)
	labelled_frame(&ctx, still())
	// The second tag waits its stagger: only the first is drawn on the first frame.
	testing.expect_value(t, ctx.labels.drawn, 1)
	for _ in 0 ..< 30 do labelled_frame(&ctx, still())
	testing.expect_value(t, ctx.labels.drawn, 2)
	testing.expect_value(t, ctx.labels.dropped, 0)
	testing.expect(t, len(ctx.draw.vertices) > plain, "the tags drew nothing")

	// With motion off they appear together.
	labels_show(&ctx, false)
	labelled_frame(&ctx, still())
	testing.expect_value(t, ctx.labels.drawn, 0)
	ctx.motion = .Off
	labels_show(&ctx, true)
	labelled_frame(&ctx, still())
	testing.expect_value(t, ctx.labels.drawn, 2)
}

// Tags never overlap: two controls on top of each other get one tag below and the other
// above, a control named twice gets one, and a tag with nowhere outside the app's clear
// rectangle is dropped.
@(test)
labels_keep_apart :: proc(t: ^testing.T) {
	ctx: Context
	init(&ctx)
	defer destroy(&ctx)
	ctx.motion = .Off
	labels_show(&ctx, true)
	frame_begin(&ctx, still())
	label_add(&ctx, 1, {300, 300, 40, 40}, "First", "1")
	label_add(&ctx, 2, {300, 300, 40, 40}, "Second", "2")
	label_add(&ctx, 2, {300, 300, 40, 40}, "Second again")
	ctx.labels.clear = {0, 0, 800, 200}
	label_add(&ctx, 3, {300, 150, 40, 20}, "Under the note")
	frame_end(&ctx)
	// Every place beside the third is in the clear band, so it is dropped.
	testing.expect_value(t, ctx.labels.drawn, 2)
	testing.expect_value(t, ctx.labels.dropped, 1)
}
