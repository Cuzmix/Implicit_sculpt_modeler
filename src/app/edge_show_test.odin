package main

import "core:os"
import "core:testing"

// A settings file from before version 13 holds Show the edges on, the default then, and
// comes back with it off, the outline showing only while in use; a newer file keeps it.
@(test)
edge_outline_starts_off_once :: proc(t: ^testing.T) {
	path := "build/edge_show_test.txt"
	defer os.remove(path)
	for version in ([?]int{12, 13}) {
		text := "version 12\nedge_show 1\n" if version == 12 else "version 13\nedge_show 1\n"
		testing.expect(t, os.write_entire_file(path, transmute([]u8)text) == nil)
		a: App
		defer results_destroy(&a)
		bars_reset(&a.kit)
		a.nav = NAV_DEFAULT
		settings_load(&a, path)
		testing.expect_value(t, a.nav.edge_show, version == 13)
	}
}
