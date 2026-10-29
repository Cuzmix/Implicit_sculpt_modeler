package main

import "core:testing"

@(test)
view_window_events_go_by_window_id :: proc(t: ^testing.T) {
	vws: View_Windows
	a, b := View_Window{id = 7, number = 1}, View_Window{id = 9, number = 3}
	vws.open[0], vws.open[2] = &a, &b
	testing.expect(t, view_window_route(&vws, 7) == &a, "window 7's event did not go to it")
	testing.expect(t, view_window_route(&vws, 9) == &b, "window 9's event did not go to it")
	testing.expect(t, view_window_route(&vws, 3) == nil, "the main window's event went to a view window")
	testing.expect(t, view_window_route(&vws, 0) == nil, "an event with no window went to a view window")
}

@(test)
view_window_picture_is_capped_keeping_its_shape :: proc(t: ^testing.T) {
	testing.expect_value(t, view_window_picture_size({960, 640}), [2]u32{960, 640})
	testing.expect_value(t, view_window_picture_size({1920, 1080}), [2]u32{1920, 1080})
	// A 4K window draws 1080p's worth, as wide as it is tall as the window.
	four_k := view_window_picture_size({3840, 2160})
	testing.expect_value(t, four_k, [2]u32{1920, 1080})
	wide := view_window_picture_size({5120, 1440})
	testing.expect(t, int(wide.x) * int(wide.y) <= VIEW_WINDOW_PICTURE_MAX, "a wide window's picture is past the cap")
	testing.expect(t, abs(f32(wide.x) / f32(wide.y) - 5120.0 / 1440) < 0.01, "a wide window's picture lost its shape")
	testing.expect_value(t, view_window_picture_size({0, 0}), [2]u32{1, 1})
}

@(test)
view_windows_stop_at_three :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	defer results_destroy(app)
	sv := Second_View{camera = .Front, pass = .Normals, turns = 4}
	for _ in 0 ..< VIEW_WINDOWS_MAX do view_window_request(app, sv)
	vws := &app.view_windows
	when VIEW_WINDOWS_AVAILABLE {
		testing.expect_value(t, len(vws.pending), VIEW_WINDOWS_MAX)
		// A window keeps the view's camera and pass, never its counts.
		testing.expect_value(t, vws.pending[0].camera, Second_Camera.Front)
		testing.expect_value(t, vws.pending[0].pass, Second_Pass.Normals)
		testing.expect(t, vws.pending[0].turns == 0, "a window kept the pane's counts")
		view_window_request(app, sv)
		testing.expect_value(t, len(vws.pending), VIEW_WINDOWS_MAX)
		testing.expect_value(t, vws.refused, 1)
		testing.expect(t, .Warning in app.result.flags, "the fourth window was refused without a word")
	} else {
		testing.expect_value(t, len(vws.pending), 0)
	}
}
