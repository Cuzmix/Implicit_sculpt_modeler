package main

import "core:strings"
import "core:testing"

// A locked object still draws but takes no press: the raycasts pass over it to whatever
// is behind it. Lock others locks every object but one, and picking a locked object in
// a list unlocks it, as picking a ghost brings it back. Neither is an undo step.
@(test)
a_locked_object_takes_no_press :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	scene_view(&app, .Lock, objs[1].id)
	testing.expect(t, objs[1].locked)
	testing.expect(t, object_shown(&app, objs[1]) && !object_pickable(&app, objs[1]))
	_, _, ok := scene_raycast(&app, {3, 0, 5}, {0, 0, -1})
	testing.expect(t, !ok)
	_, _, _, ok = scene_raycast_surface(&app, {3, 0, 5}, {0, 0, -1})
	testing.expect(t, !ok)
	testing.expect_value(t, app.scene_edits, 0)
	testing.expect_value(t, len(app.history.done), 0)

	scene_view(&app, .Lock_Others, objs[1].id)
	testing.expect(t, objs[0].locked && !objs[1].locked && objs[2].locked)
	i: int
	i, _, ok = scene_raycast(&app, {3, 0, 5}, {0, 0, -1})
	testing.expect(t, ok && i == 1)
	// Locking the selected object moves the selection on, as ghosting it does.
	testing.expect_value(t, app.scene.selected, 1)

	scene_view(&app, .Unlock, objs[0].id)
	testing.expect(t, !objs[0].locked)
	scene_view(&app, .Select, objs[2].id)
	testing.expect(t, !objs[2].locked)
	testing.expect_value(t, app.scene.selected, 2)
}

// The Scene card's filter matches names whatever their case, and everything matches an
// empty filter.
@(test)
scene_filter_matches_names :: proc(t: ^testing.T) {
	app: App
	defer tree_free(&app)
	objs := tree_scene(&app)
	// The names are owned, as tree_free deletes them.
	objs[0].name = strings.clone("Left Ear")
	objs[1].name = strings.clone("Eye left")
	objs[2].name = strings.clone("Brows")
	testing.expect(t, scene_matches(objs[0], "left") && scene_matches(objs[1], "left") && !scene_matches(objs[2], "left"))
	testing.expect(t, scene_matches(objs[2], "row"))
	for obj in objs do testing.expect(t, scene_matches(obj, ""))
}
