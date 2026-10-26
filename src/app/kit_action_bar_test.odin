package main

import "core:testing"

import "../geom"
import "../sculpt"

// A selected object with no GPU buffers, for tests of what the interface derives from the
// sculpt; test_object_free undoes it.
@(private = "file")
test_object :: proc(app: ^App, id: int) -> ^Object {
	obj := new(Object)
	obj.id = id
	// The sculpt's groups only: the Move tool, App's zero value, adds the gizmo's.
	app.tool = .Brush
	sculpt.levels_init(&obj.levels, geom.icosphere(2), nil, 64)
	append(&app.scene.objects, obj)
	app.scene.selected = len(app.scene.objects) - 1
	return obj
}

@(private = "file")
test_scene_free :: proc(app: ^App) {
	for obj in app.scene.objects {
		sculpt.levels_destroy(&obj.levels)
		free(obj)
	}
	delete(app.scene.objects)
	history_destroy(&app.history)
}

// The bar's groups follow the object: none untouched, Mask once something is masked,
// Hidden once something is hidden, and none with nothing selected.
@(test)
action_groups_follow_the_object :: proc(t: ^testing.T) {
	app: App
	defer test_scene_free(&app)
	obj := test_object(&app, 1)
	s := object_sculptor(obj)
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{})
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	history_record(&app, obj, .Mask, "Mask all")
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{.Mask})
	testing.expect(t, sculpt.sculptor_mask_command(s, .Clear))
	history_record(&app, obj, .Mask, "Clear mask")
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{})
	// A rectangle in the middle, with the mesh's space as clip space, hides what it covers.
	rect := [][2]f32{{-0.3, -0.3}, {0.3, -0.3}, {0.3, 0.3}, {-0.3, 0.3}}
	testing.expect(t, sculpt.sculptor_hide_shape(s, 1, rect, .Hide))
	history_record(&app, obj, .Hide, "Hide rectangle")
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{.Hidden})
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	history_record(&app, obj, .Mask, "Mask all")
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{.Mask, .Hidden})
	app.scene.selected = -1
	testing.expect_value(t, action_groups_now(&app), bit_set[Action_Group]{})
}

// The mask is read again only when the history, the object or its level changes: asking
// every frame costs nothing, and an undo, or a scene opened over another whose object has
// the same id, is still seen.
@(test)
object_has_mask_looks_again_only_after_a_change :: proc(t: ^testing.T) {
	app: App
	defer test_scene_free(&app)
	obj := test_object(&app, 1)
	s := object_sculptor(obj)
	testing.expect(t, sculpt.sculptor_mask_command(s, .Fill))
	history_record(&app, obj, .Mask, "Mask all")
	testing.expect(t, object_has_mask(&app, obj))
	scans := app.mask_seen.scans
	for _ in 0 ..< 10 do _ = object_has_mask(&app, obj)
	testing.expect_value(t, app.mask_seen.scans, scans)
	// Another object is another key: it is read once, with its own answer, and going back
	// reads the first again.
	other := test_object(&app, 2)
	testing.expect(t, sculpt.sculptor_mask_command(object_sculptor(other), .Fill))
	_ = sculpt.sculptor_mask_command(object_sculptor(other), .Clear)
	testing.expect(t, !object_has_mask(&app, other))
	testing.expect_value(t, app.mask_seen.scans, scans + 1)
	testing.expect(t, object_has_mask(&app, obj))
	testing.expect_value(t, app.mask_seen.scans, scans + 2)
	app.scene.selected = 0
	// An undo takes the mask away and moves the serial.
	before := app.history.serial
	history_undo(&app)
	testing.expect(t, app.history.serial != before)
	testing.expect(t, !object_has_mask(&app, obj))
	history_redo(&app)
	testing.expect(t, object_has_mask(&app, obj))
	// A clear (a scene opened) changes the key though the id is the same.
	before = app.history.serial
	history_clear(&app.history)
	testing.expect(t, app.history.serial != before)
	_ = sculpt.sculptor_mask_command(s, .Clear)
	testing.expect(t, !object_has_mask(&app, obj))
}

// Every action names a command and argument the registry can run, and each group has one.
@(test)
action_groups_run_registry_commands :: proc(t: ^testing.T) {
	for info in ACTION_GROUPS {
		testing.expect(t, len(info.actions) > 0 && len(info.actions) <= 7)
		for a in info.actions {
			n := COMMANDS[a.id].args
			testing.expectf(t, a.id != .None && (n == 0 ? a.arg == 0 : a.arg >= 0 && a.arg < n), "%v %d", a.id, a.arg)
		}
	}
}
