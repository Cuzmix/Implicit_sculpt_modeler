package main

import "core:testing"

// An import takes the place of the sphere a run or New scene starts with only while that
// sphere is untouched; a named, sculpted, saved or second object keeps its place.
@(test)
import_replaces_only_the_untouched_starter :: proc(t: ^testing.T) {
	app: App
	sphere := new(Object)
	sphere.id = 1
	append(&app.scene.objects, sphere)
	defer {
		for obj in app.scene.objects do free(obj)
		delete(app.scene.objects)
		delete(app.history.done)
		delete(app.history.undone)
	}
	testing.expect(t, import_replaces_starter(&app), "the untouched starting sphere is replaced")

	append(&app.history.done, History_Entry{id = 1})
	testing.expect(t, !import_replaces_starter(&app), "a sculpted sphere stays")
	clear(&app.history.done)
	append(&app.history.undone, History_Entry{id = 1})
	testing.expect(t, !import_replaces_starter(&app), "a sphere with an undone step stays")
	clear(&app.history.undone)
	app.history.dropped = 1
	testing.expect(t, !import_replaces_starter(&app), "a sphere whose steps the limits dropped stays")
	app.history.dropped = 0

	sphere.name = "Box"
	testing.expect(t, !import_replaces_starter(&app), "a starter other than the sphere stays")
	sphere.name = ""
	sphere.folder = 3
	testing.expect(t, !import_replaces_starter(&app), "a sphere put in a folder stays")
	sphere.folder = 0
	app.scene_path = "scene.sculpt"
	testing.expect(t, !import_replaces_starter(&app), "an opened scene's sphere stays")
	app.scene_path = ""

	append(&app.scene.objects, new(Object))
	testing.expect(t, !import_replaces_starter(&app), "two objects stay")
	free(pop(&app.scene.objects))
	testing.expect(t, import_replaces_starter(&app))
}
