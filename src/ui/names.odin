package ui

import "core:fmt"
import "core:strings"

// The control map: while it is on (the app turns it on for scripted input that names
// controls, and for --ui-map), every widget that answers the pointer is recorded with its
// path, the shown labels of the containers it sits in and its own ("Rebuild/Quad Remesh"),
// and the part of it that shows. A scripted tap can then name a control instead of giving
// a position, which moves whenever the layout does. Names resolve against the last frame
// finished, as a real press lands on what the last frame drew. Off, it costs one test per
// widget.

// How many containers up a path names, past which outer ones are left out.
NAME_DEPTH :: 8
// The least of a control, in points across and down, that must show for it to be named.
NAME_SLIVER :: 8

// A label met this frame (id_of): its id, the container it was made in, and its text in
// Names.text.
@(private)
Name_Seen :: struct {
	id:     Id,
	parent: Id,
	at:     i32,
	len:    i32,
}

// A control placed this frame: its path in Names.paths, and where it shows in points.
@(private)
Named :: struct {
	id:   Id,
	at:   i32,
	len:  i32,
	rect: Rect,
}

Names :: struct {
	on:         bool,
	seen:       [dynamic]Name_Seen,
	text:       [dynamic]u8,
	list:       [dynamic]Named,
	paths:      [dynamic]u8,
	prev_list:  [dynamic]Named,
	prev_paths: [dynamic]u8,
}

// Turns the control map on or off.
names_show :: proc(ctx: ^Context, on: bool) {
	ctx.names.on = on
}

@(private)
names_destroy :: proc(n: ^Names) {
	delete(n.seen)
	delete(n.text)
	delete(n.list)
	delete(n.paths)
	delete(n.prev_list)
	delete(n.prev_paths)
}

// Keeps the frame just finished as the one names resolve against, and starts a new one.
@(private)
names_frame :: proc(ctx: ^Context) {
	n := &ctx.names
	if !n.on do return
	n.list, n.prev_list = n.prev_list, n.list
	n.paths, n.prev_paths = n.prev_paths, n.paths
	clear(&n.list)
	clear(&n.paths)
	clear(&n.seen)
	clear(&n.text)
}

// Remembers that `label` was made into `id` inside the container `parent` (id_of).
@(private)
names_seen :: proc(ctx: ^Context, id, parent: Id, label: string) {
	n := &ctx.names
	append(&n.seen, Name_Seen{id = id, parent = parent, at = i32(len(n.text)), len = i32(len(label))})
	append(&n.text, label)
}

@(private)
names_seen_find :: proc(n: ^Names, id: Id) -> (Name_Seen, bool) {
	#reverse for s in n.seen do if s.id == id do return s, true
	return {}, false
}

// Records the control `id` at `r` (interact), by the part the clip shows; a control
// hidden, scrolled out of its panel, is left out, as a press could not reach it, and so is
// one showing a sliver thinner than NAME_SLIVER, which a finger would not aim at.
@(private)
names_place :: proc(ctx: ^Context, id: Id, r: Rect) {
	n := &ctx.names
	#reverse for c in n.list do if c.id == id do return
	s, ok := names_seen_find(n, id)
	if !ok || s.len == 0 do return
	d := px(ctx)
	shown := rect_intersect(r, {ctx.clip.x / d, ctx.clip.y / d, ctx.clip.w / d, ctx.clip.h / d})
	if shown.w < min(r.w, NAME_SLIVER) || shown.h < min(r.h, NAME_SLIVER) || shown.w <= 0 || shown.h <= 0 do return
	// The labels from the outermost container in, then the control's own.
	chain: [NAME_DEPTH]Name_Seen
	depth := 0
	chain[0] = s
	depth = 1
	for parent := s.parent; parent != 0 && depth < NAME_DEPTH; {
		p, found := names_seen_find(n, parent)
		if !found do break
		chain[depth] = p
		depth += 1
		parent = p.parent
	}
	at := i32(len(n.paths))
	for k := depth - 1; k >= 0; k -= 1 {
		c := chain[k]
		if c.len == 0 do continue
		if i32(len(n.paths)) > at do append(&n.paths, "/")
		append(&n.paths, string(n.text[c.at:][:c.len]))
	}
	append(&n.list, Named{id = id, at = at, len = i32(len(n.paths)) - at, rect = shown})
}

// Where the control `name` showed in the last frame finished, and how many matched: the
// first in layout order is taken. `name` is the control's shown label or the key after
// its "##" ("undo" for "Undo stroke##undo", whose shown part changes), matched without
// regard to case, and may begin with the labels of containers it sits in, each followed
// by "/" ("Rebuild/Quads" is the Quads inside Rebuild, at any depth).
named_find :: proc(ctx: ^Context, name: string) -> (r: Rect, count: int) {
	n := &ctx.names
	want := strings.split(name, "/", context.temp_allocator)
	for c in n.prev_list {
		path := string(n.prev_paths[c.at:][:c.len])
		if names_match(path, want) {
			if count == 0 do r = c.rect
			count += 1
		}
	}
	return
}

// Whether a control's `path` ends in the last of `want` and holds the others before it, in order.
@(private)
names_match :: proc(path: string, want: []string) -> bool {
	parts := strings.split(path, "/", context.temp_allocator)
	if len(parts) == 0 || len(want) == 0 do return false
	if !names_part_is(parts[len(parts) - 1], want[len(want) - 1]) do return false
	k := 0
	for p in parts[:len(parts) - 1] {
		if k < len(want) - 1 && names_part_is(p, want[k]) do k += 1
	}
	return k == len(want) - 1
}

// Whether a label (with its "##" key, if any) is the one `want` names: by its shown part
// or by its key.
@(private)
names_part_is :: proc(label, want: string) -> bool {
	name := strings.trim_space(want)
	shown, _, key := strings.partition(label, "##")
	return strings.equal_fold(shown, name) || (key != "" && strings.equal_fold(key, name))
}

// Writes the last frame's control map, a line a control: its path (each label with its
// "##" key, if any), a tab, then its rectangle's x, y, width and height in points.
names_write :: proc(ctx: ^Context, b: ^strings.Builder) {
	n := &ctx.names
	for c in n.prev_list {
		r := c.rect
		strings.write_string(b, string(n.prev_paths[c.at:][:c.len]))
		fmt.sbprintf(b, "\t%.1f %.1f %.1f %.1f\n", r.x, r.y, r.w, r.h)
	}
}
