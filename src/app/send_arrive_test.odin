package main

import "core:testing"

@(test)
an_arrival_follows_the_round_trip_rules :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	// A new scene with nothing done in it: anything arriving opens.
	app.saved_fp = 0
	testing.expect_value(t, send_arrive_rule(app, 7), Arrive_Rule.Open)
	// The same scene, matching its file: in place.
	app.scene.link_token = 7
	app.scene_path = "dragon.sculpt"
	app.saved_fp = scene_fingerprint(app)
	testing.expect_value(t, send_arrive_rule(app, 7), Arrive_Rule.In_Place)
	// Changed since its file: the same scene is a conflict, another one asks.
	app.scene_edits += 1
	testing.expect_value(t, send_arrive_rule(app, 7), Arrive_Rule.Conflict)
	testing.expect_value(t, send_arrive_rule(app, 8), Arrive_Rule.Ask)
	// Changed, but just as it went out: in place again.
	app.send.exchanged_token, app.send.exchanged_fp = 7, scene_fingerprint(app)
	testing.expect_value(t, send_arrive_rule(app, 7), Arrive_Rule.In_Place)
	// Changed after it went out: a conflict.
	app.scene_edits += 1
	testing.expect_value(t, send_arrive_rule(app, 7), Arrive_Rule.Conflict)
	// A scene with no token is never the open one.
	app.scene.link_token = 0
	testing.expect_value(t, send_arrive_rule(app, 0), Arrive_Rule.Ask)
}
