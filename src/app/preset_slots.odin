package main

import "core:fmt"
import "core:strconv"
import "core:strings"

// Every preset as a command's argument (Brush_Preset), so a shelf tile, a dock, a key, a
// pie or a dial sector holds one as it holds a plain brush: first the built-in presets
// (BUILT_IN_PRESETS, appended only), then the person's own in their order, then the
// content packs' in the library's order. The person's own are renumbered when one is
// deleted (preset_slots_deleted), and the packs' are named in settings.txt by pack and
// name (preset_slots_save), so a tile keeps its preset when packs come and go.

PRESET_SLOT_OWN :: len(BUILT_IN_PRESETS)
PRESET_SLOT_PACK :: PRESET_SLOT_OWN + MAX_PRESETS
// More packs' presets than any library is likely to hold; past it a pack's preset stays
// in the picker.
PRESET_SLOT_PACKS_MAX :: 1024
PRESET_SLOTS :: PRESET_SLOT_PACK + PRESET_SLOT_PACKS_MAX

// The preset an argument stands for, numbered as PACK_PRESET says.
preset_slot_number :: proc(arg: int) -> int {
	switch {
	case arg < PRESET_SLOT_OWN:  return BUILT_IN_PRESET + arg
	case arg < PRESET_SLOT_PACK: return arg - PRESET_SLOT_OWN + 1
	}
	return PACK_PRESET + arg - PRESET_SLOT_PACK
}

// The argument that stands for the preset numbered `n`; false for none.
preset_slot_of :: proc(n: int) -> (arg: int, ok: bool) {
	switch {
	case n <= 0:                return
	case preset_of_pack(n):     arg = n - PACK_PRESET + PRESET_SLOT_PACK
	case preset_built_in(n):    arg = n - BUILT_IN_PRESET
	case n <= MAX_PRESETS:      arg = n - 1 + PRESET_SLOT_OWN
	case:                       return
	}
	return arg, arg < PRESET_SLOTS
}

// The argument's name in settings.txt: a built-in by its name, underscores for spaces, as
// lines split at spaces; the person's own and the packs' by their place ("Own3",
// "Pack12"), which preset_slots_save backs with the pack's name.
preset_slot_name :: proc(arg: int) -> string {
	switch {
	case arg < PRESET_SLOT_OWN:
		name, _ := strings.replace_all(BUILT_IN_PRESETS[arg].name, " ", "_", context.temp_allocator)
		return name
	case arg < PRESET_SLOT_PACK: return fmt.tprintf("Own%d", arg - PRESET_SLOT_OWN + 1)
	}
	return fmt.tprintf("Pack%d", arg - PRESET_SLOT_PACK + 1)
}

// The preset's name for a tile, or "Preset" for one that is gone.
preset_slot_label :: proc(app: ^App, arg: int) -> string {
	if p, ok := preset_at(app, preset_slot_number(arg)); ok do return preset_name(p)
	return "Preset"
}

// The icon of the preset's brush.
preset_slot_icon :: proc(app: ^App, arg: int) -> rune {
	if p, ok := preset_at(app, preset_slot_number(arg)); ok do return BRUSHES[p.values.kind].icon
	return BRUSHES[.Draw].icon
}

// Calls `f` on every slot the person arranges that can hold a command: the bars (shelf
// pages, docks, rails, the brush pie), the pies, the dials' sectors, the favourites, the
// gesture map and the keys.
@(private = "file")
slots_each :: proc(app: ^App, f: proc(s: ^Pie_Slot, data: rawptr), data: rawptr) {
	k := &app.kit
	for which in Bar_Which {
		l := bar_list(app, which)
		for &s in l.slots do f(&s, data)
	}
	for &pie in k.pies do for &s in pie do f(&s, data)
	for &dial in k.dials do for &sector in dial do if s, ok := &sector.(Bar_Slot); ok do f(s, data)
	for &s in k.favourites do f(&s, data)
	for &s in app.nav.gestures do f(&s, data)
	for &o in app.key_overrides[:app.key_override_count] {
		s := Pie_Slot{o.command, o.arg}
		f(&s, data)
		o.command, o.arg = s.id, s.arg
	}
}

// After the person's own preset `i` (from 0) was deleted: a slot that held it holds
// nothing (a bar closes up round it), and those after it move down one, so each keeps its
// preset.
preset_slots_deleted :: proc(app: ^App, i: int) {
	gone := PRESET_SLOT_OWN + i
	slots_each(app, proc(s: ^Pie_Slot, data: rawptr) {
		gone := (^int)(data)^
		if s.id != .Brush_Preset || s.arg < gone || s.arg >= PRESET_SLOT_PACK do return
		if s.arg == gone do s^ = {}
		else do s.arg -= 1
	}, &gone)
	for which in Bar_Which do if which != .Brush_Pie do bar_close_up(app, which)
}

// A bar's slots without the empty ones a deleted preset left, in their order.
@(private = "file")
bar_close_up :: proc(app: ^App, which: Bar_Which) {
	l := bar_list(app, which)
	count := clamp(l.count, 0, len(l.slots))
	kept := 0
	for i in 0 ..< count {
		if l.slots[i].id == .None do continue
		l.slots[kept], l.looks[kept] = l.slots[i], l.looks[i]
		kept += 1
	}
	for i in kept ..< count do l.slots[i], l.looks[i] = {}, {}
	l.count = kept
}

// Settings.txt's `preset_slot Pack<n> <pack id> <name>` lines: the pack and name behind
// each pack preset a slot holds, so the next run finds it wherever the library's order put
// it then.
preset_slots_save :: proc(app: ^App, out: ^strings.Builder) {
	seen: [PRESET_SLOT_PACKS_MAX]bool
	slots_each(app, proc(s: ^Pie_Slot, data: rawptr) {
		if s.id == .Brush_Preset && s.arg >= PRESET_SLOT_PACK && s.arg < PRESET_SLOTS do (^[PRESET_SLOT_PACKS_MAX]bool)(data)[s.arg - PRESET_SLOT_PACK] = true
	}, &seen)
	for held, j in seen {
		if !held || j >= len(app.library.presets) do continue
		p := &app.library.presets[j]
		fmt.sbprintfln(out, "preset_slot %s %s %s", preset_slot_name(PRESET_SLOT_PACK + j), p.pack, preset_escape(preset_name(&p.preset)))
	}
}

// A `preset_slot` line read, its old argument and the pack preset it names now; false for
// a damaged line or a preset the library no longer has.
preset_slot_line :: proc(app: ^App, f: []string) -> (old, now: int, ok: bool) {
	if len(f) != 4 || !strings.has_prefix(f[1], "Pack") do return
	n := strconv.parse_int(f[1][len("Pack"):]) or_return
	if n < 1 || n > PRESET_SLOT_PACKS_MAX do return
	found := pack_preset_find(app, f[2], preset_unescape(f[3]))
	if found == 0 do return
	now = preset_slot_of(found) or_return
	return PRESET_SLOT_PACK + n - 1, now, true
}

// Moves every slot that held pack preset argument `from[i]` to `to[i]` at once, after
// settings.txt is read; a slot whose pack preset was not found holds nothing.
preset_slots_retarget :: proc(app: ^App, from, to: []int) {
	Map :: struct {
		from, to: []int,
	}
	m := Map{from, to}
	slots_each(app, proc(s: ^Pie_Slot, data: rawptr) {
		if s.id != .Brush_Preset || s.arg < PRESET_SLOT_PACK do return
		m := (^Map)(data)
		for old, i in m.from do if s.arg == old {
			s.arg = m.to[i]
			return
		}
		s^ = {}
	}, &m)
	for which in Bar_Which do if which != .Brush_Pie do bar_close_up(app, which)
}
