package main

import "core:fmt"
import "core:math/linalg"
import "core:strings"

import "../sculpt"
import "../ui"

// The Lens panel stack (round 2 of the mockups, screens sculpt2 and brushPanel): in Lens
// the palette tray is drawn as a stack of cards down the pen side, Brush, Symmetry,
// Layers and Scene, then Palettes, which keeps the whole tray (every palette and section)
// within reach until the later rounds give its sections panels of their own. Each card
// has the mockups' header: a grip that drags it up or down the stack (or out, to float),
// a chevron that folds it to its header and a line saying what it holds, its icon and
// title, Float (or Dock) and its options. The Brush card shows the brush's card, Radius and
// Strength always, then the Brush palette's sections as groups that fold, each saying how
// it is set while folded, in place of the tray's list beside one section. The stack is
// the tray's panel (Kit_Window.Inspector), so it docks, floats and opens wherever the tray
// does.

// Every panel the stack holds (round 3, PR 9): its cards, then a palette for each tray
// section, in Kit_Section's order, which draws exactly what the tray drew under that
// section. Layers, Material and Lights have a card and their full section beside it
// (Layer_Settings, Material_Settings, Light_Settings); the Environment section is its
// card. Cases are appended, never reordered: files name them by panel_word, never by
// number, but the exit stats and tests name them too.
Panel_Kind :: enum u8 {
	Brush,
	Symmetry,
	Layers,
	Scene,
	Tools,
	Palettes,
	// The look's cards, which a fresh layout leaves out and Studio shows (lens_studio.odin).
	Lights,
	Material,
	Environment,
	// The Brush palette's sections.
	Preset,
	Stroke,
	Paint_Color,
	Recall,
	Falloff,
	Samples,
	Alpha,
	Pen,
	Options,
	Recorder,
	// The Object palette's.
	Transform,
	Levels,
	Hd,
	Topology,
	Mask,
	Sets,
	Visibility,
	Paint,
	Groups,
	Morph,
	Layer_Settings,
	Deform,
	Deformers,
	Remesh,
	Mirror,
	Voxels,
	Retopo,
	Textures,
	Project,
	Booleans,
	Extract,
	// The Scene palette's.
	Objects,
	Add,
	Look,
	Material_Settings,
	Light_Settings,
	Render,
	Lens,
	Finish,
	Camera,
	Turntable,
	Print,
	Floor,
	Background,
}
// A bit_set of them stays one u64.
#assert(len(Panel_Kind) <= 64)

// The cards' names, as a layout line and Search say them (the Brush card's title is the
// tool's while another tool is held); a section's is its section's title.
@(rodata)
STACK_CARD_NAMES := #partial [Panel_Kind]string {
	.Brush    = "Brush",
	.Symmetry = "Symmetry",
	.Layers   = "Layers",
	.Scene    = "Scene",
	.Tools       = "Tools",
	.Palettes    = "Palettes",
	.Lights      = "Lights",
	.Material    = "Material",
	.Environment = "Environment",
}

@(rodata)
STACK_CARD_ICONS := #partial [Panel_Kind]rune {
	.Brush    = ui.ICON_BRUSH,
	.Symmetry = ICON_SYMMETRY,
	.Layers   = ICON_OBJECTS,
	.Scene    = ui.ICON_SHAPES,
	.Tools       = ICON_SQUARE_DASHED,
	.Palettes    = ui.ICON_PANEL,
	.Lights      = ui.ICON_SUN,
	.Material    = ICON_MATERIAL,
	.Environment = ui.ICON_IMAGE,
}

// As a fresh layout has it: the Brush card open, the others folded to their headers; and
// the Brush card's groups that start folded (the rest start open).
STACK_OPEN_DEFAULT :: bit_set[Panel_Kind]{.Brush}
// The cards a fresh layout leaves out of the stack, and every section's palette: opening
// one of their sections, or a workspace's layout naming them, puts them in.
STACK_HIDDEN_DEFAULT :: STACK_LOOK_CARDS | STACK_SECTION_PANELS
STACK_LOOK_CARDS :: bit_set[Panel_Kind]{.Lights, .Material, .Environment}
// The cards, and (Odin takes no range in a bit_set literal) the sections' palettes as
// everything else; a complement keeps to the enum's cases.
STACK_CARDS :: bit_set[Panel_Kind]{.Brush, .Symmetry, .Layers, .Scene, .Tools, .Palettes, .Lights, .Material, .Environment}
STACK_SECTION_PANELS :: ~STACK_CARDS
STACK_SHUT_DEFAULT :: bit_set[Kit_Section]{.Preset, .Paint_Color, .Samples, .Pen, .Options, .Recorder}

// The stack's state, in Kit_State: the cards' order, which are open and which float (each
// with its window), the Brush card's folded groups, the card its grip is carrying and the
// card whose options are open; where each card was laid out (for a carried card's drop);
// and for the exit stats, folds and moves.
Lens_Stack :: struct {
	order:   [len(Panel_Kind)]Panel_Kind,
	open:    bit_set[Panel_Kind],
	floated: bit_set[Panel_Kind],
	hidden:  bit_set[Panel_Kind], // left out of the stack: not drawn, docked or floating
	windows: [Panel_Kind]ui.Window,
	shut:    bit_set[Kit_Section],
	carry:   Maybe(Stack_Carry),
	menu:    bool,
	menu_of: Panel_Kind,
	menu_at: ui.Rect,
	rects:   [Panel_Kind]ui.Rect,
	folds:   int,
	moves:   int,
	// Sizes (lens_resize.odin): the stack's width (0 for a fresh layout's), each docked
	// card's content height (0 to fit it), each floating card's size (0 across for the
	// stack's width, 0 down to fit), the scroll of each card shown shorter than its content,
	// where each card's content was laid out, the resize under way, the last tap on a
	// handle (for a double tap) and, for the exit stats, how many resizes there were; and
	// the docked stack's panel, which a press on a card's content scrolls.
	width:     f32,
	heights:   [Panel_Kind]f32,
	sizes:     [Panel_Kind][2]f32,
	scrolls:   [Panel_Kind]f32,
	bodies:    [Panel_Kind]ui.Rect,
	drag:      Stack_Drag,
	tap:       Handle_Tap,
	resizes:   int,
	owner:     ui.Id,
	// With panes beside the main one the stack is a strip of tabs (lens_panes.odin): the
	// card a tab opened over the view and where its tab is, and how many were opened.
	tab:       Panel_Kind,
	tab_open:  bool,
	tab_at:    ui.Rect,
	tabs:      int,
	// How the docked stack shows (the layout's): its cards, or the strip of their icons
	// beside the rail, each opening its card over the view (lens_panes.odin); and where
	// each icon was laid out, for Show where to open its card from.
	density:  Stack_Density,
	strip_at: [Panel_Kind]ui.Rect,
	// Palette groups (stack_groups.odin): the cards that are tabs of the card before them
	// (never the first), the tab each group's host shows, and for the exit stats, how many
	// joins and takes out there were.
	joined: bit_set[Panel_Kind],
	shown:  [Panel_Kind]Panel_Kind,
	joins:  int,
	// Columns (stack_groups.odin): the tabs that begin their group's second column, each
	// host's second column width (0 for the usual) and the floating groups whose second
	// column stands on their left.
	beside:      bit_set[Panel_Kind],
	beside_w:    [Panel_Kind]f32,
	beside_left: bit_set[Panel_Kind],
	// Drop targets (stack_carry.odin), this frame's only: the cards laid out, each one's
	// rect as the panel shows it (clipped where the column scrolls), its header, its tab
	// row and each tab; the target under a carry and, for the exit stats, the drops that
	// changed the stack.
	seen:    bit_set[Panel_Kind],
	drop_at: [Panel_Kind]ui.Rect,
	head_at: [Panel_Kind]ui.Rect,
	row_at:  [Panel_Kind]ui.Rect,
	tabs_at: [Panel_Kind]ui.Rect,
	target:  Stack_Target,
	drops:   int,
	// A carry put down with Escape stays down until the press that began it ends, as the
	// grip or tab still held would start it again.
	carry_off: bool,
	// The strip's icons laid out this frame, and the icon a carry rests on: since when and
	// where, so resting there long enough joins its group (stack_carry.odin).
	strip_seen: bit_set[Panel_Kind],
	dwell:      Panel_Kind,
	dwell_on:   bool,
	dwell_from: f64,
	dwell_at:   [2]f32,
	// Sections as cards (round 3, PR 9b): the section's palette Show section opened last
	// while it is not kept (stack_visiting), the section opened last by stack_reveal (for
	// the markers the Lights and Lens sections show, and the exit stats) and how many visits
	// there were.
	visit:    Maybe(Panel_Kind),
	revealed: Maybe(Kit_Section),
	visits:   int,
	// Whether stack_default has set it up: a Kit_State nothing has set up yet (a test's)
	// holds a fresh layout's stack.
	set:     bool,
}

// The docked stack's density, as round 3's docks have it: Panels (the cards, open or
// folded, down the column) or Icons (the strip, whatever panes there are).
Stack_Density :: enum u8 {
	Panels,
	Icons,
}

// Puts the stack as a fresh layout has it.
stack_default :: proc(k: ^Kit_State) {
	s := &k.stack
	for c, i in Panel_Kind do s.order[i] = c
	s.open, s.floated, s.shut, s.hidden = STACK_OPEN_DEFAULT, {}, STACK_SHUT_DEFAULT, STACK_HIDDEN_DEFAULT
	s.windows = {}
	s.carry, s.menu, s.tab_open = nil, false, false
	s.width, s.heights, s.sizes, s.scrolls, s.drag = 0, {}, {}, {}, {}
	s.density, s.strip_at = .Panels, {}
	s.joined, s.beside, s.beside_left, s.beside_w = {}, {}, {}, {}
	for c in Panel_Kind do s.shown[c] = c
	s.visit, s.revealed = nil, nil
	s.set = true
}

// The stack's line in a workspace's layout, `stack <card>[+] ...` in its order with a + on
// the open ones and a card left out written `-Card`, only where it differs from a fresh
// layout's; floating cards dock again when a layout is put in place. A section's palette
// is written only while it is in the stack (`section:Mask+`): one left out is as a fresh
// layout has it, so the line stays as short as before sections could be cards.
stack_layout_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	s := &k.stack
	if !s.set do return
	// The sections left out, and the one visiting, are as a fresh layout has them: no part
	// of the line, wherever they stand in the order.
	out_of_it := s.hidden & STACK_SECTION_PANELS
	if v, ok := s.visit.?; ok && stack_visiting(s, v) do out_of_it += {v}
	same := s.open - out_of_it == STACK_OPEN_DEFAULT && s.hidden + out_of_it == STACK_HIDDEN_DEFAULT
	i := 0
	for c in s.order {
		if c in out_of_it do continue
		for i < len(Panel_Kind) && (Panel_Kind(i) in out_of_it) do i += 1
		same &&= i < len(Panel_Kind) && c == Panel_Kind(i)
		i += 1
	}
	if same do return
	strings.write_string(out, "stack")
	for c in s.order {
		if c in out_of_it do continue
		fmt.sbprintf(out, " %s%s%s", "-" if c in s.hidden else "", panel_word(c), "+" if c in s.open else "")
	}
	strings.write_byte(out, '\n')
}

// Reads a stack line as stack_layout_save writes it; cards it does not name keep their
// places after those it does, and words that name no card are passed over.
stack_layout_read :: proc(k: ^Kit_State, f: []string) {
	s := &k.stack
	if !s.set do stack_default(k)
	order: [dynamic; len(Panel_Kind)]Panel_Kind
	open: bit_set[Panel_Kind]
	// Cards the line does not name are in or out as in a fresh layout, so a line from
	// before the look's cards leaves them out.
	hidden := STACK_HIDDEN_DEFAULT
	for word in f[1:] {
		left_out := strings.has_prefix(word, "-")
		name := strings.trim_suffix(strings.trim_prefix(word, "-"), "+")
		c, known := panel_from_word(name)
		if !known || slice_has(order[:], c) do continue
		append(&order, c)
		if strings.has_suffix(word, "+") do open += {c}
		if left_out do hidden += {c}
		else do hidden -= {c}
	}
	// Tools came after the others; a line from before it puts it after Scene, where a
	// fresh layout has it.
	if !slice_has(order[:], .Tools) && slice_has(order[:], .Scene) {
		for c, i in order do if c == .Scene {
			inject_at(&order, i + 1, Panel_Kind.Tools)
			break
		}
	}
	for c in s.order do if !slice_has(order[:], c) do append(&order, c)
	for c, i in order do s.order[i] = c
	s.open, s.hidden = open, hidden
	s.floated -= hidden
}

@(private = "file")
slice_has :: proc(list: []Panel_Kind, c: Panel_Kind) -> bool {
	for x in list do if x == c do return true
	return false
}

// The stack's card for tray section `sec`: the Brush card for the brush's sections (while
// the brush is the tool), Layers, Scene, Lights, Material and Environment for theirs, and
// the section's own palette for the rest. With `exact`, the section as the tray drew it:
// the full Layers, Objects, Lights and Material sections rather than their cards.
stack_card_of :: proc(app: ^App, sec: Kit_Section, exact := false) -> Panel_Kind {
	if section_palette(sec) == .Tool && app.tool == .Brush do return .Brush
	if !exact {
		#partial switch sec {
		case .Layers:      return .Layers
		case .Objects:     return .Scene
		case .Lights:      return .Lights
		case .Material:    return .Material
		case .Environment: return .Environment
		}
	}
	p, _ := panel_of_section(sec)
	return p
}

// Opens the card that holds section `sec` (and, on the Brush card, unfolds its group); a
// section's palette left out of the stack comes in as the visit (stack_visit). The tall
// cards, Brush and Palettes, fold for another, and the stack scrolls to its top, so the
// card opened is in sight. `exact` as stack_card_of has it (Show where).
stack_reveal :: proc(app: ^App, sec: Kit_Section, exact := false) {
	k := &app.kit
	s := &k.stack
	if !s.set do stack_default(k)
	c := stack_card_of(app, sec, exact)
	// A tab of a group left out comes in with its group instead, below.
	if panel_is_section(c) && c in s.hidden && c not_in s.joined && len(stack_group(s, c)) == 1 do stack_visit(k, c)
	s.revealed = sec
	// In a group, the group opens on the card's tab.
	host := stack_host(s, c)
	s.open -= {stack_host(s, .Brush), stack_host(s, .Palettes)} - {host}
	s.open += {host}
	for x in stack_group(s, host) do s.hidden -= {x}
	stack_show_tab(s, c)
	if c == .Brush do s.shut -= {sec}
	k.panels.scroll[.Inspector], k.scroll = 0, 0
	// Shown as icons, the card opens from its icon, so what is asked for is in sight.
	if stack_strip_shown(app) && host not_in s.floated {
		s.tab, s.tab_open, s.tab_at, s.scrolls[host] = host, true, s.strip_at[host], 0
	}
}

// The layout's density line, `stack_density icons`, only when it is not Panels.
stack_density_save :: proc(k: ^Kit_State, out: ^strings.Builder) {
	if k.stack.density == .Icons do strings.write_string(out, "stack_density icons\n")
}

// Reads a `stack_density panels|icons` line; another word leaves Panels.
stack_density_read :: proc(k: ^Kit_State, f: []string) {
	if len(f) != 2 do return
	if !k.stack.set do stack_default(k)
	if f[1] == "icons" do k.stack.density = .Icons
}

// Shows the docked stack as its cards or as the strip of their icons.
stack_density_set :: proc(app: ^App, d: Stack_Density) {
	s := &app.kit.stack
	if !s.set do stack_default(&app.kit)
	if s.density == d do return
	s.density = d
	s.tab_open = false
}

// The stack's docked cards in order, `width` wide, where the tray's panel is (kit_inspector
// calls it in Lens inside the panel's body, `owner`); the floating ones come later.
kit_stack :: proc(app: ^App, width: f32, owner: ui.Id) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.stack
	if !s.set do stack_default(k)
	stack_visit_settle(s)
	s.owner = owner
	// While a group shows two columns the stack is wider by its second column; the other
	// cards keep the stack's width against the edge it is docked on.
	base := width - stack_docked_extra(k)
	right := stack_docked_right(k)
	for c in s.order {
		if c in s.floated || c in s.hidden || c in s.joined do continue
		w := base + stack_group_extra(k, c)
		if w >= width {
			stack_card(app, c, width, false)
			continue
		}
		ui.begin(ctx, fmt.tprintf("stack row %v", c), {direction = .Row, width = width})
		if right do ui.spacer(ctx, width - w)
		stack_card(app, c, w, false)
		ui.end(ctx)
	}
}

// How much wider than its width the docked stack stands: the widest second column of an
// open docked group, or nothing (and nothing while it shows as the strip).
stack_docked_extra :: proc(k: ^Kit_State) -> f32 {
	s := &k.stack
	extra: f32 = 0
	for c in s.order {
		if c in s.floated || c in s.hidden || c in s.joined do continue
		extra = max(extra, stack_group_extra(k, c))
	}
	return extra
}

// Floating card `c`, where it was put, if it floats now: a card of its own over the view,
// which its grip's long press docks back. It is drawn in the floating order with the
// panels (new_ui.odin), so the one touched last is in front. Returns true when a press
// landed on it, to bring it to the front.
stack_float_card :: proc(app: ^App, c: Panel_Kind) -> (raised: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	if !k.inspector || side_panel_open(k) do return
	if c not_in s.floated || c in s.hidden do return
	name := fmt.tprintf("stack card %v", c)
	w := &s.windows[c]
	width := s.sizes[c].x if s.sizes[c].x > 0 else stack_width(k) + stack_group_extra(k, c)
	pressed, dock := ui.card_begin(ctx, name, "", w, .End, .Start, {kit_right(app) + stack_width(k) + 12, kit_top() + 80}, {direction = .Column, gap = 6, padding = 10, width = width, radius = t.radius_large, background = .Panel})
	stack_card(app, c, width - 20, true)
	ui.window_end(ctx)
	if dock {
		stack_dock(app, c)
		return
	}
	stack_float_handles(app, c)
	return pressed
}

// Puts floating card `c` back in the stack, where it was in the order.
stack_dock :: proc(app: ^App, c: Panel_Kind) {
	s := &app.kit.stack
	s.floated -= {c}
	s.windows[c], s.sizes[c] = {}, {}
	s.moves += 1
}

// Floats card `c` beside the stack, or at `at` when it was carried there.
stack_float :: proc(app: ^App, card: Panel_Kind, at: Maybe([2]f32) = nil) {
	k := &app.kit
	s := &k.stack
	// A tab floats its whole group.
	c := stack_host(s, card)
	s.floated += {c}
	s.open += {c}
	s.moves += 1
	float_raise(k, c)
	if p, ok := at.?; ok {
		r := s.rects[c]
		ui.window_move(&k.ctx, &s.windows[c], p - {r.w * 0.5, 12}, {r.w, r.h}, 10)
	}
}

// One card: its header, then (open) its body. `width` is its outer width (a floating
// card's inside its own padding).
@(private = "file")
stack_card :: proc(app: ^App, c: Panel_Kind, width: f32, floating: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	// The header runs nearly to the card's edges, so a folded card is little more than a
	// target tall; the body keeps the panels' padding.
	EDGE :: 2
	PAD :: 8
	name := fmt.tprintf("stack %v", c)
	if floating {
		stack_head(app, c, width, true)
	} else {
		ui.begin(ctx, name, {direction = .Column, gap = 0, padding = EDGE, width = width, radius = t.radius_large, background = .Panel})
		stack_head(app, c, width - 2 * EDGE, false)
	}
	outer := width - (0 if floating else 2 * EDGE)
	inner := outer - (0 if floating else 2 * PAD)
	_, two := stack_beside_of(s, c)
	if c in s.open && two do stack_columns_tabs(app, c, outer)
	else if c in s.open do stack_tab_row(app, c, outer)
	if c in s.open {
		pad: f32 = 0 if floating else PAD
		ui.begin(ctx, "stack body", {direction = .Column, gap = 6, padding = pad, width = outer})
		// A height set by the grip (or a floating card's size) shows that much of the content
		// and scrolls the rest.
		height := stack_float_body(app, c) if floating else s.heights[c]
		scroll: Kit_Scroll
		if height > 0 {
			owner := ui.hash_under(0, fmt.tprintf("stack card %v", c)) if floating else s.owner
			scroll = kit_scroll_begin(ctx, "stack scroll", &s.scrolls[c], owner, inner, height, 6)
		}
		if two do stack_columns_bodies(app, c, inner)
		else do panel_body(app, stack_shown(s, c), inner)
		if height > 0 do kit_scroll_end(ctx, scroll)
		ui.end(ctx)
		r := ui.last_ended(ctx)
		s.bodies[c] = {r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad}
		if !floating do stack_height_grip(app, c, outer)
	}
	if !floating {
		ui.end(ctx)
		s.rects[c] = ui.last_ended(ctx)
		s.drop_at[c] = ui.clipped(ctx, s.rects[c])
	} else {
		s.rects[c] = ui.prev_rect(ctx, fmt.tprintf("stack card %v", c))
		s.drop_at[c] = s.rects[c]
	}
	s.seen += {c}
}

// Card `c`'s content, `inner` wide: in the stack, on a floating card, or over the view from
// the strip's tab.
stack_card_body :: proc(app: ^App, c: Panel_Kind, inner: f32) {
	k := &app.kit
	k.in_tray = true
	defer k.in_tray = false
	if panel_is_section(c) {
		panel_body(app, c, inner)
		return
	}
	#partial switch c {
	case .Brush:
		if app.tool == .Brush do stack_brush(app, inner)
		else do kit_tool_tab(app)
	case .Symmetry:
		symmetry_controls(app)
	case .Layers:
		kit_lens_layers(app)
	case .Scene:
		kit_lens_scene(app)
	case .Tools:
		kit_lens_tools(app, inner)
	case .Lights:
		kit_lens_lights(app)
	case .Material:
		kit_lens_material(app)
	case .Environment:
		kit_environment(app)
	case .Palettes:
		kit_tray_select(app)
		switch k.tab {
		case .Tool:   kit_tool_tab(app)
		case .Object: kit_object_tab(app)
		case .Scene:  kit_scene_tab(app)
		}
	}
}

// A card's header: grip (docked only), chevron, icon, title and while folded what it
// holds; Symmetry's axes; Float or Dock; options.
@(private = "file")
stack_head :: proc(app: ^App, c: Panel_Kind, inner: f32, floating: bool) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	open := c in s.open
	// A group's header is its shown tab's: its icon, title and line, and Symmetry's axes.
	v := stack_shown(s, c)
	ui.begin(ctx, "stack head", {direction = .Row, width = inner, center = true})
	CHIP :: 26
	extras: f32 = 2 * t.target
	if v == .Symmetry do extras += 3 * CHIP + 4
	if !floating {
		g := ui.area(ctx, "stack grip", {18, t.target})
		ui.icon(ctx, ui.ICON_GRIP, {g.rect.x + 9, g.rect.y + g.rect.h * 0.5}, t.icon_small, t.accent if g.held else (t.text if g.hovered else t.text_tertiary))
		ui.tip(ctx, g.id, g.rect, "Drag to move it in the stack, or out to float it")
		if g.held && s.carry == nil && linalg.length(ctx.input.mouse - ctx.press_mouse) > t.slop do s.carry = Stack_Carry{card = c}
		extras += 18
	}
	head := ui.area(ctx, "stack title", {max(inner - extras, t.target), t.target})
	if head.hovered || head.held do ui.fill_rect(ctx, head.rect, t.radius_medium, t.fill_pressed if head.held else t.fill_hover)
	y := head.rect.y + head.rect.h * 0.5
	x := head.rect.x + 9
	ui.icon(ctx, ui.ICON_CHEVRON_DOWN if open else ui.ICON_CHEVRON_RIGHT, {x, y}, t.icon_small - 2, t.text_secondary)
	x += 22
	ui.icon(ctx, panel_kind_icon(app, v), {x, y}, t.icon_small, t.text_secondary)
	x += 16
	title := stack_title(app, v)
	ui.text(ctx, title, x, y, t.text_size, t.text, .Semibold)
	x += ui.text_width(ctx, title, t.text_size, .Semibold) + 10
	if line := stack_summary(app, v) if !open || v == .Palettes else stack_open_line(app, v); line != "" && head.rect.x + head.rect.w - x > 24 {
		ui.text(ctx, ui.text_fit(ctx, line, t.small_size, head.rect.x + head.rect.w - x - 6), head.rect.x + head.rect.w - 6, y, t.small_size, t.text_tertiary, align = .Right)
	}
	if head.clicked {
		s.open ~= {c}
		s.folds += 1
	}
	if ui.secondary(ctx) do stack_menu_open(app, v, head.rect)
	ui.tip(ctx, head.id, head.rect, "Fold" if open else "Unfold")
	if v == .Symmetry {
		// The axes as small chips, as the mockups' header has them: a full target tall to
		// press, a letter on a lit square while on.
		for axis in sculpt.Axis {
			a := ui.area(ctx, fmt.tprintf("%v##stack axis", axis), {CHIP, t.target})
			on := axis in app.brush.symmetry
			chip := ui.Rect{a.rect.x + 2, a.rect.y + a.rect.h * 0.5 - 11, CHIP - 4, 22}
			ui.fill_rect(ctx, chip, t.radius_small, t.accent_soft if on else (t.fill_hover if a.hovered else t.surface))
			if on do ui.stroke_rect(ctx, chip, t.radius_small, t.accent, 1)
			ui.text(ctx, fmt.tprint(axis), chip.x + chip.w * 0.5, chip.y + chip.h * 0.5, t.small_size, t.accent if on else t.text_secondary, .Semibold, .Center)
			ui.tip(ctx, a.id, a.rect, fmt.tprintf("Symmetry across %v", axis), command_hint(app, .Symmetry_X) if axis == .X else "")
			if a.clicked do app.brush.symmetry ~= {axis}
		}
		ui.spacer(ctx, 4)
	}
	if ui.icon_button(ctx, "Dock in the stack" if floating else "Float", ui.ICON_RESTORE if floating else ui.ICON_PANEL) {
		if floating do stack_dock(app, c)
		else do stack_float(app, c)
	}
	if ui.icon_button(ctx, "Panel options", ui.ICON_MORE) do stack_menu_open(app, v, ctx.last_rect)
	ui.end(ctx)
	s.head_at[c] = ui.clipped(ctx, ui.last_ended(ctx))
}

// The card's title: the tool's name on the first while the tool is not the brush, the
// palette's on Palettes.
stack_title :: proc(app: ^App, c: Panel_Kind) -> string {
	if c == .Brush do return kit_tool_name(app.tool)
	if panel_is_section(c) do return panel_kind_title(app, c)
	return STACK_CARD_NAMES[c]
}

stack_brush_icon :: proc(app: ^App) -> rune {
	return ui.ICON_BRUSH if app.tool == .Brush else TOOL_ICONS[app.tool]
}

// What a folded card holds, in a few words: the brush and its size, the axes, the
// layers, the objects and the one selected, the palette and section the tray shows.
stack_summary :: proc(app: ^App, c: Panel_Kind) -> string {
	k := &app.kit
	obj := selected_object(app)
	if sec, ok := panel_section(c); ok do return panel_summary(app, sec)
	#partial switch c {
	case .Brush:
		if app.tool != .Brush do return ""
		return fmt.tprintf("%s · %.0f px", brush_item_name(app, brush_item_current(app)), app.brush.radius_px)
	case .Symmetry:
		if app.brush.radial_on do return fmt.tprintf("radial %d", app.brush.radial_count)
		return "Local" if app.brush.sym_local else ""
	case .Layers:
		return panel_summary(app, Kit_Section.Layers)
	case .Scene:
		n := len(app.scene.objects)
		line := fmt.tprintf("%d object%s", n, "" if n == 1 else "s")
		if obj != nil do line = fmt.tprintf("%s · %s", line, object_label(obj))
		return line
	case .Tools:
		return TOOLS_TAB_NAMES[k.tools_tab]
	case .Lights:
		return panel_summary(app, Kit_Section.Lights)
	case .Material:
		return panel_summary(app, Kit_Section.Material)
	case .Environment:
		return panel_summary(app, Kit_Section.Environment)
	case .Palettes:
		if len(tray_sections(app, k.tab)) == 0 do return palette_name(k.tab)
		return fmt.tprintf("%s · %s", palette_name(k.tab), tray_section_title(tray_section(app, k.tab)))
	}
	return ""
}

// What an open card's header says, where its body does not already: how many objects
// the Scene card lists and whose layers the Layers card holds, as the mock's headers.
@(private = "file")
stack_open_line :: proc(app: ^App, c: Panel_Kind) -> string {
	// An Object palette section's says whose it is, as that palette's head did.
	if sec, ok := panel_section(c); ok && section_palette(sec) == .Object {
		obj := selected_object(app)
		if obj == nil do return ""
		return fmt.tprintf("%s · %s vertices", object_label(obj), count_label(object_vertex_count(obj)))
	}
	#partial switch c {
	case .Scene:
		n := len(app.scene.objects)
		return fmt.tprintf("%d object%s", n, "" if n == 1 else "s")
	case .Layers:
		if obj := selected_object(app); obj != nil do return object_label(obj)
	case .Tools:
		return TOOLS_TAB_NAMES[app.kit.tools_tab]
	case .Lights:
		return panel_summary(app, Kit_Section.Lights)
	case .Material:
		return panel_summary(app, Kit_Section.Material)
	}
	return ""
}

// The Brush card's body: the brush's card (its stroke, name, family and whether its
// preset has changed, Favorite), Radius and Strength, then each section of the Brush
// palette the brush has as a group that folds.
@(private = "file")
stack_brush :: proc(app: ^App, inner: f32) {
	k := &app.kit
	ctx := &k.ctx
	t := ctx.theme
	s := &k.stack
	cur := brush_item_current(app)
	key := brush_item_key(app, cur)
	ui.begin(ctx, "stack brush card", {direction = .Row, gap = 10, center = true, width = inner})
	r := ui.place(ctx, {44, 44})
	lens_stroke_preview(ctx, r, cur, app)
	text_w := inner - 44 - 10 - 8 - t.target
	ui.begin(ctx, "stack brush name", {direction = .Column, gap = 0, width = text_w})
	ui.label(ctx, ui.text_fit(ctx, brush_item_name(app, cur), t.text_size, text_w, .Semibold), font = .Semibold)
	family := brush_item_family(app, cur)
	if preset_changed(app) do family = fmt.tprintf("%s · edited", family)
	ui.label(ctx, ui.text_fit(ctx, family, t.small_size, text_w), size = t.small_size, color = t.text_tertiary)
	ui.end(ctx)
	_, favourite := brush_favorite(&k.brushes, key)
	if ui.icon_button(ctx, "Favorite (on)##stack" if favourite else "Favorite##stack", ICON_HEART, selected = favourite) do brush_favorite_toggle(&k.brushes, key)
	ui.end(ctx)
	_ = ui.slider(ctx, "Radius##stack", &app.brush.radius_px, MIN_RADIUS_PX, MAX_RADIUS_PX, .Logarithmic, fmt.tprintf("%.0f px", app.brush.radius_px))
	strength := brush_strength(app)
	_ = ui.slider(ctx, "Strength##stack", strength, MIN_STRENGTH, 1, .Linear, fmt.tprintf("%.2f", strength^))
	k.in_stack = true
	defer k.in_stack = false
	for sec in BRUSH_SECTIONS {
		if sec.shown != nil && !sec.shown(app) do continue
		open := sec.section not_in s.shut
		ui.divider(ctx, inner, across = true)
		g := ui.area(ctx, fmt.tprintf("%s##stack group", sec.title), {inner, 36})
		if g.hovered || g.held do ui.fill_rect(ctx, g.rect, t.radius_medium, t.fill_pressed if g.held else t.fill_hover)
		y := g.rect.y + g.rect.h * 0.5
		ui.icon(ctx, ui.ICON_CHEVRON_DOWN if open else ui.ICON_CHEVRON_RIGHT, {g.rect.x + 8, y}, t.icon_small - 2, t.text_secondary)
		ui.text(ctx, sec.title, g.rect.x + 22, y, t.text_size, t.text, .Semibold)
		used := 22 + ui.text_width(ctx, sec.title, t.text_size, .Semibold) + 12
		if line := stack_group_summary(app, sec.section); line != "" && g.rect.w - used > 24 {
			ui.text(ctx, ui.text_fit(ctx, line, t.small_size, g.rect.w - used - 6), g.rect.x + g.rect.w - 6, y, t.small_size, t.text_tertiary, align = .Right)
		}
		ui.tip(ctx, g.id, g.rect, "Fold" if open else "Unfold")
		if g.clicked {
			s.shut ~= {sec.section}
			s.folds += 1
		}
		if open do sec.draw(app)
	}
}

// How a Brush card group is set, for its header: the stroke and lazy mouse, the falloff,
// the alpha, what the pen drives, the surface switches that are on, the preset.
stack_group_summary :: proc(app: ^App, sec: Kit_Section) -> string {
	b := &app.brush
	#partial switch sec {
	case .Preset:
		p, on := brush_preset(app)
		if !on do return "none"
		return fmt.tprintf("%s%s", preset_name(p), " · changed" if preset_changed(app) else "")
	case .Stroke:
		line := STROKE_MODE_NAMES[b.stroke]
		if b.lazy_px >= 0.5 do line = fmt.tprintf("%s · lazy %.0f px", line, b.lazy_px)
		if n := steady_count(b.smoothing); n > 1 do line = fmt.tprintf("%s · smoothing %d", line, n)
		return line
	case .Paint_Color:
		return hex_text(b.color)
	case .Falloff:
		f := b.falloffs[b.kind]
		line := "Drawn curve" if f.drawn else "The brush's own"
		if f.focal != 0 do line = fmt.tprintf("%s · focal %.0f", line, f.focal)
		if f.hardness != 0 do line = fmt.tprintf("%s · hard %.0f%%", line, f.hardness * 100)
		if f.projected do line = fmt.tprintf("%s · projected", line)
		return line
	case .Samples:
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		if b.stabilize > 0 do append(&parts, fmt.tprintf("steady %.0f%%", b.stabilize * 100))
		if b.sample_radius > 0 && b.sample_radius < 1 do append(&parts, fmt.tprintf("sample %.0f%%", b.sample_radius * 100))
		if accumulate_applies(b.kind) do append(&parts, "builds up" if !b.no_accumulate[b.kind] else "one pass")
		if len(parts) == 0 do return "as it comes"
		return strings.join(parts[:], " · ", context.temp_allocator)
	case .Alpha:
		if b.alpha < 0 || b.alpha >= len(app.alphas) do return "Round"
		return app.alphas[b.alpha].name
	case .Pen:
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		p := brush_pressure(b, b.kind)
		if p.size do append(&parts, "size")
		if p.strength do append(&parts, "strength")
		own := " (own)" if b.pressures[b.kind].own else ""
		if len(parts) == 0 do return fmt.tprintf("pressure off%s", own)
		return fmt.tprintf("pressure → %s%s", strings.join(parts[:], ", ", context.temp_allocator), own)
	case .Options:
		parts := make([dynamic]string, 0, 3, context.temp_allocator)
		if b.front_only do append(&parts, "front faces")
		if b.lock_plane do append(&parts, "lock plane")
		if b.connected do append(&parts, "connected")
		if len(parts) == 0 do return "every face"
		return strings.join(parts[:], " · ", context.temp_allocator)
	}
	return ""
}

// Moves card `c` to slot `at` of the docked cards (the order keeps the floating ones where
// they were).
stack_move_to :: proc(app: ^App, c: Panel_Kind, at: int) {
	stack_move_to_k(&app.kit, c, at)
}

stack_move_to_k :: proc(k: ^Kit_State, card: Panel_Kind, at: int) {
	s := &k.stack
	// The order is a list of runs, each a group (a card on its own is a group of one), so
	// a group moves as one. Floating and hidden groups keep their places in the order; the
	// docked ones move.
	c := stack_host(s, card)
	runs := make([dynamic][]Panel_Kind, 0, len(Panel_Kind), context.temp_allocator)
	for x in s.order do if x not_in s.joined do append(&runs, stack_group(s, x))
	docked := make([dynamic][]Panel_Kind, 0, len(Panel_Kind), context.temp_allocator)
	for r in runs do if r[0] != c && r[0] not_in s.floated && r[0] not_in s.hidden do append(&docked, r)
	inject_at_elem(&docked, clamp(at, 0, len(docked)), stack_group(s, c))
	order: [dynamic; len(Panel_Kind)]Panel_Kind
	i := 0
	for r in runs {
		if r[0] != c && (r[0] in s.floated || r[0] in s.hidden) {
			append(&order, ..r)
			continue
		}
		append(&order, ..docked[i])
		i += 1
	}
	for x, j in order do s.order[j] = x
	s.moves += 1
}

// Opens card `c`'s options beside `at`.
stack_menu_open :: proc(app: ^App, c: Panel_Kind, at: ui.Rect) {
	k := &app.kit
	kit_floats_close(k)
	k.stack.menu, k.stack.menu_of, k.stack.menu_at = true, c, at
}

// A card's options: move it up or down the stack, float or dock it, fold the others,
// and where the stack itself goes (the tray's panel options).
kit_stack_menu :: proc(app: ^App) {
	k := &app.kit
	ctx := &k.ctx
	s := &k.stack
	if !ui.popover_begin(ctx, "stack menu", &s.menu, s.menu_at, .Below, {direction = .Column, padding = 6, width = 240}) do return
	defer ui.popover_end(ctx)
	// The menu is the shown tab's; what it does as a card of the stack, its group does.
	tab := s.menu_of
	c := stack_host(s, tab)
	group := stack_group(s, c)
	place := 0
	for x in s.order {
		if x == c do break
		if x not_in s.floated && x not_in s.hidden && x not_in s.joined do place += 1
	}
	count := 0
	for x in s.order do if x not_in s.floated && x not_in s.hidden && x not_in s.joined do count += 1
	floated := c in s.floated
	if ui.menu_item(ctx, "Move up", glyph = ui.ICON_CHEVRON_UP, enabled = !floated && place > 0) {
		stack_move_to(app, c, place - 1)
		s.menu = false
	}
	if ui.menu_item(ctx, "Move down", glyph = ui.ICON_CHEVRON_DOWN, enabled = !floated && place < count - 1) {
		stack_move_to(app, c, place + 1)
		s.menu = false
	}
	if ui.menu_item(ctx, "Dock in the stack" if floated else "Float", glyph = ui.ICON_PANEL) {
		if floated do stack_dock(app, c)
		else do stack_float(app, c)
		s.menu = false
	}
	// The visit stays only until another section is opened, unless it is pinned.
	if stack_visiting(s, tab) && ui.menu_item(ctx, "Pin to the stack", glyph = ui.ICON_PANEL) {
		stack_keep(k, tab, true)
		s.menu = false
	}
	if ui.menu_item(ctx, "Leave out of the stack", glyph = ui.ICON_EYE_OFF, enabled = count > 1 || floated) {
		for x in group do s.hidden += {x}
		s.floated -= {c}
		s.moves += 1
		s.menu = false
	}
	// Groups: the card (with its group's tabs) joins the docked card above as its tabs;
	// a tab comes out as a card of its own.
	_, can_join := stack_join_target(s, c)
	if ui.menu_item(ctx, "Join the card above", glyph = ICON_MERGE, enabled = can_join) {
		stack_join(k, c)
		s.menu = false
	}
	if len(group) > 1 && ui.menu_item(ctx, "Take out of the group", glyph = ICON_SPLIT) {
		stack_take_out(k, tab)
		s.menu = false
	}
	if len(group) > 1 && ui.menu_item(ctx, "Ungroup", glyph = ICON_SPLIT) {
		stack_ungroup(k, c)
		s.menu = false
	}
	// The look's cards hold the settings used most; the rest are their tray sections'.
	if tab == .Lights || tab == .Material {
		sec := Kit_Section.Lights if tab == .Lights else Kit_Section.Material
		if ui.menu_item(ctx, "All light settings" if tab == .Lights else "All material settings", glyph = ui.ICON_SETTINGS) {
			tray_open(app, sec, exact = true)
			s.menu = false
		}
	}
	icons := s.density == .Icons
	if ui.menu_item(ctx, "Show as panels" if icons else "Show as icons", glyph = ui.ICON_PANEL if icons else ui.ICON_GRID) {
		stack_density_set(app, .Panels if icons else .Icons)
		s.menu = false
	}
	if ui.menu_item(ctx, "Fold the others") {
		s.open = {c}
		s.folds += 1
		s.menu = false
	}
	if ui.menu_item(ctx, "Where the stack goes...", glyph = ui.ICON_MOVE) {
		s.menu = false
		panel_menu_open(app, Kit_Window.Inspector, s.menu_at)
	}
}

// The stack for the exit stats: its cards in order, + on the open ones, ^ on floating ones,
// & before a group's tab and | before the one beginning its second column; the cards left
// out are not named.
stack_text :: proc(k: ^Kit_State) -> string {
	s := &k.stack
	b := strings.builder_make(context.temp_allocator)
	for c in s.order {
		if c in s.hidden do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		mark := "|" if c in s.beside else ("&" if c in s.joined else "")
		fmt.sbprintf(&b, "%s%v%s%s", mark, c, "+" if c in s.open else "", "^" if c in s.floated else "")
	}
	return strings.to_string(b)
}

// The Brush card's folded groups for the exit stats, by section, or none.
stack_shut_text :: proc(k: ^Kit_State) -> string {
	b := strings.builder_make(context.temp_allocator)
	for sec in Kit_Section {
		if sec not_in k.stack.shut do continue
		if strings.builder_len(b) > 0 do strings.write_byte(&b, ',')
		fmt.sbprint(&b, sec)
	}
	return strings.to_string(b) if strings.builder_len(b) > 0 else "none"
}

// Brings section palette `p` into the stack as the visit: open, at the docked stack's
// foot (before Palettes while it is docked there), the visit before it left out again
// unless it has since been kept. The visit is no part of the layout (stack_layout_save), so
// opening sections never marks the workspace changed.
stack_visit :: proc(k: ^Kit_State, p: Panel_Kind) {
	s := &k.stack
	if !s.set do stack_default(k)
	if v, ok := s.visit.?; ok && v != p && stack_visiting(s, v) {
		s.hidden += {v}
		s.open -= {v}
	}
	s.hidden -= {p}
	s.floated -= {p}
	s.open += {p}
	// Into the order just before Palettes's group while it is docked, else just after the
	// last docked group, so no other card moves and the order of the layout's cards stays
	// as it was.
	order: [dynamic; len(Panel_Kind)]Panel_Kind
	for x in s.order do if x != p do append(&order, x)
	palettes := stack_host(s, .Palettes)
	docked :: proc(s: ^Lens_Stack, x: Panel_Kind) -> bool {return x not_in s.floated && x not_in s.hidden}
	at := -1
	for x, i in order do if x == palettes && docked(s, x) do at = i
	if at < 0 {
		at = 0
		for x, i in order do if docked(s, stack_host(s, x)) do at = i + 1
	}
	inject_at(&order, at, p)
	for x, i in order do s.order[i] = x
	s.visit = p
	s.visits += 1
}

// Whether `p` is the visit and still as it came in: docked on its own, its height and
// column the usual. Carried into a group, floated or resized, it is kept (stack_visit_settle).
stack_visiting :: proc(s: ^Lens_Stack, p: Panel_Kind) -> bool {
	v, ok := s.visit.?
	if !ok || v != p || p in s.hidden || p in s.floated || p in s.joined || s.heights[p] > 0 do return false
	return len(stack_group(s, p)) == 1
}

// Lets go of the visit once it is no longer as it came in, so it stays kept even after it
// is taken out of a group again; kit_stack calls it each frame.
stack_visit_settle :: proc(s: ^Lens_Stack) {
	if v, ok := s.visit.?; ok && !stack_visiting(s, v) do s.visit = nil
}

// Keeps section palette `p` in the stack for good (Pin to the stack), or leaves it out.
stack_keep :: proc(k: ^Kit_State, p: Panel_Kind, on: bool) {
	s := &k.stack
	if !s.set do stack_default(k)
	if v, ok := s.visit.?; ok && v == p do s.visit = nil
	if on {
		if p in s.hidden && p not_in s.joined && len(stack_group(s, p)) == 1 do stack_visit(k, p)
		for x in stack_group(s, stack_host(s, p)) do s.hidden -= {x}
		s.visit = nil
		return
	}
	// A tab comes out of its group first, so its group stays as it was.
	if len(stack_group(s, stack_host(s, p))) > 1 do stack_take_out(k, p, open = false)
	s.hidden += {p}
	s.open -= {p}
	s.floated -= {p}
}

// Whether palette `p` is on screen: the tab shown of an open docked group (or the strip's
// tab opened on it), or of a floating one.
palette_on_screen :: proc(app: ^App, p: Panel_Kind) -> bool {
	k := &app.kit
	s := &k.stack
	if !s.set || !k.inspector || side_panel_open(k) || p in s.hidden do return false
	host := stack_host(s, p)
	if stack_shown(s, host) != p {
		b, two := stack_beside_of(s, host)
		if !two || stack_shown(s, b) != p do return false
	}
	if host in s.floated do return true
	if stack_strip_shown(app) do return s.tab_open && s.tab == host
	return host in s.open
}

// The visit for the exit stats: its kind, or none.
stack_visit_text :: proc(k: ^Kit_State) -> string {
	if v, ok := k.stack.visit.?; ok && stack_visiting(&k.stack, v) do return fmt.tprint(v)
	return "none"
}
