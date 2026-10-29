package main

import "core:math"
import "core:testing"

import "../camera"

// Where `p` shows in the view of `c`, in clip space over w: what stays put on screen.
@(private = "file")
shown_at :: proc(c: camera.Orbit, p: Vec3) -> [2]f32 {
	v := camera.orbit_proj(c, 16.0 / 9) * camera.orbit_view(c) * [4]f32{p.x, p.y, p.z, 1}
	return {v.x / v.w, v.y / v.w}
}

// Twisting about the model's point under the tip turns the picture as far as the pen
// turned, clockwise for clockwise, and leaves that point on its pixel, nearer or further
// than the target alike.
@(test)
twist_keeps_the_hovered_point_on_its_pixel :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	for hit in ([?]Vec3{{0.4, 0.3, 0.9}, {-0.7, -0.2, -0.5}, {0, 0, 0}}) {
		app.camera = camera.orbit_default()
		was := shown_at(app.camera, hit)
		tw := Pen_Twist{live = true, action = .Twist, hit = hit, from = 0}
		pen_roll_apply(&app, &tw, 30, {1600, 900})
		pen_roll_apply(&app, &tw, 30, {1600, 900})
		testing.expectf(t, abs(app.camera.roll - math.to_radians(f32(60))) < 1e-4, "rolled %v", app.camera.roll)
		now := shown_at(app.camera, hit)
		testing.expectf(t, abs(now.x - was.x) < 1e-4 && abs(now.y - was.y) < 1e-4, "%v moved from %v to %v", hit, was, now)
	}
}

// The twist holds level for the last few degrees on its way there, as two fingers' twist
// does, and back the other way past it.
@(test)
twist_holds_level :: proc(t: ^testing.T) {
	app: App
	app.camera = camera.orbit_default()
	tw := Pen_Twist{live = true, action = .Twist, hit = Vec3{}}
	pen_roll_apply(&app, &tw, 20, {1600, 900})
	pen_roll_apply(&app, &tw, -17, {1600, 900})
	testing.expect_value(t, app.camera.roll, 0)
	pen_roll_apply(&app, &tw, -20, {1600, 900})
	testing.expect(t, app.camera.roll < 0)
}

// Undo and redo step History a step for every ROLL_HISTORY_STEP degrees, and the pen's
// size roll doubles the size for a quarter turn, as the island's does.
@(test)
roll_values_and_steps :: proc(t: ^testing.T) {
	app: App
	app.brush.radius_px = 50
	tw := Pen_Twist{live = true, action = .Size}
	pen_roll_apply(&app, &tw, 90, {1600, 900})
	testing.expectf(t, abs(app.brush.radius_px - 100) < 0.01, "size %v", app.brush.radius_px)
	tw = {live = true, action = .History}
	pen_roll_apply(&app, &tw, -ROLL_HISTORY_STEP + 1, {1600, 900})
	testing.expect_value(t, tw.steps, f32(-ROLL_HISTORY_STEP + 1))
	// Nothing to undo: the steps start over rather than piling up.
	pen_roll_apply(&app, &tw, -2, {1600, 900})
	testing.expect_value(t, tw.steps, 0)
}

// A pencil out of hover range counts as over the model; one hovering empty view space
// runs the empty-space slots, which start on Frame for a double-tap.
@(test)
pencil_gestures_follow_where_the_pen_points :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	app.camera = camera.orbit_default()
	app.device.pointer = .Pen
	app.pen_twist.size = {800, 600}
	app.device.mouse = {20, 20}
	testing.expect_value(t, pen_area_now(&app), Pen_Area.Model)
	testing.expect_value(t, pencil_slot_here(&app, .Pen_Double_Tap), Gesture_Slot.Pen_Double_Tap)
	app.pencil.about = true
	testing.expect_value(t, pen_area_now(&app), Pen_Area.Empty)
	testing.expect_value(t, pencil_slot_here(&app, .Pen_Double_Tap), Gesture_Slot.Pen_Double_Tap_Empty)
	testing.expect_value(t, pencil_slot_here(&app, .Pen_Squeeze), Gesture_Slot.Pen_Squeeze_Empty)
	testing.expect_value(t, pencil_slot_here(&app, .Pen_Button_2), Gesture_Slot.Pen_Button_2)
	testing.expect_value(t, app.nav.gestures[.Pen_Double_Tap_Empty], Pie_Slot{.Frame_All, 0})
	// With no alpha turning with the pen, the roll over the model twists the view.
	testing.expect_value(t, pen_roll_action(&app, .Model), Roll_Action.Twist)
	free_all(context.temp_allocator)
}

// While grabbing, the pen's roll turns what is held once it passed ui.ROLL_ENGAGE, the
// short way round where its numbers wrap; with Roll while grabbing off it turns nothing.
@(test)
grab_twist_counts_past_the_engage :: proc(t: ^testing.T) {
	app: App
	app.nav = NAV_DEFAULT
	app.stroke.grab_roll = 170
	testing.expect_value(t, grab_twist_angle(&app, 178), 0)
	got := grab_twist_angle(&app, -160)
	testing.expectf(t, abs(got - math.to_radians(f32(20))) < 1e-5, "turned %v", got)
	app.nav.grab_twist = false
	testing.expect_value(t, grab_twist_angle(&app, -150), 0)
}
