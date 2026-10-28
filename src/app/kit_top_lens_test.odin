package main

import "core:testing"
import "core:time"

@(test)
saved_ago_says_how_long :: proc(t: ^testing.T) {
	testing.expect_value(t, saved_ago(20 * time.Second), "Saved just now")
	testing.expect_value(t, saved_ago(2 * time.Minute + 30 * time.Second), "Saved 2 min ago")
	testing.expect_value(t, saved_ago(59 * time.Minute), "Saved 59 min ago")
	testing.expect_value(t, saved_ago(3 * time.Hour), "Saved 3 h ago")
	testing.expect_value(t, saved_ago(47 * time.Hour), "Saved 47 h ago")
	testing.expect_value(t, saved_ago(4 * 24 * time.Hour), "Saved 4 days ago")
	// A clock set back since the save reads as just now, never as minutes to come.
	testing.expect_value(t, saved_ago(-5 * time.Minute), "Saved just now")
}

@(test)
file_status_follows_the_scene :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	now := time.now()
	app.saved_fp = scene_fingerprint(app)
	testing.expect_value(t, file_status(app, now), "Not saved")
	// A scene with no file and nothing done in it is not marked as holding changes.
	app.scene_edits += 1
	testing.expect_value(t, file_status(app, now), "Not saved")
	app.scene_path = "head.sculpt"
	app.saved_fp = scene_fingerprint(app)
	app.saved_at = time.time_add(now, -5 * time.Minute)
	testing.expect_value(t, file_status(app, now), "Saved 5 min ago")
	app.scene_edits += 1
	testing.expect_value(t, file_status(app, now), "Unsaved changes")
}
