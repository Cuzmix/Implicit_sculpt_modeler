package main

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../geom"
import "../ui"

// Settings > Interface > Look: the interface's colours as themes. Six come with the app
// (Look); a person's own are seeds kept beside them (User_Theme). Whatever is shown is
// Theme_State.seed: the chosen theme's own, or a draft once a control moved it, which
// Keep saves as a theme of their own and Undo puts back. Lens, Studio and Graphite keep
// their exact colours wherever a seed still holds what theirs does (ui.theme_from_seed),
// so changing only the accent of Lens leaves every grey of Lens alone. Day and night
// themes follow the device's light or dark setting when Match device is on.

// How many themes of their own a person keeps, and how long a name may be.
USER_THEMES :: 24
THEME_NAME :: 32

User_Theme :: struct {
	name: [THEME_NAME]u8, // up to its first zero byte
	base: Look, // the built-in theme it began as, whose exact colours it keeps where it can
	seed: ui.Theme_Seed,
	over: ui.Theme_Overrides, // colours set by hand in Every colour
}

// A theme by where it is: a built-in one (user -1) or the person's own number `user`.
Theme_Ref :: struct {
	look: Look,
	user: i32,
}

Theme_State :: struct {
	seed:   ui.Theme_Seed, // what the interface shows: the chosen theme's seed or a draft of it
	over:   ui.Theme_Overrides, // ...and its colours set by hand
	user:   i32, // the chosen theme of the person's own, or -1 for the built-in Kit_State.look
	list:   [USER_THEMES]User_Theme,
	count:  int,
	match:  bool, // Match device: the day theme in a light system theme, the night one in a dark
	day:    Theme_Ref,
	night:  Theme_Ref,
	device_dark: bool, // what the device said last, for Match device
	compare: bool, // Hold to compare is held: the saved theme shows instead of the draft
	seed_read: bool, // a settings file named the seed shown (themes_settle)
	every:  bool, // Every colour is open
	menu:   bool, // a card's menu (Rename, Duplicate, Share code, Delete)
	menu_at: ui.Rect,
	menu_of: Theme_Ref,
	code:   Theme_Code, // the Share code or Import code popover
	// Bring its background: a change of theme paints the viewport's background to go with
	// it. `brought` is what it painted last, so the background stays free to change by
	// hand until the theme next changes.
	bring:   bool,
	brought: Background_Settings,
}

// The popover that shows a theme as a code to copy, or takes one pasted to import.
Theme_Code :: struct {
	open:   bool,
	importing: bool,
	at:     ui.Rect,
	text:   [THEME_CODE]u8,
	note:   string, // what the last Copy, Paste or Import did (a constant)
}

// The longest theme code: the seed's words and every colour set by hand fit well inside.
THEME_CODE :: 1024

@(rodata)
LOOK_SEEDS := [Look]ui.Theme_Seed {
	.Lens          = ui.THEME_SEED_LENS,
	.Studio        = ui.THEME_SEED_STUDIO,
	.Graphite      = ui.THEME_SEED_GRAPHITE,
	.Paper         = ui.THEME_SEED_PAPER,
	.Midnight      = ui.THEME_SEED_MIDNIGHT,
	.High_Contrast = ui.THEME_SEED_HIGH_CONTRAST,
}

// The accents offered as swatches: Lens's sea green first, then round the wheel, and a
// near-white for those who want no colour at all.
@(rodata)
THEME_ACCENTS := [?]ui.Color {
	{0x5e, 0xd6, 0xc4, 0xff},
	{0x5b, 0x8c, 0xff, 0xff},
	{0xa0, 0x8c, 0xff, 0xff},
	{0xff, 0x86, 0xb9, 0xff},
	{0xf0, 0x6a, 0x5e, 0xff},
	{0xf2, 0xa3, 0x3a, 0xff},
	{0xff, 0xd6, 0x0a, 0xff},
	{0x74, 0xcc, 0x7c, 0xff},
	{0xe9, 0xec, 0xef, 0xff},
}

// The hues of skin and clay, in degrees: a saturated accent among them reads as part of
// the model, so the Look page says so.
THEME_CLAY_HUES :: [2]f32{8, 48}

// The days themes start with: Paper by day, Lens by night.
THEME_DAY_DEFAULT :: Theme_Ref{.Paper, -1}
THEME_NIGHT_DEFAULT :: Theme_Ref{.Lens, -1}

// A built-in theme's exact colours: the three that were made by hand, or what the seed
// makes for the others.
look_exact :: proc(l: Look) -> ui.Theme {
	#partial switch l {
	case .Lens:     return ui.THEME_LENS
	case .Studio:   return ui.THEME_STUDIO
	case .Graphite: return ui.THEME_DARK
	}
	return ui.theme_derive(LOOK_SEEDS[l])
}

themes_init :: proc(k: ^Kit_State) {
	k.look = .Lens
	k.themes.user = -1
	k.themes.seed = LOOK_SEEDS[.Lens]
	k.themes.day = THEME_DAY_DEFAULT
	k.themes.night = THEME_NIGHT_DEFAULT
	k.themes.match = false
}

// The chosen theme, as a reference.
theme_ref :: proc(k: ^Kit_State) -> Theme_Ref {
	return {k.look, k.themes.user}
}

// A reference that still names a theme: one of the person's own that is gone falls back
// to its built-in.
theme_ref_valid :: proc(k: ^Kit_State, r: Theme_Ref) -> Theme_Ref {
	if r.user >= i32(k.themes.count) do return {r.look, -1}
	return {r.look, max(r.user, -1)}
}

// The seed a theme was saved with.
theme_ref_seed :: proc(k: ^Kit_State, ref: Theme_Ref) -> ui.Theme_Seed {
	r := theme_ref_valid(k, ref)
	return k.themes.list[r.user].seed if r.user >= 0 else LOOK_SEEDS[r.look]
}

// The colours a theme was saved with set by hand.
theme_ref_over :: proc(k: ^Kit_State, ref: Theme_Ref) -> ui.Theme_Overrides {
	r := theme_ref_valid(k, ref)
	return k.themes.list[r.user].over if r.user >= 0 else {}
}

// The built-in theme a reference starts from.
theme_ref_base :: proc(k: ^Kit_State, ref: Theme_Ref) -> Look {
	r := theme_ref_valid(k, ref)
	return k.themes.list[r.user].base if r.user >= 0 else r.look
}

theme_ref_name :: proc(k: ^Kit_State, ref: Theme_Ref) -> string {
	r := theme_ref_valid(k, ref)
	if r.user >= 0 do return string(cstring(raw_data(k.themes.list[r.user].name[:])))
	return LOOK_NAMES[r.look]
}

// The theme a seed and its colours set by hand make when it began as the built-in `base`.
theme_of :: proc(seed: ui.Theme_Seed, over: ui.Theme_Overrides, base: Look) -> ui.Theme {
	t := ui.theme_from_seed(seed, look_exact(base), LOOK_SEEDS[base])
	ui.theme_overrides_apply(&t, over)
	return t
}

// The chosen theme's colours as saved, before any draft.
theme_saved :: proc(k: ^Kit_State) -> ui.Theme {
	r := theme_ref(k)
	return theme_of(theme_ref_seed(k, r), theme_ref_over(k, r), theme_ref_base(k, r))
}

// What the interface shows now: the draft, or while Hold to compare is held, the theme
// as it was saved.
theme_current :: proc(k: ^Kit_State) -> ui.Theme {
	if k.themes.compare do return theme_saved(k)
	return theme_of(k.themes.seed, k.themes.over, theme_ref_base(k, theme_ref(k)))
}

// The colours set by hand in the theme shown now (the saved ones while Hold to compare
// is held).
theme_shown_over :: proc(k: ^Kit_State) -> ui.Theme_Overrides {
	return theme_ref_over(k, theme_ref(k)) if k.themes.compare else k.themes.over
}

// The wireframe's colour for the renderer, linear as it takes it: zero, the renderer's
// own, until the theme shown sets one by hand, so a theme alone never changes a render.
theme_wire_color :: proc(k: ^Kit_State) -> [4]f32 {
	over := theme_shown_over(k)
	if .Wire not_in over.set do return {}
	c := over.colors[.Wire]
	return {geom.srgb_decode(f32(c.r) / 255), geom.srgb_decode(f32(c.g) / 255), geom.srgb_decode(f32(c.b) / 255), 1}
}

// Model mode's selected faces: their own orange until the theme shown sets a colour by
// hand, drawn as see-through as the orange is.
theme_selection_color :: proc(k: ^Kit_State) -> [4]f32 {
	over := theme_shown_over(k)
	if .Selection not_in over.set do return MODEL_SELECTION_COLOR
	c := over.colors[.Selection]
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, MODEL_SELECTION_COLOR.a}
}

// A viewport background to go with theme `t`: a pale wash of a light theme's ground, a
// lift of a dark one's in the default's own steps, and plain black behind pure black.
theme_background :: proc(t: ui.Theme) -> Background_Settings {
	frame := ui.Color{t.frame.r, t.frame.g, t.frame.b, 255}
	rgb :: proc(c: ui.Color) -> [3]f32 {return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255}}
	white, black := ui.Color{255, 255, 255, 255}, ui.Color{0, 0, 0, 255}
	if ui.color_luminance(frame) > 0.5 do return {true, rgb(ui.color_mix(frame, white, 0.5)), rgb(ui.color_mix(frame, black, 0.18))}
	if max(frame.r, frame.g, frame.b) < 4 do return {false, {}, {}}
	return {true, rgb(ui.color_mix(frame, white, 0.2)), rgb(ui.color_mix(frame, white, 0.03))}
}

// Each frame: with Bring its background on, a theme that changed paints the background.
theme_bring_background :: proc(app: ^App) {
	ts := &app.kit.themes
	if !ts.bring do return
	b := theme_background(theme_current(&app.kit))
	if b == ts.brought do return
	ts.brought = b
	app.background = b
}

// Whether a control moved the chosen theme away from what it was saved as.
theme_draft :: proc(k: ^Kit_State) -> bool {
	r := theme_ref(k)
	return k.themes.seed != theme_ref_seed(k, r) || k.themes.over != theme_ref_over(k, r)
}

// Shows theme `r` as saved, dropping any draft. Picking a light theme makes it the day
// theme and a dark one the night theme, so Dark and Light (and Match device) go back to
// the last of each that was picked.
theme_choose :: proc(k: ^Kit_State, ref: Theme_Ref) {
	r := theme_ref_valid(k, ref)
	k.look, k.themes.user = r.look, r.user
	k.themes.seed = theme_ref_seed(k, r)
	k.themes.over = theme_ref_over(k, r)
	if k.themes.seed.mode == .Light do k.themes.day = r
	else do k.themes.night = r
}

// Keep: the draft becomes the chosen theme of the person's own, written over it, or, for
// a built-in one, a new theme named after it ("Lens 2"). Returns false when the list is full.
theme_keep :: proc(k: ^Kit_State) -> bool {
	ts := &k.themes
	r := theme_ref(k)
	if r.user >= 0 {
		ts.list[r.user].seed = ts.seed
		ts.list[r.user].over = ts.over
		theme_choose(k, r)
		return true
	}
	if ts.count == USER_THEMES do return false
	u := &ts.list[ts.count]
	u^ = {base = r.look, seed = ts.seed, over = ts.over}
	theme_name_set(u, theme_name_free(k, LOOK_NAMES[r.look]))
	ts.count += 1
	theme_choose(k, {r.look, i32(ts.count - 1)})
	return true
}

theme_name_set :: proc(u: ^User_Theme, name: string) {
	u.name = {}
	_ = copy(u.name[:THEME_NAME - 1], name)
}

// `name` with the first number after it that no theme is called yet ("Lens 2", "Lens 3").
theme_name_free :: proc(k: ^Kit_State, name: string) -> string {
	// "Lens 2" copied is "Lens 3", not "Lens 2 2".
	from := name
	if space := strings.last_index_byte(from, ' '); space > 0 {
		if _, numbered := strconv.parse_int(from[space + 1:]); numbered do from = from[:space]
	}
	for n := 2; ; n += 1 {
		next := fmt.tprintf("%s %d", from, n)
		if !theme_name_taken(k, next) do return next
	}
}

theme_name_taken :: proc(k: ^Kit_State, name: string) -> bool {
	for l in Look do if strings.equal_fold(LOOK_NAMES[l], name) do return true
	for i in 0 ..< k.themes.count do if strings.equal_fold(theme_ref_name(k, {.Lens, i32(i)}), name) do return true
	return false
}

// Match device: once a frame, the day or night theme as the device is light or dark. A
// draft is left alone until it is kept or undone, so a change of the system's theme never
// throws away what is being made.
theme_follow_device :: proc(k: ^Kit_State, dark: bool) {
	k.themes.device_dark = dark
	if !k.themes.match || theme_draft(k) do return
	want := theme_ref_valid(k, k.themes.night if dark else k.themes.day)
	if want != theme_ref(k) {
		day, night := k.themes.day, k.themes.night
		theme_choose(k, want)
		k.themes.day, k.themes.night = day, night
	}
}

// A seed as the words of a settings line: its mode, then key=value pairs, so a field
// added later is a new pair an older app steps over.
theme_seed_text :: proc(s: ui.Theme_Seed, over: ui.Theme_Overrides = {}) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b,
		"%s hue=%v tint=%v contrast=%v opacity=%v corners=%s accent=%s chosen=%s black=%d shadow=%d",
		"light" if s.mode == .Light else "dark",
		s.hue,
		s.tint,
		s.contrast,
		s.opacity,
		strings.to_lower(fmt.tprint(s.corners), context.temp_allocator),
		theme_hex(s.accent),
		strings.to_lower(fmt.tprint(s.chosen), context.temp_allocator),
		1 if s.black else 0,
		1 if s.shadow else 0,
	)
	for token in over.set do fmt.sbprintf(&b, " %s=%s", ui.THEME_TOKEN_KEYS[token], theme_hex(over.colors[token]))
	return strings.to_string(b)
}

theme_hex :: proc(c: ui.Color) -> string {
	return fmt.tprintf("#%02x%02x%02x", c.r, c.g, c.b)
}

// Reads what theme_seed_text wrote over `seed`: a word it does not know is stepped over and
// a value is held to its range, so a damaged line never makes a theme nobody could read.
theme_seed_parse :: proc(words: []string, seed: ui.Theme_Seed) -> (s: ui.Theme_Seed, over: ui.Theme_Overrides, ok: bool) {
	s = seed
	// Fractions are written as they are, so they read back to the bit; a value over 1 is a
	// percentage, as a person typing a code by hand may write one.
	fraction :: proc(v: f32) -> f32 {return v / 100 if v > 1 else v}
	for w in words {
		switch w {
		case "dark":  s.mode = .Dark; ok = true; continue
		case "light": s.mode = .Light; ok = true; continue
		}
		key, _, value := strings.partition(w, "=")
		number, is_number := strconv.parse_f32(value)
		switch key {
		case "hue":      if is_number do s.hue = clamp(number, 0, 360)
		case "tint":     if is_number do s.tint = clamp(fraction(number), 0, 1)
		case "contrast": if is_number do s.contrast = clamp(fraction(number), 0, 1)
		case "opacity":  if is_number do s.opacity = clamp(fraction(number), ui.THEME_OPACITY_MIN, 1)
		case "black":    s.black = value == "1"
		case "shadow":   s.shadow = value == "1"
		case "corners":
			switch value {
			case "square": s.corners = .Square
			case "normal": s.corners = .Normal
			case "round":  s.corners = .Round
			}
		case "chosen":
			switch value {
			case "soft":  s.chosen = .Soft
			case "solid": s.chosen = .Solid
			}
		case "accent":
			if rgb, hex_ok := color_hex_parse(value); hex_ok do s.accent = theme_color(rgb)
		case:
			for name, token in ui.THEME_TOKEN_KEYS {
				if name != key do continue
				if rgb, hex_ok := color_hex_parse(value); hex_ok {
					over.set += {token}
					over.colors[token] = theme_color(rgb)
				}
			}
		}
	}
	return
}

theme_color :: proc(rgb: [3]f32) -> ui.Color {
	return {u8(clamp(rgb.r, 0, 1) * 255 + 0.5), u8(clamp(rgb.g, 0, 1) * 255 + 0.5), u8(clamp(rgb.b, 0, 1) * 255 + 0.5), 255}
}

theme_rgb :: proc(c: ui.Color) -> [3]f32 {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255}
}

// The settings lines of the themes: each of the person's own, then what is shown (its
// seed, draft or not), which of the person's own is chosen, and the day and night themes.
// The chosen built-in theme is the `look` row.
themes_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	ts := &k.themes
	for i in 0 ..< ts.count {
		u := &ts.list[i]
		fmt.sbprintfln(out, "user_theme %s %v %s", preset_escape(theme_ref_name(k, {.Lens, i32(i)})), u.base, theme_seed_text(u.seed, u.over))
	}
	fmt.sbprintfln(out, "look_user %d", ts.user)
	fmt.sbprintfln(out, "look_seed %s", theme_seed_text(ts.seed, ts.over))
	fmt.sbprintfln(out, "look_match %d", 1 if ts.match else 0)
	fmt.sbprintfln(out, "look_background %d", 1 if ts.bring else 0)
	fmt.sbprintfln(out, "look_day %v %d", ts.day.look, ts.day.user)
	fmt.sbprintfln(out, "look_night %v %d", ts.night.look, ts.night.user)
}

// Once a settings file is read: references to themes that are not there fall back to
// their built-in ones, and a file from before themes, with no seed line, shows its look's.
themes_settle :: proc(k: ^Kit_State) {
	ts := &k.themes
	ts.user = theme_ref_valid(k, theme_ref(k)).user
	ts.day = theme_ref_valid(k, ts.day)
	ts.night = theme_ref_valid(k, ts.night)
	if !ts.seed_read {
		ts.seed = theme_ref_seed(k, theme_ref(k))
		ts.over = theme_ref_over(k, theme_ref(k))
	}
	ts.seed_read = false
	// The background read with the settings is the one to keep: only a later change of
	// theme brings another.
	ts.brought = theme_background(theme_current(k))
}

// Reads one themes line; false when `f` is not one. The `look` row comes through the
// SETTINGS table; themes_settle checks what was read once every line is in.
themes_line :: proc(k: ^Kit_State, f: []string) -> bool {
	ts := &k.themes
	look_of :: proc(word: string) -> (Look, bool) {
		for l in Look do if fmt.tprint(l) == word do return l, true
		return .Lens, false
	}
	switch f[0] {
	case "user_theme":
		if len(f) < 4 || ts.count == USER_THEMES do return true
		base, ok := look_of(f[2])
		if !ok do return true
		u := &ts.list[ts.count]
		u^ = {base = base}
		u.seed, u.over, ok = theme_seed_parse(f[3:], LOOK_SEEDS[base])
		if !ok do return true
		theme_name_set(u, preset_unescape(f[1]))
		ts.count += 1
	case "look_user":
		if n, ok := strconv.parse_int(f[1]); ok do ts.user = i32(clamp(n, -1, USER_THEMES))
	case "look_seed":
		if s, o, ok := theme_seed_parse(f[1:], ts.seed); ok do ts.seed, ts.over = s, o
		ts.seed_read = true
	case "look_match":
		ts.match = f[1] == "1"
	case "look_background":
		ts.bring = f[1] == "1"
	case "look_day", "look_night":
		if len(f) < 3 do return true
		l, ok := look_of(f[1])
		n, n_ok := strconv.parse_int(f[2])
		if !ok || !n_ok do return true
		r := Theme_Ref{l, i32(clamp(n, -1, USER_THEMES))}
		if f[0] == "look_day" do ts.day = r
		else do ts.night = r
	case:
		return false
	}
	return true
}

// Reset Look settings: Lens, by night, with Match device off. The person's own themes stay.
themes_reset :: proc(k: ^Kit_State) {
	list, count := k.themes.list, k.themes.count
	themes_init(k)
	k.themes.list, k.themes.count = list, count
}

// The hues the Tint slider runs through, a stop every 60 degrees.
@(rodata)
THEME_HUES := [7]ui.Color{{0xd9, 0x4c, 0x4c, 0xff}, {0xd9, 0xd9, 0x4c, 0xff}, {0x4c, 0xd9, 0x4c, 0xff}, {0x4c, 0xd9, 0xd9, 0xff}, {0x4c, 0x4c, 0xd9, 0xff}, {0xd9, 0x4c, 0xd9, 0xff}, {0xd9, 0x4c, 0x4c, 0xff}}

// Whether a colour is a saturated one among skin and clay hues.
theme_accent_near_clay :: proc(c: ui.Color) -> bool {
	hi := max(c.r, c.g, c.b)
	lo := min(c.r, c.g, c.b)
	if int(hi) - int(lo) < 60 do return false
	r, g, b := f32(c.r), f32(c.g), f32(c.b)
	d := f32(hi) - f32(lo)
	h: f32
	switch hi {
	case c.r: h = 60 * (g - b) / d
	case c.g: h = 60 * ((b - r) / d + 2)
	case:     h = 60 * ((r - g) / d + 4)
	}
	if h < 0 do h += 360
	clay := THEME_CLAY_HUES
	return h >= clay[0] && h <= clay[1]
}

// The Look page's rows: the draft's Keep and Undo, the gallery, Dark, Light or Match
// device, the accent, the chosen tile's style, the four sliders, the corners, Pure black,
// panel shadows and the contrast check. Every control writes the seed only; the theme is
// derived from it as the frame starts, so nothing here holds a colour between frames.
settings_look :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	ts := &k.themes
	seed := &ts.seed

	// The draft's row is always there, its buttons waking once a control below moves the
	// theme, so the first change never pushes the page down under the finger.
	draft := theme_draft(k)
	name := theme_ref_name(k, theme_ref(k))
	ui.paragraph(ctx, fmt.tprintf("%s, edited: keep it as a theme of your own, or undo.", name) if draft else "Pick a theme, or change anything below to make one of your own.")
	ui.begin(ctx, "look draft", {direction = .Row, gap = 8})
	if ui.button(ctx, "Undo##look draft", .Bordered, enabled = draft, reason = "Nothing has changed") do theme_choose(k, theme_ref(k))
	keep_name := "Keep##look draft" if ts.user >= 0 else "Keep as new##look draft"
	keep_room := ts.user >= 0 || ts.count < USER_THEMES
	if ui.button(ctx, keep_name, .Solid, .Accent, enabled = draft && keep_room, reason = "Nothing has changed" if !draft else "You have as many themes of your own as can be kept") do _ = theme_keep(k)
	// Held, the theme as it was saved shows in place of the draft.
	hold := ui.area(ctx, "Hold to compare##look", {132, t.target}, drag = false)
	vis := ui.Rect{hold.rect.x, hold.rect.y + (hold.rect.h - t.control) * 0.5, hold.rect.w, t.control}
	ts.compare = draft && hold.held
	ui.fill_rect(ctx, vis, t.radius_medium, ui.color_fade(t.fill_pressed if ts.compare else t.fill, 1 if draft else 0.4))
	ui.text(ctx, "Hold to compare", vis.x + vis.w * 0.5, vis.y + vis.h * 0.5, t.text_size, ui.color_fade(t.text_secondary, 1 if draft else 0.4), .Regular, .Center)
	ui.end(ctx)

	// The gallery: the built-in themes, then the person's own, as many to a row as fit.
	columns := max(int(ui.fill_width(ctx) / ui.THEME_CARD.x), 1)
	n := len(Look) + ts.count
	chosen := theme_ref(k)
	for i in 0 ..< n {
		if i % columns == 0 do ui.begin(ctx, fmt.tprintf("look gallery row %d", i / columns), {direction = .Row, gap = 0})
		r := Theme_Ref{Look(i), -1} if i < len(Look) else Theme_Ref{.Lens, i32(i - len(Look))}
		if r.user >= 0 do r.look = ts.list[r.user].base
		tag := ""
		if r.user >= 0 do tag = "Yours"
		else if r.look >= .Paper do tag = "New"
		look := theme_of(theme_ref_seed(k, r), theme_ref_over(k, r), theme_ref_base(k, r))
		res := ui.theme_card(ctx, fmt.tprintf("%s##look card %d", theme_ref_name(k, r), i), look, r == chosen && !draft, tag)
		if res.clicked do theme_choose(k, r)
		if res.menu do ts.menu, ts.menu_at, ts.menu_of = true, ctx.last_rect, r
		if i % columns == columns - 1 || i == n - 1 do ui.end(ctx)
	}

	modes := [3]string{"Dark", "Light", "Match device"}
	at := 2 if ts.match else int(seed.mode)
	if picked := ui.tabs(ctx, "Appearance##look", modes[:], at); picked >= 0 && picked != at {
		ts.match = picked == 2
		if ts.match do theme_follow_device(k, ts.device_dark)
		else do theme_choose(k, ts.night if picked == 0 else ts.day)
	}
	if ts.match {
		names := make([]string, n, context.temp_allocator)
		refs := make([]Theme_Ref, n, context.temp_allocator)
		day_at, night_at := 0, 0
		for i in 0 ..< n {
			refs[i] = Theme_Ref{Look(i), -1} if i < len(Look) else Theme_Ref{ts.list[i - len(Look)].base, i32(i - len(Look))}
			names[i] = theme_ref_name(k, refs[i])
			if refs[i] == ts.day do day_at = i
			if refs[i] == ts.night do night_at = i
		}
		ui.caption(ctx, "BY DAY")
		if picked := ui.select(ctx, "Day theme##look", names, day_at); picked >= 0 {
			ts.day = refs[picked]
			if !ts.device_dark do theme_choose(k, ts.day)
			ts.day = refs[picked]
		}
		ui.caption(ctx, "BY NIGHT")
		if picked := ui.select(ctx, "Night theme##look", names, night_at); picked >= 0 {
			ts.night = refs[picked]
			if ts.device_dark do theme_choose(k, ts.night)
			ts.night = refs[picked]
		}
		ui.paragraph(ctx, "The day theme shows while the device is set to light, the night theme while it is set to dark.")
	}

	ui.caption(ctx, "ACCENT")
	per_row := max(int(ui.fill_width(ctx) / t.target), 1)
	for c, i in THEME_ACCENTS {
		if i % per_row == 0 do ui.begin(ctx, fmt.tprintf("look accents %d", i / per_row), {direction = .Row, gap = 0})
		if ui.swatch(ctx, fmt.tprintf("Accent %s##look accent %d", theme_hex(c), i), c, t.target, selected = c == seed.accent).clicked do seed.accent = c
		if i % per_row == per_row - 1 || i == len(THEME_ACCENTS) - 1 do ui.end(ctx)
	}
	rgb := theme_rgb(seed.accent)
	if theme_color_well(app, "Any accent", &rgb) do seed.accent = theme_color(rgb)
	if theme_accent_near_clay(seed.accent) do ui.paragraph(ctx, "This accent sits among skin and clay colours, so a selection may read as part of the model.", color = t.warning)
	tiles := [2]string{"Soft", "Solid"}
	ui.caption(ctx, "CHOSEN BRUSH TILE")
	if picked := ui.tabs(ctx, "Chosen tile##look", tiles[:], int(seed.chosen)); picked >= 0 do seed.chosen = ui.Theme_Chosen(picked)

	ui.caption(ctx, "TINT")
	hue := seed.hue / 360
	if ui.gradient_slider(ctx, "##look tint", &hue, THEME_HUES[:], fmt.tprintf("%.0f°", seed.hue)) do seed.hue = clamp(hue * 360, 0, 360)
	_ = ui.slider(ctx, "Tint strength##look", &seed.tint, 0, 1, .Linear, fmt.tprintf("%.0f%%", seed.tint * 100))
	ui.caption(ctx, "SURFACES")
	_ = ui.slider(ctx, "Contrast##look", &seed.contrast, 0, 1, .Linear, fmt.tprintf("%.0f%%", seed.contrast * 100))
	_ = ui.slider(ctx, "Panel opacity##look", &seed.opacity, ui.THEME_OPACITY_MIN, 1, .Linear, fmt.tprintf("%.0f%%", seed.opacity * 100))
	corners := [3]string{"Square", "Normal", "Round"}
	if picked := ui.tabs(ctx, "Corners##look", corners[:], int(seed.corners)); picked >= 0 do seed.corners = ui.Theme_Corners(picked)
	if seed.mode == .Dark do _ = ui.switch_row(ctx, "Pure black##look", &seed.black)
	_ = ui.switch_row(ctx, "Panel shadows##look", &seed.shadow)
	ui.caption(ctx, "VIEWPORT")
	if ui.switch_row(ctx, "Bring its background##look", &ts.bring) && ts.bring do ts.brought = {}
	ui.paragraph(ctx, "Changing theme also changes the viewport's background to go with it. The wireframe, Model mode's selection and the spaces' colours are under Every colour.")

	// The contrast check: how the theme's text and accent read on its panels (WCAG 2).
	shown := theme_current(k)
	ground := ui.Color{shown.surface.r, shown.surface.g, shown.surface.b, 255}
	check :: proc(ctx: ^ui.Context, label: string, fg, bg: ui.Color, least: f32) {
		r := ui.color_contrast(fg, bg)
		ui.value_row(ctx, label, fmt.tprintf("%.1f : 1%s", r, "" if r >= least else ", too low"))
	}
	ui.caption(ctx, "CONTRAST CHECK")
	check(ctx, "Labels on panels", shown.text_secondary, ground, 4.5)
	check(ctx, "Hints on panels", shown.text_tertiary, ground, 3)
	check(ctx, "Accent on panels", shown.accent, ground, 3)
	check(ctx, "Text on the accent", shown.on_accent, shown.accent, 4.5)
	ui.paragraph(ctx, "Labels want 4.5 to 1 or more, hints and the accent 3 to 1, so everything stays readable in a bright room.")

	// Every colour: any of the theme's colours set by hand over what the seed made, each
	// with Reset once set.
	if ui.section(ctx, fmt.tprintf("Every colour (%d set by hand)##look every", card(ts.over.set)), &ts.every) {
		made := theme_of(ts.seed, {}, theme_ref_base(k, theme_ref(k)))
		for token in ui.Theme_Token {
			set := token in ts.over.set
			c := ts.over.colors[token] if set else ui.theme_token(&made, token)^
			ui.begin(ctx, fmt.tprintf("look every %v", token), {direction = .Row, gap = 8})
			ui.begin(ctx, fmt.tprintf("look every name %v", token), {direction = .Column, width = max(ui.fill_width(ctx) - 120, 80)})
			ui.label(ctx, ui.THEME_TOKEN_NAMES[token], t.text_size, t.text if set else t.text_secondary)
			ui.end(ctx)
			if set {
				if ui.button(ctx, fmt.tprintf("Reset##look every %v", token), .Light, width = 64) do ts.over.set -= {token}
			}
			ui.end(ctx)
			shown := theme_rgb(c)
			if theme_color_well(app, fmt.tprintf("%s##%v", ui.THEME_TOKEN_NAMES[token], token), &shown) {
				ts.over.set += {token}
				ts.over.colors[token] = theme_color(shown)
			}
		}
		ui.section_end(ctx)
	}

	share, take := kit_button_pair(ctx, "Share code##look", "Import code##look")
	if share do theme_share_open(k, ctx.last_rect)
	if take do ts.code = {open = true, importing = true, at = ctx.last_rect}
}

// A colour well alone, the width of the column, that opens the colour popover (as
// kit_color's does) beside its hex code: for colours with no channel sliders under them.
theme_color_well :: proc(app: ^App, name: string, rgb: ^[3]f32) -> (changed: bool) {
	ctx := &app.kit.ctx
	t := ctx.theme
	c := &app.kit.colors
	hex_w: f32 = 104
	well_w := max(ui.fill_width(ctx) - hex_w - 8, 28)
	ui.begin(ctx, fmt.tprintf("well row##%s", name), {direction = .Row, gap = 8})
	well := fmt.tprintf("%s##%s well", name, name)
	id := ui.id_of(ctx, well)
	open := c.pop && c.pop_of == id
	if open && c.pop_dirty {
		rgb^ = c.pop_set
		c.pop_dirty = false
		changed = true
	}
	if ui.swatch(ctx, well, overlay_color({rgb.r, rgb.g, rgb.b, 1}), t.target, selected = open, width = well_w).clicked {
		if open do c.pop = false
		else do c.pop, c.pop_of, c.pop_dirty, c.pop_changed, c.pop_scroll = true, id, false, false, 0
		open = c.pop
	}
	if open do c.pop_at, c.pop_value, c.pop_alive = ctx.last_rect, rgb^, true
	if typed, ok := kit_hex_field(app, name, rgb^, hex_w); ok {
		rgb^ = typed
		changed = true
	}
	ui.end(ctx)
	return
}

// Takes out theme `i` of the person's own. What named it (the chosen theme, the day and
// night themes) falls back to the built-in one it began as, and what named one after it
// moves down with it.
theme_delete :: proc(k: ^Kit_State, i: int) {
	ts := &k.themes
	if i < 0 || i >= ts.count do return
	base := ts.list[i].base
	follow :: proc(r: ^Theme_Ref, i: i32, base: Look) {
		if r.user == i do r^ = {base, -1}
		else if r.user > i do r.user -= 1
	}
	chosen := theme_ref(k)
	draft := theme_draft(k)
	follow(&chosen, i32(i), base)
	follow(&ts.day, i32(i), base)
	follow(&ts.night, i32(i), base)
	follow(&ts.menu_of, i32(i), base)
	for j in i ..< ts.count - 1 do ts.list[j] = ts.list[j + 1]
	ts.count -= 1
	ts.list[ts.count] = {}
	k.look, ts.user = chosen.look, chosen.user
	// The theme shown goes with it unless it was a draft, which stays a draft of the base.
	if !draft do ts.seed, ts.over = theme_ref_seed(k, chosen), theme_ref_over(k, chosen)
}

// A copy of theme `r` among the person's own, named "<name> 2" (or the next free number),
// chosen; false when the list is full.
theme_duplicate :: proc(k: ^Kit_State, ref: Theme_Ref) -> bool {
	ts := &k.themes
	if ts.count == USER_THEMES do return false
	r := theme_ref_valid(k, ref)
	u := &ts.list[ts.count]
	u^ = {base = theme_ref_base(k, r), seed = theme_ref_seed(k, r), over = theme_ref_over(k, r)}
	theme_name_set(u, theme_name_free(k, theme_ref_name(k, r)))
	ts.count += 1
	theme_choose(k, {u.base, i32(ts.count - 1)})
	return true
}

// Theme `i` of the person's own renamed: an empty name or one another theme has is
// refused (false), so every theme in the gallery and in Day and Night has a name of its own.
theme_rename :: proc(k: ^Kit_State, i: int, typed: string) -> bool {
	name := strings.trim_space(typed)
	if i < 0 || i >= k.themes.count || name == "" do return false
	if strings.equal_fold(theme_ref_name(k, {.Lens, i32(i)}), name) do return true
	if theme_name_taken(k, name) do return false
	theme_name_set(&k.themes.list[i], name)
	return true
}

// The code that shares a theme: "sculpt-theme 1", its name, the built-in theme it began
// as and its seed's words, one line a person can paste in a message.
theme_code :: proc(name: string, base: Look, seed: ui.Theme_Seed, over: ui.Theme_Overrides) -> string {
	return fmt.tprintf("sculpt-theme 1 %s %v %s", preset_escape(name), base, theme_seed_text(seed, over))
}

// Reads a code theme_code wrote; ok is false for anything that is not one.
theme_code_parse :: proc(text: string) -> (name: string, base: Look, seed: ui.Theme_Seed, over: ui.Theme_Overrides, ok: bool) {
	f := strings.fields(strings.trim_space(text), context.temp_allocator)
	if len(f) < 5 || f[0] != "sculpt-theme" || f[1] != "1" do return
	found := false
	for l in Look do if fmt.tprint(l) == f[3] do base, found = l, true
	if !found do return
	seed, over, ok = theme_seed_parse(f[4:], LOOK_SEEDS[base])
	name = strings.trim_space(preset_unescape(f[2]))
	if name == "" do name = "Imported"
	return
}

// Imports a code as a theme of the person's own and chooses it: its name is kept if no
// theme has it, else given the next free number. False when it is no code or the list is full.
theme_import :: proc(k: ^Kit_State, text: string) -> bool {
	ts := &k.themes
	name, base, seed, over, ok := theme_code_parse(text)
	if !ok || ts.count == USER_THEMES do return false
	if theme_name_taken(k, name) do name = theme_name_free(k, name)
	u := &ts.list[ts.count]
	u^ = {base = base, seed = seed, over = over}
	theme_name_set(u, name)
	ts.count += 1
	theme_choose(k, {base, i32(ts.count - 1)})
	return true
}

// Opens the Share code popover on what the interface shows (a draft too) beside `at`.
theme_share_open :: proc(k: ^Kit_State, at: ui.Rect) {
	ts := &k.themes
	name := theme_ref_name(k, theme_ref(k))
	if theme_draft(k) do name = fmt.tprintf("%s edited", name)
	ts.code = {open = true, at = at}
	_ = copy(ts.code.text[:THEME_CODE - 1], theme_code(name, theme_ref_base(k, theme_ref(k)), ts.seed, ts.over))
}

// A card's menu (Rename and Delete on the person's own; Duplicate and Share code on any)
// and the Share or Import code popover, over everything else.
kit_theme_menus :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	ts := &k.themes
	if ts.menu && !k.settings do ts.menu = false
	if ts.code.open && !k.settings do ts.code.open = false
	if ui.popover_begin(ctx, "theme menu", &ts.menu, ts.menu_at, .Below, {direction = .Column, gap = 0, padding = 6, width = 240}) {
		r := theme_ref_valid(k, ts.menu_of)
		if r.user >= 0 && ui.menu_item(ctx, "Rename...##theme", glyph = ui.ICON_PENCIL) {
			k.rename = {open = true, theme = int(r.user) + 1, at = ts.menu_at}
			ts.menu = false
		}
		if ui.menu_item(ctx, "Duplicate##theme", glyph = ui.ICON_COPY, enabled = ts.count < USER_THEMES, reason = "You have as many themes of your own as can be kept") {
			_ = theme_duplicate(k, r)
			ts.menu = false
		}
		if ui.menu_item(ctx, "Share code##theme", glyph = ui.ICON_EXPORT) {
			theme_choose(k, r)
			theme_share_open(k, ts.menu_at)
			ts.menu = false
		}
		if r.user >= 0 && ui.menu_item(ctx, "Delete theme##theme", glyph = ui.ICON_TRASH, tone = .Danger) {
			theme_delete(k, int(r.user))
			ts.menu = false
		}
		ui.popover_end(ctx)
	}
	c := &ts.code
	// Opened low on the screen (Share code at the page's foot), it opens upward, so the
	// field and its buttons stay on screen.
	side := ui.Side.Above if c.at.y > ctx.input.window.y * 0.5 else .Below
	if ui.popover_begin(ctx, "theme code", &c.open, c.at, side, {direction = .Column, gap = 6, padding = 12, width = 340}) {
		defer ui.popover_end(ctx)
		ui.caption(ctx, "IMPORT A THEME" if c.importing else "SHARE THIS THEME")
		ui.paragraph(ctx, "Paste a theme code; Import adds it to your themes and shows it." if c.importing else "Copy this code and paste it into Import code on any device. It is plain text, so it fits in a message.")
		_ = ui.text_field(ctx, "code##theme code", c.text[:THEME_CODE - 1], hint = "sculpt-theme 1 ...")
		if c.note != "" do ui.paragraph(ctx, c.note)
		text := string(cstring(raw_data(c.text[:])))
		if c.importing {
			paste, add := kit_button_pair(ctx, "Paste", "Import", tone_b = .Accent)
			if paste {
				c.text = {}
				_ = copy(c.text[:THEME_CODE - 1], platform_clipboard_text())
				c.note = ""
			}
			if add {
				if theme_import(k, text) do c.open = false
				else do c.note = "That is no theme code: one starts with sculpt-theme 1." if ts.count < USER_THEMES else "You have as many themes of your own as can be kept."
			}
		} else {
			copied, done := kit_button_pair(ctx, "Copy", "Done", tone_a = .Accent)
			if copied do c.note = "Copied." if platform_clipboard_set(text) else "Copying was refused: select the code and copy it by hand."
			if done do c.open = false
		}
	}
}
