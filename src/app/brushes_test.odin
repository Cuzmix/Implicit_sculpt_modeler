package main

import "core:testing"

import "../sculpt"

// Every brush has a name of its own, words, an icon and a strength a slider can show,
// and scripts and the settings file find it by its name.
@(test)
every_brush_has_its_row :: proc(t: ^testing.T) {
	for b, kind in BRUSHES {
		testing.expectf(t, b.name != "" && b.help != "" && b.icon != 0, "%v has no name, help or icon", kind)
		testing.expectf(t, b.strength >= MIN_STRENGTH && b.strength <= 1, "%v starts at strength %v", kind, b.strength)
		found, ok := brush_by_name(b.name)
		testing.expectf(t, ok && found == kind, "%q finds %v", b.name, found)
		for other, k in BRUSHES do if k != kind do testing.expectf(t, other.name != b.name && other.icon != b.icon, "%v and %v look alike", kind, k)
	}
	snake, ok := brush_by_name("snake_hook")
	testing.expect(t, ok && snake == sculpt.Brush_Kind.Snake_Hook)
	free_all(context.temp_allocator)
}
