package main

import "core:testing"

// Splitting the Object tab into pages lost no section: each of its sections is on
// exactly one page, every page has one, and none holds more than six (UX roadmap phase 3).
@(test)
object_sections_each_on_one_page :: proc(t: ^testing.T) {
	seen: [Kit_Section]int
	per_page: [Object_Page]int
	for sec in OBJECT_SECTIONS {
		seen[sec.section] += 1
		per_page[sec.page] += 1
	}
	for s in Kit_Section.Transform ..= Kit_Section.Extract {
		testing.expectf(t, seen[s] == 1, "%v is on %d pages", s, seen[s])
	}
	for n, page in per_page do testing.expectf(t, n >= 1 && n <= 6, "%v has %d sections", page, n)
}
