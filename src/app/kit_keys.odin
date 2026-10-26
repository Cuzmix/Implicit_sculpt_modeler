package main

import "core:fmt"
import "core:strings"

import "../ui"

// Settings > Keys: what the mouse's buttons do to the view, as ZBrush, Blender or Maya
// have it, and every command with its keys, found by its name or by a key, each opening
// Assign key (kit_bind.odin) at a tap, where its key is changed, removed or reset, as
// 3DCoat's and Blender's keymap editors list theirs.

MOUSE_SCHEME_NAMES := [Mouse_Scheme]string {
	.ZBrush  = "ZBrush",
	.Blender = "Blender",
	.Maya    = "Maya",
}

// What turns, pans and zooms the view in each scheme, as mouse_button_owner decides it,
// for this tab and Help's MOUSE rows.
@(rodata)
MOUSE_SCHEME_HOW := [Mouse_Scheme][3]string {
	.ZBrush  = {"Right drag, or Alt + left drag", "Middle drag, or Alt or Shift + right drag", "Wheel, or Ctrl + right or middle drag"},
	.Blender = {"Middle or right drag, or Alt + left drag", "Shift + middle drag, or Alt or Shift + right drag", "Wheel, or Ctrl + middle or right drag"},
	.Maya    = {"Alt + left drag, or right drag", "Alt + middle or middle drag, or Shift + right drag", "Wheel, Alt + right drag, or Ctrl + right or middle drag"},
}

MOUSE_ACTIONS := [3]string{"Turn the view", "Pan", "Zoom"}

// Whether the command matches what is typed in the tab's search. With a `+` in it the
// query is the start of one of its keys ("ctrl+z" finds Undo, "ctrl+shift" every key
// with both); without one, the label or the words Search finds it by, or a key's own last
// part ("q" finds Q and Shift+Q, not every key with Shift). `query` is folded and trimmed.
keys_match :: proc(app: ^App, id: Command_Id, arg: int, query: string) -> bool {
	if query == "" do return true
	chord := strings.contains(query, "+")
	for b in keymap(app) {
		if b.command != id || b.arg != arg do continue
		text := strings.to_lower(chord_text(b.chord), context.temp_allocator)
		if chord && strings.has_prefix(text, query) do return true
		if !chord {
			// The key named "+" ends in "+" with nothing after it: it is its own last part.
			last := text
			if i := strings.last_index_byte(text[:len(text) - 1], '+'); i >= 0 do last = text[i + 1:]
			if last == query do return true
		}
	}
	if chord do return false
	e := Palette_Entry{.Command, id, arg}
	tier, _ := palette_match(query, strings.to_lower(palette_label(e), context.temp_allocator), strings.to_lower(palette_words_of(e), context.temp_allocator))
	// Letters in order match nearly every label; a key list wants what is named.
	return tier < .Fuzzy
}

// The commands the tab lists for `query`, in Help > Keys' groups, then the registry's
// order. In the temp allocator.
keys_rows :: proc(app: ^App, query: string) -> []Palette_Entry {
	q := strings.to_lower(strings.trim_space(query), context.temp_allocator)
	out := make([dynamic]Palette_Entry, 0, 160, context.temp_allocator)
	entries := palette_entries()
	for group in Command_Group {
		for e in entries {
			if e.kind != .Command || command_group(e.id) != group do continue
			if keys_match(app, e.id, e.arg, q) do append(&out, e)
		}
	}
	return out[:]
}

// The tab. Rows the user gave other keys show them in the accent colour.
settings_keys :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	n := &app.nav
	ui.caption(ctx, "MOUSE BUTTONS")
	names: [len(Mouse_Scheme)]string
	for s in Mouse_Scheme do names[int(s)] = MOUSE_SCHEME_NAMES[s]
	ui.label(ctx, "Turn, pan and zoom as in")
	if picked := ui.tabs(ctx, "Mouse scheme", names[:], int(n.mouse_scheme)); picked >= 0 do n.mouse_scheme = Mouse_Scheme(picked)
	for how, i in MOUSE_SCHEME_HOW[n.mouse_scheme] {
		ui.label(ctx, MOUSE_ACTIONS[i], t.small_size)
		ui.label(ctx, how, t.small_size, t.text)
	}
	ui.paragraph(ctx, "The wheel zooms in all three. Left drags, the edges and the brush pie's right click stay as they are (Settings > Camera and Touch).")
	ui.spacer(ctx, 8)

	ui.caption(ctx, "KEYS")
	_ = ui.text_field(ctx, "Find a command or key##keys", k.keys_query[:], hint = "Find a command or a key, such as ctrl+z")
	query := string(cstring(&k.keys_query[0]))
	rows := keys_rows(app, query)
	b := &k.bind
	body := k.settings_body
	anchored := false
	group := Command_Group(255)
	for e in rows {
		if g := command_group(e.id); g != group {
			if group != Command_Group(255) do ui.spacer(ctx, 4)
			ui.caption(ctx, COMMAND_GROUP_NAMES[g])
			group = g
		}
		keys := command_chords(app, e.id, e.arg)
		shown := keys if keys != "" else "No key"
		label := palette_label(e)
		// A long name gives way to the keys, which are what this list is for.
		room := ui.fill_width(ctx) - 20 - t.icon_small - 10 - ui.text_width(ctx, shown, t.small_size) - 16
		label = ui.text_fit(ctx, label, t.text_size, room)
		changed := key_override_find(app, e.id, e.arg) >= 0
		if ui.menu_item(ctx, fmt.tprintf("%s##keys %s", label, command_name(e.id, e.arg)), shown, palette_icon(e), keys_accent = changed, keys_muted = keys == "") {
			bind_open(app, e.id, e.arg, ctx.last_rect)
			b.from_keys = true
		}
		// The popover follows its row as the list scrolls, and closes once the row
		// scrolls out of view or the search hides it.
		if b.open && b.from_keys && b.id == e.id && b.arg == e.arg {
			r := ctx.last_rect
			if r.y + r.h > body.y && r.y < body.y + body.h {
				b.at, anchored = r, true
			}
		}
	}
	if len(rows) == 0 do ui.paragraph(ctx, "No command has that name or key.")
	if b.open && b.from_keys && !anchored do b.open = false
	ui.paragraph(ctx, "Tap a command to give it a key, take its key away or put its own back. Keys you changed are in blue.")
}
