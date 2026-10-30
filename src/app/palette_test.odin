package main

import "core:testing"

import "../sculpt"

// The label of the best match for `query`, with every entry enabled and no recents.
@(private = "file")
best :: proc(query: string, recent: []Palette_Entry = nil) -> string {
	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for &e in enabled do e = true
	hits := palette_rank(query, entries, recent, enabled)
	if len(hits) == 0 do return ""
	return palette_label(entries[hits[0].entry])
}

@(private = "file")
cmd :: proc(id: Command_Id, arg := 0) -> Palette_Entry {return {.Command, id, arg}}

// Folded words, prefixes, synonyms and letters in order each match, in that order.
@(test)
palette_tiers_rank_in_order :: proc(t: ^testing.T) {
	expect_tier :: proc(t: ^testing.T, query, label, synonyms: string, want: Palette_Tier) {
		tier, _ := palette_match(query, label, synonyms)
		testing.expectf(t, tier == want, "%q against %q: %v, not %v", query, label, tier, want)
	}
	expect_tier(t, "remesh", "remesh", "", .Exact)
	expect_tier(t, "rem", "remesh to 1m vertices", "", .Prefix)
	expect_tier(t, "inv mask", "invert mask", "", .Words)
	expect_tier(t, "mask inv", "invert mask", "", .Words)
	expect_tier(t, "dyna", "remesh", "dynamesh voxel", .Synonyms)
	expect_tier(t, "wfr", "wireframe", "", .Fuzzy)
	expect_tier(t, "wf", "wireframe", "", .None)
	expect_tier(t, "zzz", "wireframe", "", .None)
	expect_tier(t, "", "anything", "", .Exact)
	expect_tier(t, "settings", "settings...", "", .Exact)
	expect_tier(t, "open scene", "open scene...", "", .Exact)
	expect_tier(t, "...", "settings...", "", .None)
	// A closer run of letters scores lower than a scattered one.
	tight_tier, tight := palette_match("ram", "frame all", "")
	loose_tier, loose := palette_match("fml", "frame all", "")
	testing.expect(t, tight_tier == .Fuzzy && loose_tier == .Fuzzy && tight < loose)
}

// The names other apps give a command find ours, and case and spaces do not matter.
@(test)
palette_finds_other_apps_names :: proc(t: ^testing.T) {
	testing.expect_value(t, best("DynaMesh"), "Remesh")
	testing.expect_value(t, best("zremesher"), "Quad Remesh")
	testing.expect_value(t, best("  WIREFRAME "), "Wireframe")
	testing.expect_value(t, best("clay"), "Clay brush")
	testing.expect_value(t, best("inv mask"), "Invert mask")
	testing.expect_value(t, best("touch"), "Settings: Touch")
	testing.expect_value(t, best("bpr"), "Render")
	testing.expect_value(t, best("freeze"), "Mask all")
	testing.expect_value(t, best("subtool"), "Add object")
	testing.expect_value(t, best("qqqqq"), "")
}

// Among equal matches the recent one comes first, then one that can run now; and with
// no query the recents lead, in the order they were run.
@(test)
palette_recent_then_enabled_first :: proc(t: ^testing.T) {
	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for &e in enabled do e = true
	testing.expect_value(t, best("smooth"), "Smooth all")
	testing.expect_value(t, best("smooth", {cmd(.Brush, 1)}), "Smooth brush")
	// Disabled loses to enabled within a tier, but not across tiers.
	for e, i in entries do if e == cmd(.Smooth_All) do enabled[i] = false
	hits := palette_rank("smooth", entries, nil, enabled)
	testing.expect_value(t, palette_label(entries[hits[0].entry]), "Smooth brush")
	hits = palette_rank("smooth all", entries, nil, enabled)
	testing.expect_value(t, palette_label(entries[hits[0].entry]), "Smooth all")
	for &e in enabled do e = true
	recent := []Palette_Entry{cmd(.Wireframe), cmd(.Remesh)}
	hits = palette_rank("", entries, recent, enabled)
	testing.expect_value(t, len(hits), len(entries))
	testing.expect(t, entries[hits[0].entry] == cmd(.Wireframe))
	testing.expect(t, entries[hits[1].entry] == cmd(.Remesh))
	testing.expect(t, entries[hits[2].entry] == entries[0])
}

// Ranking twice gives the same order, whatever the labels' ties.
@(test)
palette_rank_is_deterministic :: proc(t: ^testing.T) {
	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for &e, i in enabled do e = i % 3 != 0
	for q in ([?]string{"", "s", "mask", "de", "h"}) {
		a := palette_rank(q, entries, nil, enabled)
		b := palette_rank(q, entries, nil, enabled)
		testing.expect_value(t, len(a), len(b))
		for i in 0 ..< min(len(a), len(b)) do testing.expect_value(t, a[i].entry, b[i].entry)
	}
}

// Every command but None, the palette itself and those that act at the pointer is listed, once per argument, and
// every Settings tab, and no label is empty or listed twice.
@(test)
palette_lists_everything_once :: proc(t: ^testing.T) {
	entries := palette_entries()
	seen := make(map[string]int, context.temp_allocator)
	for e in entries {
		testing.expect(t, e.kind == .Settings_Tab || palette_lists(e.id))
		label := palette_label(e)
		testing.expect(t, label != "")
		seen[label] += 1
	}
	for label, n in seen do testing.expectf(t, n == 1, "%q is listed %d times", label, n)
}

// Running an entry puts it first; running a recent one again moves it up; the oldest
// falls off when the list is full.
@(test)
palette_remember_keeps_the_latest_first :: proc(t: ^testing.T) {
	recent: [PALETTE_RECENT]Palette_Entry
	count := 0
	palette_remember(&recent, &count, cmd(.Undo))
	palette_remember(&recent, &count, cmd(.Redo))
	testing.expect_value(t, count, 2)
	testing.expect(t, recent[0] == cmd(.Redo) && recent[1] == cmd(.Undo))
	palette_remember(&recent, &count, cmd(.Undo))
	testing.expect_value(t, count, 2)
	testing.expect(t, recent[0] == cmd(.Undo) && recent[1] == cmd(.Redo))
	for i in 0 ..< PALETTE_RECENT do palette_remember(&recent, &count, cmd(.Brush, i))
	testing.expect_value(t, count, PALETTE_RECENT)
	testing.expect(t, recent[0] == cmd(.Brush, PALETTE_RECENT - 1))
	testing.expect(t, recent[PALETTE_RECENT - 1] == cmd(.Brush, 0))
}

// Recents are written by name, arguments too, and read back as the same entries; a name
// this version does not know, or a size between presets, reads as nothing or the nearest.
@(test)
palette_names_round_trip :: proc(t: ^testing.T) {
	for e in palette_entries() {
		back, ok := palette_entry_from_name(palette_entry_name(e))
		testing.expectf(t, ok && back == e, "%s read back as %v", palette_entry_name(e), back)
	}
	testing.expect_value(t, palette_entry_name(cmd(.Brush, int(sculpt.Brush_Kind.Clay))), "Brush:Clay")
	testing.expect_value(t, palette_entry_name({kind = .Settings_Tab, arg = int(Settings_Tab.Touch)}), "Settings_Tab:Touch")
	near, ok := palette_entry_from_name("Remesh_To:990000")
	testing.expect(t, ok && near == cmd(.Remesh_To, 2))
	for bad in ([?]string{"Teleport", "Brush:Nonsense", "Wireframe:1", "Hd_Toggle", "None", "Command_Palette", "Settings_Tab:Sound", ""}) {
		_, ok = palette_entry_from_name(bad)
		testing.expectf(t, !ok, "%q was read", bad)
	}
}

// A tall window shows every row; a short one fewer, never under two.
@(test)
palette_rows_fit_the_room :: proc(t: ^testing.T) {
	testing.expect_value(t, palette_rows(800, 48), PALETTE_ROWS)
	testing.expect_value(t, palette_rows(400, 48), 3)
	testing.expect_value(t, palette_rows(100, 48), 2)
}

// The touch scenarios that star, pie or bind Wireframe (scripts/touch_check.py) type
// "wire" and tap the buttons under the rows it finds, where three rows put them
// (PALETTE_STAR and the rest). A new command whose label also holds w, i, r, e in order
// adds a row and moves the buttons: this says so in seconds, rather than four scenarios
// failing in the touch run. Rename the command, or move the scenarios' buttons.
@(test)
palette_wire_finds_three_rows :: proc(t: ^testing.T) {
	entries := palette_entries()
	enabled := make([]bool, len(entries), context.temp_allocator)
	for &e in enabled do e = true
	hits := palette_rank("wire", entries, nil, enabled)
	labels := make([]string, len(hits), context.temp_allocator)
	for h, i in hits do labels[i] = palette_label(entries[h.entry])
	testing.expectf(t, len(hits) == 3, "\"wire\" finds %v", labels)
}
