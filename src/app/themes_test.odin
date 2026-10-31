package main

import "core:os"
import "core:testing"

import "../ui"

// Moving a control starts a draft of the chosen theme; Undo puts it back; Keep on a
// built-in theme makes a theme of one's own named after it, which is then chosen and no
// longer a draft, and Keep again writes over that one.
@(test)
a_draft_is_kept_as_a_theme_of_ones_own :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	testing.expect(t, !theme_draft(&k))
	k.themes.seed.accent = {0x5b, 0x8c, 0xff, 0xff}
	testing.expect(t, theme_draft(&k))
	theme_choose(&k, theme_ref(&k))
	testing.expect(t, !theme_draft(&k))
	testing.expect_value(t, k.themes.seed, LOOK_SEEDS[.Lens])

	k.themes.seed.tint = 0.9
	testing.expect(t, theme_keep(&k))
	testing.expect_value(t, k.themes.count, 1)
	testing.expect_value(t, theme_ref(&k), Theme_Ref{.Lens, 0})
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Lens 2")
	testing.expect(t, !theme_draft(&k))
	k.themes.seed.contrast = 1
	testing.expect(t, theme_keep(&k))
	testing.expect_value(t, k.themes.count, 1)
	testing.expect_value(t, k.themes.list[0].seed.contrast, 1)

	// A second theme kept from Lens takes the next free name.
	theme_choose(&k, {.Lens, -1})
	k.themes.seed.hue = 30
	testing.expect(t, theme_keep(&k))
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Lens 3")
}

// Picking a light theme makes it the day theme and a dark one the night theme; with
// Match device on, the device's setting picks between them, but never over a draft.
@(test)
match_device_follows_the_system_but_spares_a_draft :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	theme_choose(&k, {.Midnight, -1})
	testing.expect_value(t, k.themes.night, Theme_Ref{.Midnight, -1})
	testing.expect_value(t, k.themes.day, THEME_DAY_DEFAULT)
	k.themes.match = true
	theme_follow_device(&k, false)
	testing.expect_value(t, theme_ref(&k), Theme_Ref{.Paper, -1})
	theme_follow_device(&k, true)
	testing.expect_value(t, theme_ref(&k), Theme_Ref{.Midnight, -1})
	k.themes.seed.opacity = 0.7
	theme_follow_device(&k, false)
	testing.expect_value(t, theme_ref(&k), Theme_Ref{.Midnight, -1})
	testing.expect(t, theme_draft(&k))
}

// Untouched, Lens, Studio and Graphite are their exact hand-made colours.
@(test)
built_in_themes_keep_their_exact_colours :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	testing.expect(t, theme_current(&k) == ui.THEME_LENS)
	theme_choose(&k, {.Studio, -1})
	testing.expect(t, theme_current(&k) == ui.THEME_STUDIO)
	theme_choose(&k, {.Graphite, -1})
	testing.expect(t, theme_current(&k) == ui.THEME_DARK)
}

// The themes' settings lines read back as they were written, and a seed line with words
// it does not know, or values out of range, still reads.
@(test)
themes_read_back_from_the_settings :: proc(t: ^testing.T) {
	path := "build/themes_test.txt"
	defer os.remove(path)
	a: App
	themes_init(&a.kit)
	a.kit.themes.seed.accent = {0xff, 0x86, 0xb9, 0xff}
	a.kit.themes.seed.corners = .Square
	testing.expect(t, theme_keep(&a.kit))
	theme_choose(&a.kit, {.Paper, -1})
	a.kit.themes.seed.contrast = 0.75
	a.kit.themes.match = true
	testing.expect(t, settings_save(&a, path))

	b: App
	themes_init(&b.kit)
	settings_load(&b, path)
	testing.expect_value(t, b.kit.themes.count, 1)
	testing.expect_value(t, theme_ref_name(&b.kit, {.Lens, 0}), "Lens 2")
	testing.expect_value(t, b.kit.themes.list[0], a.kit.themes.list[0])
	testing.expect_value(t, theme_ref(&b.kit), Theme_Ref{.Paper, -1})
	testing.expect_value(t, b.kit.themes.seed, a.kit.themes.seed)
	testing.expect(t, theme_draft(&b.kit))
	testing.expect(t, b.kit.themes.match)
	testing.expect_value(t, b.kit.themes.day, Theme_Ref{.Paper, -1})
	testing.expect_value(t, b.kit.themes.night, Theme_Ref{.Lens, 0})

	words := []string{"light", "hue=400", "opacity=0.2", "contrast=75", "accent=#123", "sparkle=9", "corners=round"}
	s, _, ok := theme_seed_parse(words, LOOK_SEEDS[.Lens])
	testing.expect(t, ok)
	testing.expect_value(t, s.mode, ui.Theme_Mode.Light)
	testing.expect_value(t, s.hue, 360)
	testing.expect_value(t, s.opacity, ui.THEME_OPACITY_MIN)
	testing.expect_value(t, s.contrast, 0.75)
	testing.expect_value(t, s.accent, ui.Color{0x11, 0x22, 0x33, 0xff})
	testing.expect_value(t, s.corners, ui.Theme_Corners.Round)
	free_all(context.temp_allocator)
}

// A settings file from before themes names only its look: the seed shown is that look's.
@(test)
an_old_settings_file_shows_its_look :: proc(t: ^testing.T) {
	path := "build/themes_old_test.txt"
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, transmute([]u8)string("version 13\nlook Graphite\n")) == nil)
	a: App
	themes_init(&a.kit)
	settings_load(&a, path)
	testing.expect_value(t, theme_ref(&a.kit), Theme_Ref{.Graphite, -1})
	testing.expect(t, !theme_draft(&a.kit))
	free_all(context.temp_allocator)
}

// Deleting a theme of one's own sends what named it back to its built-in theme and moves
// the references to the ones after it down; a copy takes the next free number.
@(test)
deleting_a_theme_moves_what_named_it :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	theme_choose(&k, {.Paper, -1})
	testing.expect(t, theme_duplicate(&k, theme_ref(&k)))
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Paper 2")
	testing.expect(t, theme_duplicate(&k, theme_ref(&k)))
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Paper 3")
	testing.expect_value(t, k.themes.day, Theme_Ref{.Paper, 1})
	theme_delete(&k, 0)
	testing.expect_value(t, k.themes.count, 1)
	testing.expect_value(t, theme_ref(&k), Theme_Ref{.Paper, 0})
	testing.expect_value(t, k.themes.day, Theme_Ref{.Paper, 0})
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Paper 3")
	theme_delete(&k, 0)
	testing.expect_value(t, theme_ref(&k), Theme_Ref{.Paper, -1})
	testing.expect(t, !theme_draft(&k))
	testing.expect(t, !theme_rename(&k, 0, "Anything"))
}

// A name another theme has, built-in or one's own, is refused; any other is kept.
@(test)
a_theme_name_is_its_own :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	k.themes.seed.hue = 10
	testing.expect(t, theme_keep(&k))
	testing.expect(t, !theme_rename(&k, 0, "paper"))
	testing.expect(t, !theme_rename(&k, 0, "  "))
	testing.expect(t, theme_rename(&k, 0, "Clay room"))
	testing.expect_value(t, theme_ref_name(&k, {.Lens, 0}), "Clay room")
}

// A colour set by hand is part of the draft and of a share code, which imports back to
// the same colours under a name of its own.
@(test)
a_share_code_imports_the_same_theme :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	theme_choose(&k, {.Studio, -1})
	k.themes.seed.contrast = 0.8
	k.themes.over.set += {.Danger}
	k.themes.over.colors[.Danger] = {0xff, 0x00, 0x40, 0xff}
	testing.expect(t, theme_draft(&k))
	shown := theme_current(&k)
	testing.expect_value(t, shown.danger, ui.Color{0xff, 0x00, 0x40, 0xff})
	code := theme_code("Studio edited", .Studio, k.themes.seed, k.themes.over)
	testing.expect(t, theme_import(&k, code))
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Studio edited")
	testing.expect(t, !theme_draft(&k))
	testing.expect(t, theme_current(&k) == shown)
	// The same code again takes the next free name; a stranger's text is no code.
	testing.expect(t, theme_import(&k, code))
	testing.expect_value(t, theme_ref_name(&k, theme_ref(&k)), "Studio edited 2")
	testing.expect(t, !theme_import(&k, "hello there"))
	testing.expect(t, !theme_import(&k, "sculpt-theme 1 X Nowhere dark"))
	free_all(context.temp_allocator)
}

// The viewport's marks keep the renderer's own colours until set by hand, and a space's
// tint set by hand brings its soft fill along.
@(test)
viewport_marks_follow_only_colours_set_by_hand :: proc(t: ^testing.T) {
	k: Kit_State
	themes_init(&k)
	theme_choose(&k, {.Paper, -1})
	testing.expect_value(t, theme_wire_color(&k), [4]f32{})
	testing.expect_value(t, theme_selection_color(&k), MODEL_SELECTION_COLOR)
	k.themes.over.set += {.Wire, .Selection, .Space_Model}
	k.themes.over.colors[.Wire] = {255, 255, 255, 255}
	k.themes.over.colors[.Selection] = {0, 0, 255, 255}
	k.themes.over.colors[.Space_Model] = {0x20, 0xa0, 0x40, 255}
	testing.expect_value(t, theme_wire_color(&k), [4]f32{1, 1, 1, 1})
	testing.expect_value(t, theme_selection_color(&k), [4]f32{0, 0, 1, MODEL_SELECTION_COLOR.a})
	shown := theme_current(&k)
	testing.expect_value(t, shown.tints[1], ui.Color{0x20, 0xa0, 0x40, 255})
	testing.expect(t, shown.tints_soft[1] != theme_saved(&k).tints_soft[1])
	// Held to compare, the saved theme's marks show again.
	k.themes.compare = true
	testing.expect_value(t, theme_wire_color(&k), [4]f32{})
}

// Bring its background paints the viewport once per change of theme, leaving a background
// set by hand alone until the theme changes again; a light theme gets a light one, pure
// black a black one.
@(test)
a_theme_brings_its_background :: proc(t: ^testing.T) {
	a: App
	themes_init(&a.kit)
	a.background = BACKGROUND_DEFAULT
	theme_bring_background(&a)
	testing.expect_value(t, a.background, BACKGROUND_DEFAULT)
	a.kit.themes.bring = true
	theme_choose(&a.kit, {.Paper, -1})
	theme_bring_background(&a)
	paper := a.background
	testing.expect(t, paper.gradient && paper.top.g > 0.8 && paper.bottom.g < paper.top.g)
	a.background.top = {1, 0, 0}
	theme_bring_background(&a)
	testing.expect_value(t, a.background.top, [3]f32{1, 0, 0})
	theme_choose(&a.kit, {.Midnight, -1})
	theme_bring_background(&a)
	testing.expect_value(t, a.background, Background_Settings{})
	theme_choose(&a.kit, {.Lens, -1})
	theme_bring_background(&a)
	testing.expect(t, a.background.gradient && a.background.top.g > a.background.bottom.g && a.background.top.g < 0.4)
}
