package main

import "core:fmt"
import "core:os"
import "core:testing"

// Recent keeps each scene once, newest first, at most HOME_RECENT_MAX; a path with spaces
// survives the settings file, and a file that names one twice reads it once.
@(test)
recent_scenes_keep_the_newest_once :: proc(t: ^testing.T) {
	a: App
	defer {
		for s in a.recent_scenes do delete(s)
		delete(a.recent_scenes)
	}
	recent_scene_add(&a, "/scenes/dragon.sculpt")
	recent_scene_add(&a, "/scenes/my head.sculpt")
	recent_scene_add(&a, "/scenes/dragon.sculpt")
	recent_scene_add(&a, "")
	testing.expect_value(t, len(a.recent_scenes), 2)
	testing.expect_value(t, a.recent_scenes[0], "/scenes/dragon.sculpt")
	testing.expect_value(t, a.recent_scenes[1], "/scenes/my head.sculpt")
	for i in 0 ..< HOME_RECENT_MAX + 5 do recent_scene_add(&a, fmt.tprintf("/scenes/%d.sculpt", i))
	testing.expect_value(t, len(a.recent_scenes), HOME_RECENT_MAX)
	testing.expect_value(t, a.recent_scenes[0], fmt.tprintf("/scenes/%d.sculpt", HOME_RECENT_MAX + 4))
	recent_scene_drop(&a, a.recent_scenes[1], save = false)
	testing.expect_value(t, len(a.recent_scenes), HOME_RECENT_MAX - 1)
	testing.expect_value(t, a.recent_scenes[1], fmt.tprintf("/scenes/%d.sculpt", HOME_RECENT_MAX + 2))

	path := "build/recent_test_settings.txt"
	defer os.remove(path)
	for s in a.recent_scenes do delete(s)
	clear(&a.recent_scenes)
	recent_scene_add(&a, "/scenes/my head.sculpt")
	recent_scene_add(&a, "C:\\Scenes\\100% clay.sculpt")
	testing.expect(t, settings_save(&a, path))
	b: App
	defer {
		for s in b.recent_scenes do delete(s)
		delete(b.recent_scenes)
	}
	settings_load(&b, path)
	testing.expect_value(t, len(b.recent_scenes), 2)
	testing.expect_value(t, b.recent_scenes[0], "C:\\Scenes\\100% clay.sculpt")
	testing.expect_value(t, b.recent_scenes[1], "/scenes/my head.sculpt")

	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("recent_scenes /a.sculpt /b.sculpt /a.sculpt\n")) == nil)
	settings_load(&b, path)
	testing.expect_value(t, len(b.recent_scenes), 2)
	free_all(context.temp_allocator)
}
