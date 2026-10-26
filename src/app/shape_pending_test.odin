package main

import "core:testing"

import "../ui"

// Auto applies the mouse's shapes at once and waits for a finger's or the pen's; Now and
// Confirm do the same for every pointer.
@(test)
shapes_apply_by_pointer :: proc(t: ^testing.T) {
	for pointer in ui.Pointer_Kind {
		testing.expect_value(t, shape_apply_now(.Auto, pointer), pointer == .Mouse)
		testing.expect(t, shape_apply_now(.Now, pointer))
		testing.expect(t, !shape_apply_now(.Confirm, pointer))
	}
}

@(private = "file")
pending_app :: proc(app: ^App, kind: Shape_Kind, points: ..[2]f32) {
	app.kit.scale = 1
	app.kit.ctx.theme.target = 48
	app.nav.shape_apply = .Confirm
	app.tool = .Brush
	shape_finish(app, kind, points, kind == .Mask, false, {1000, 800}, .Finger)
}

// A press finds a handle within half a touch target and no further; the middle comes
// last; a lasso has only the middle.
@(test)
shape_handles_take_a_finger :: proc(t: ^testing.T) {
	app: App
	defer shape_pending_destroy(&app.shape_pending)
	pending_app(&app, .Mask, {100, 100}, {300, 200})
	testing.expect_value(t, app.shape_pending.kind, Shape_Kind.Mask)
	testing.expect_value(t, shape_handle_at(&app, {100 + 23, 100}), 0)
	testing.expect_value(t, shape_handle_at(&app, {100 + 25, 100}), -1)
	testing.expect_value(t, shape_handle_at(&app, {300, 100}), 1)
	testing.expect_value(t, shape_handle_at(&app, {300, 210}), 2)
	testing.expect_value(t, shape_handle_at(&app, {200, 150}), 4)
	// Another tool: no handles to take.
	app.tool = .Move
	testing.expect_value(t, shape_handle_at(&app, {100, 100}), -1)
	app.tool = .Brush
	lasso := [?][2]f32{{0, 0}, {100, 0}, {50, 80}}
	shape_finish(&app, .Hide, lasso[:], false, false, {1000, 800}, .Finger)
	_, n := shape_handles(&app.shape_pending)
	testing.expect_value(t, n, 1)
}

// A corner moves its two edges, the middle moves it all, and a cancelled drag puts it
// back.
@(test)
shape_handles_drag :: proc(t: ^testing.T) {
	app: App
	defer shape_pending_destroy(&app.shape_pending)
	pending_app(&app, .Mask, {100, 100}, {300, 200})
	p := &app.shape_pending
	shape_grab(&app, 1) // the top right corner
	shape_drag(&app, {10, -5})
	shape_release(&app, false)
	testing.expect_value(t, p.points[0], [2]f32{100, 95})
	testing.expect_value(t, p.points[1], [2]f32{310, 200})
	shape_grab(&app, 4)
	shape_drag(&app, {-50, 0})
	testing.expect_value(t, p.points[0], [2]f32{50, 95})
	shape_release(&app, true)
	testing.expect_value(t, p.points[0], [2]f32{100, 95})
	testing.expect_value(t, p.grab, -1)
}

// A taller window scales the shape about the middle by the change in height, as the
// view's projection does; a wider one only moves it with the middle.
@(test)
shape_follows_the_window :: proc(t: ^testing.T) {
	app: App
	defer shape_pending_destroy(&app.shape_pending)
	pending_app(&app, .Clip, {500, 400}, {600, 400})
	shape_pending_frame(&app, {1000, 1600})
	p := &app.shape_pending
	testing.expect_value(t, p.points[0], [2]f32{500, 800})
	testing.expect_value(t, p.points[1], [2]f32{700, 800})
	shape_pending_frame(&app, {2000, 1600})
	testing.expect_value(t, p.points[0], [2]f32{1000, 800})
	testing.expect_value(t, p.size, [2]f32{2000, 1600})
}

// Apply needs a selected object and a shape that is still one; leaving the Brush tool
// lets the shape go.
@(test)
shape_apply_needs_a_shape :: proc(t: ^testing.T) {
	app: App
	defer shape_pending_destroy(&app.shape_pending)
	defer delete(app.scene.objects)
	app.device.pointer = .Mouse
	pending_app(&app, .Mask, {100, 100}, {300, 200})
	testing.expect(t, !shape_can_apply(&app))
	obj: Object
	append(&app.scene.objects, &obj)
	app.scene.selected = 0
	testing.expect(t, shape_can_apply(&app))
	// Dragged down to a dot.
	shape_grab(&app, 2)
	shape_drag(&app, {-199, -99})
	shape_release(&app, false)
	testing.expect(t, !shape_can_apply(&app))
	app.tool = .Move
	shape_pending_frame(&app, {1000, 800})
	testing.expect_value(t, app.shape_pending.kind, Shape_Kind.None)
}
