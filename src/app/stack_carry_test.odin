package main

import "core:strings"
import "core:testing"

// The stack's rules, after any operation: the order holds every card once, the first is
// no tab, every host shows one of its own tabs, a tab keeps no state as a card (open,
// floating, window, height, size), and a tab is in or out of the stack as its host is.
@(private = "file")
stack_valid :: proc(s: ^Lens_Stack) -> bool {
	seen: bit_set[Panel_Kind]
	for c in s.order {
		if c in seen do return false
		seen += {c}
	}
	all := ~bit_set[Panel_Kind]{}
	if seen != all || s.order[0] in s.joined do return false
	for c in Panel_Kind {
		if c in s.joined {
			if c in s.open || c in s.floated || s.windows[c] != {} || s.heights[c] != 0 || s.sizes[c] != {} do return false
			if (c in s.hidden) != (stack_host(s, c) in s.hidden) do return false
		} else if stack_host(s, stack_shown(s, c)) != c {
			return false
		}
	}
	// A second column begins at a tab, and a group has at most one.
	if s.beside & ~s.joined != {} do return false
	for c in s.order {
		if c in s.joined do continue
		n := 0
		for x in stack_group(s, c) do if x in s.beside do n += 1
		if n > 1 do return false
	}
	return true
}

// Joining at a slot: a tab goes between the tabs it was dropped between, never before
// the host (slot 0 is slot 1); a group's whole run joins; nothing joins its own group or a
// tab; Ungroup gives every tab back as a card where it stood.
@(test)
stack_join_at_a_slot_and_ungroup :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	s := &k.stack
	testing.expect(t, stack_join(k, .Symmetry))
	testing.expect(t, stack_join_at(k, .Scene, false, .Brush, 0))
	testing.expect_value(t, stack_text(k), "Brush+,&Scene,&Symmetry,Layers,Tools,Palettes")
	testing.expect(t, stack_valid(s))
	// A tab of one group into another: Symmetry out of Brush's, into Layers' after the host.
	testing.expect(t, stack_join_at(k, .Symmetry, true, .Layers, 1))
	testing.expect_value(t, stack_text(k), "Brush+,&Scene,Layers+,&Symmetry,Tools,Palettes")
	testing.expect(t, stack_valid(s))
	testing.expect(t, !stack_join_at(k, .Scene, true, .Brush, 1))
	testing.expect(t, !stack_join_at(k, .Brush, false, .Symmetry, 1))
	// A whole group into another, between its tabs.
	testing.expect(t, stack_join_at(k, .Layers, false, .Brush, 1))
	testing.expect_value(t, stack_text(k), "Brush+,&Layers,&Symmetry,&Scene,Tools,Palettes")
	testing.expect_value(t, stack_shown(s, .Brush), Panel_Kind.Layers)
	testing.expect(t, stack_valid(s))
	testing.expect(t, stack_ungroup(k, .Brush))
	testing.expect_value(t, stack_text(k), "Brush+,Layers,Symmetry,Scene,Tools,Palettes")
	testing.expect(t, stack_valid(s))
	testing.expect(t, !stack_ungroup(k, .Brush))
	free_all(context.temp_allocator)
}

// Carrying the host's tab alone out of its group hands the group to the next tab, which
// keeps the group's place, fold and the strip's open card.
@(test)
stack_carried_host_tab_hands_the_group_over :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	s := &k.stack
	stack_join(k, .Symmetry)
	s.tab, s.tab_open = .Brush, true
	testing.expect(t, stack_join_at(k, .Brush, true, .Layers, 1))
	testing.expect_value(t, stack_text(k), "Symmetry+,Layers+,&Brush,Scene,Tools,Palettes")
	testing.expect_value(t, s.tab, Panel_Kind.Symmetry)
	testing.expect(t, stack_valid(s))
	free_all(context.temp_allocator)
}

// The target under a carry, from the rects laid out: a header's middle joins and its top
// band is the line, a tab row joins between its tabs, a floating group in front takes the
// drop over the docked cards, the carried group's own place changes nothing, and well
// clear of the stack it floats.
@(test)
stack_carry_targets_from_the_rects :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	stack_default(k)
	s := &k.stack
	stack_join(k, .Symmetry)
	// Brush's group open at the top (header 44 tall, tabs 40 under it), the rest folded.
	y: f32 = 80
	for c in s.order {
		if c in s.hidden || c in s.joined do continue
		h: f32 = 300 if c == .Brush else 48
		s.drop_at[c], s.head_at[c] = {1060, y, 312, h}, {1062, y + 2, 308, 44}
		s.seen += {c}
		y += h + 8
	}
	s.row_at[.Brush] = {1062, 126, 308, 44}
	s.tabs_at[.Brush], s.tabs_at[.Symmetry] = {1068, 126, 148, 44}, {1216, 126, 148, 44}
	layers := Stack_Carry{card = .Layers}
	testing.expect_value(t, stack_carry_target(app, {1200, 104}, layers), Stack_Target{kind = .Join, host = .Brush, slot = 2})
	testing.expect_value(t, stack_carry_target(app, {1100, 148}, layers), Stack_Target{kind = .Join, host = .Brush, slot = 1})
	testing.expect_value(t, stack_carry_target(app, {1200, 84}, layers), Stack_Target{kind = .Line, at = 0})
	// Layers' own header and place: nothing.
	testing.expect_value(t, stack_carry_target(app, {1200, 412}, layers), Stack_Target{})
	// Scene's header middle joins Scene.
	testing.expect_value(t, stack_carry_target(app, {1200, 412 + 56}, layers), Stack_Target{kind = .Join, host = .Scene, slot = 1})
	testing.expect_value(t, stack_carry_target(app, {400, 400}, layers), Stack_Target{kind = .Float})
	// The Symmetry tab over its own group: nothing; below Tools' band: the line.
	tab := Stack_Carry{card = .Symmetry, tab = true}
	testing.expect_value(t, stack_carry_target(app, {1200, 148}, tab), Stack_Target{})
	// A floating Tools card over Brush's body takes the drop.
	s.floated += {.Tools}
	float_raise(k, Panel_Kind.Tools)
	s.drop_at[.Tools] = {1100, 200, 300, 200}
	testing.expect_value(t, stack_carry_target(app, {1200, 300}, layers), Stack_Target{kind = .Join, host = .Tools, slot = 1})
	free_all(context.temp_allocator)
}

// In the strip of icons: let go over another icon at once, the strip reorders there;
// rested on it for twice the long press, the carry joins its group; its own place changes
// nothing; well away from the strip it floats.
@(test)
stack_strip_targets_reorder_then_join :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	stack_default(k)
	s := &k.stack
	k.ctx.theme.long_press = 0.25
	y: f32 = 73
	for c in s.order {
		if c in s.hidden do continue
		s.strip_at[c] = {1326, y, 44, 44}
		s.strip_seen += {c}
		y += 50
	}
	layers := Stack_Carry{card = .Layers}
	testing.expect_value(t, stack_carry_target(app, {1348, 95}, layers), Stack_Target{kind = .Line, at = 0, strip = true})
	testing.expect_value(t, stack_carry_target(app, {1348, 195}, layers), Stack_Target{})
	s.dwell, s.dwell_on, s.dwell_from = .Brush, true, -1
	testing.expect_value(t, stack_carry_target(app, {1348, 95}, layers), Stack_Target{kind = .Join, host = .Brush, slot = 1})
	s.dwell_from = k.ctx.time - 0.3
	testing.expect_value(t, stack_carry_target(app, {1348, 95}, layers).kind, Stack_Target_Kind.Line)
	testing.expect_value(t, stack_carry_target(app, {400, 400}, layers), Stack_Target{kind = .Float})
	free_all(context.temp_allocator)
}

// Beside: a card dropped beside a group is its second column, with its own shown tab, and
// widens the group's card; more dropped beside join that column; taking its first card out
// hands the column to the next, and the last out leaves one column.
@(test)
stack_beside_makes_a_second_column :: proc(t: ^testing.T) {
	k := new(Kit_State)
	defer free(k)
	stack_default(k)
	s := &k.stack
	testing.expect(t, stack_beside_join(k, .Symmetry, false, .Brush, true))
	testing.expect_value(t, stack_text(k), "Brush+,|Symmetry,Layers,Scene,Tools,Palettes")
	testing.expect_value(t, stack_shown(s, .Brush), Panel_Kind.Brush)
	testing.expect_value(t, stack_group_extra(k, .Brush), STACK_W + STACK_DIVIDER)
	testing.expect(t, stack_valid(s))
	testing.expect(t, stack_beside_join(k, .Layers, false, .Brush, true))
	testing.expect_value(t, stack_text(k), "Brush+,|Symmetry,&Layers,Scene,Tools,Palettes")
	testing.expect_value(t, stack_shown(s, .Symmetry), Panel_Kind.Layers)
	testing.expect_value(t, stack_column_head(s, .Layers), Panel_Kind.Symmetry)
	testing.expect(t, stack_valid(s))
	testing.expect(t, stack_take_out(k, .Symmetry))
	testing.expect_value(t, stack_text(k), "Brush+,|Layers,Symmetry+,Scene,Tools,Palettes")
	testing.expect(t, stack_valid(s))
	testing.expect(t, stack_take_out(k, .Layers))
	testing.expect_value(t, stack_text(k), "Brush+,Layers+,Symmetry+,Scene,Tools,Palettes")
	testing.expect_value(t, stack_group_extra(k, .Brush), 0)
	// The host out of a group whose first column is only the host: column two is the group.
	stack_beside_join(k, .Layers, false, .Brush, true)
	testing.expect(t, stack_take_out(k, .Brush))
	testing.expect_value(t, stack_text(k), "Layers+,Brush+,Symmetry+,Scene,Tools,Palettes")
	testing.expect(t, stack_valid(s))
	free_all(context.temp_allocator)
}

// The columns are part of the layout: `|` before column two in the group's line, a `*` on
// each column's shown tab, and the second column's width; they read back as written.
@(test)
stack_columns_read_back :: proc(t: ^testing.T) {
	a: Kit_State
	stack_default(&a)
	stack_join(&a, .Symmetry)
	stack_beside_join(&a, .Layers, false, .Brush, true)
	stack_beside_join(&a, .Scene, false, .Brush, true)
	stack_show_tab(&a.stack, .Symmetry)
	a.stack.beside_w[.Brush] = 280
	text := kit_layout_text(&a)
	testing.expect(t, strings.contains(text, "stack_group card:Brush *card:Symmetry | card:Layers *card:Scene\n"), text)
	testing.expect(t, strings.contains(text, "stack_beside Brush=280\n"), text)
	b: Kit_State
	kit_layout_put(&b, text)
	testing.expect_value(t, stack_text(&b), "Brush+,&Symmetry,|Layers,&Scene,Tools,Palettes")
	testing.expect_value(t, stack_shown(&b.stack, .Brush), Panel_Kind.Symmetry)
	testing.expect_value(t, stack_shown(&b.stack, .Layers), Panel_Kind.Scene)
	testing.expect_value(t, stack_beside_width(&b, .Brush), 280)
	testing.expect(t, stack_valid(&b.stack))
	free_all(context.temp_allocator)
}

// Just beyond a docked group's view side the carry goes beside it, where the window has
// room; in a narrow window it goes below instead.
@(test)
stack_beside_target_needs_room :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	k := &app.kit
	stack_default(k)
	s := &k.stack
	k.ctx.input.window = {1440, 900}
	y: f32 = 80
	for c in s.order {
		if c in s.hidden do continue
		s.drop_at[c], s.head_at[c] = {1060, y, 312, 48}, {1062, y + 2, 308, 44}
		s.seen += {c}
		y += 56
	}
	scene := Stack_Carry{card = .Scene}
	testing.expect_value(t, stack_carry_target(app, {1000, 100}, scene), Stack_Target{kind = .Beside, host = .Brush, left = true})
	k.ctx.input.window = {800, 900}
	for c in Panel_Kind do s.drop_at[c].x -= 640
	testing.expect_value(t, stack_carry_target(app, {360, 100}, scene), Stack_Target{kind = .Line, at = 1, no_room = true})
	free_all(context.temp_allocator)
}
