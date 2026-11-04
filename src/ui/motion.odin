package ui

import "core:math"

// Motion in the manner of Anime.js: a value moves to a target over a duration along an
// easing curve, after an optional delay, and a new target starts from wherever the value
// is now, so nothing ever jumps. Tweens are keyed by Id and live in one table that is
// allocated once and reused; a widget asks for its value each frame and gets it eased.

Ease :: enum u8 {
	Linear,
	Out_Quad, // Anime.js's default: quick to start, settling gently
	Out_Cubic,
	Out_Quart,
	In_Out_Cubic,
	Out_Back, // a small overshoot, for switch knobs only
}

// `t` (0 to 1) along the curve.
ease :: proc(e: Ease, at: f32) -> f32 {
	t := clamp(at, 0, 1)
	switch e {
	case .Linear:
		return t
	case .Out_Quad:
		return 1 - (1 - t) * (1 - t)
	case .Out_Cubic:
		u := 1 - t
		return 1 - u * u * u
	case .Out_Quart:
		u := 1 - t
		return 1 - u * u * u * u
	case .In_Out_Cubic:
		if t < 0.5 do return 4 * t * t * t
		u := -2 * t + 2
		return 1 - u * u * u * 0.5
	case .Out_Back:
		// Overshoot 1.2: about 3% past the end, which reads as weight rather than bounce.
		C1 :: f32(1.2)
		C3 :: C1 + 1
		u := t - 1
		return 1 + C3 * u * u * u + C1 * u * u
	}
	return t
}

// How much the interface moves: Full; Reduced, where fades keep their time and moves and
// scales go (transform_since leaves them out), as the systems' reduced-motion settings
// ask; or Off, where every duration is 0.
Motion_Level :: enum u8 {
	Full,
	Reduced,
	Off,
}

// A kind of motion that can be turned off by itself: the kit's own widgets use the first
// numbers, and an app numbers its own kinds after them (up to 31). MOTION_ALWAYS follows
// the level only.
Motion_Class :: distinct u8
MOTION_PRESS :: Motion_Class(0) // presses, hovers and switch knobs
MOTION_POPOVERS :: Motion_Class(1) // popovers, menus and lists opening
MOTION_PANELS :: Motion_Class(2) // sections opening, windows sliding
MOTION_TABS :: Motion_Class(3) // the indicator under a tab or a choice sliding
MOTION_TOASTS :: Motion_Class(4) // notes rising and stacking
MOTION_TOOLTIPS :: Motion_Class(5) // tooltips fading in
MOTION_ALWAYS :: Motion_Class(255)

// `duration` as the motion settings let it run for `class`: 0 when motion is off, or that
// kind of motion is.
motion_duration :: proc(ctx: ^Context, class: Motion_Class, duration: f32) -> f32 {
	if ctx.motion == .Off do return 0
	if class < 32 && int(class) in ctx.motion_off do return 0
	return duration
}

// Whether `class` may move or scale things now, not only fade them: an app's own slides
// (a page turning) ask this before they move.
motion_moves :: proc(ctx: ^Context, class: Motion_Class = MOTION_ALWAYS) -> bool {
	return ctx.motion == .Full && motion_duration(ctx, class, 1) > 0
}

@(private)
Tween :: struct {
	from, to: f32,
	start:    f64, // Context.time when it set off toward `to`
	duration: f32,
	delay:    f32,
	ease:     Ease,
	seen:     f64, // the last time it was asked for, to drop tweens no widget uses
}

// Tweens unused this long are dropped from the table.
@(private)
TWEEN_KEEP :: 2.0

// The value moving toward `target`; the first time `id` is seen it starts at `target`.
tween :: proc(ctx: ^Context, id: Id, target: f32, duration: f32, e := Ease.Out_Quad, delay: f32 = 0, class := MOTION_ALWAYS) -> f32 {
	return tween_from(ctx, id, target, target, duration, e, delay, class)
}

// As tween, but the first time `id` is seen it starts at `start`: for things that
// animate in when they first appear.
tween_from :: proc(ctx: ^Context, id: Id, start, target: f32, duration: f32, e := Ease.Out_Quad, delay: f32 = 0, class := MOTION_ALWAYS) -> f32 {
	run := motion_duration(ctx, class, duration)
	wait := delay if run > 0 else 0
	tw, found := &ctx.tweens[id]
	if !found {
		ctx.tweens[id] = {from = start, to = target, start = ctx.time, duration = run, delay = wait, ease = e, seen = ctx.time}
		tw = &ctx.tweens[id]
	}
	tw.seen = ctx.time
	if tw.to != target {
		tw.from = tween_value(ctx, tw^)
		tw.to = target
		tw.start = ctx.time
		tw.duration = run
		tw.delay = wait
		tw.ease = e
	}
	return tween_value(ctx, tw^)
}

// The share (0 to 1) something that opens and closes is shown: rising while `open`,
// falling after. It starts closed, so the first frame open animates in. Draw it while
// this is above 0.
presence :: proc(ctx: ^Context, id: Id, open: bool, duration: f32, class := MOTION_ALWAYS) -> f32 {
	return tween_from(ctx, id, 0, 1 if open else 0, duration, .Out_Cubic, class = class)
}

// True while some tween has not arrived: the app can keep drawing frames until then.
animating :: proc(ctx: ^Context) -> bool {
	for _, tw in ctx.tweens {
		if tw.seen >= ctx.time && tween_done(ctx, tw) == false do return true
	}
	return false
}

@(private)
tween_value :: proc(ctx: ^Context, tw: Tween) -> f32 {
	if tw.duration <= 0 do return tw.to
	t := f32(ctx.time - tw.start) - tw.delay
	if t <= 0 do return tw.from
	if t >= tw.duration do return tw.to
	return math.lerp(tw.from, tw.to, ease(tw.ease, t / tw.duration))
}

@(private)
tween_done :: proc(ctx: ^Context, tw: Tween) -> bool {
	return tw.duration <= 0 || f32(ctx.time - tw.start) >= tw.delay + tw.duration
}

// Drops tweens no widget has asked for lately. Map order cannot matter: each entry is
// judged on its own.
@(private)
tween_prune :: proc(ctx: ^Context) {
	clear(&ctx.scratch_ids)
	for id, tw in ctx.tweens {
		if ctx.time - tw.seen > TWEEN_KEEP do append(&ctx.scratch_ids, id)
	}
	for id in ctx.scratch_ids do delete_key(&ctx.tweens, id)
}

// A tween's own id, derived from a widget's: a widget with several animated properties
// salts its id once per property.
salt :: #force_inline proc(id: Id, s: u64) -> Id {
	return id ~ (s * 0x9e3779b97f4a7c15)
}

// Changes everything drawn since vertex `mark`: its opacity multiplied by `opacity`,
// scaled by `scale` about `origin` and moved by `offset` (points). Panels and popovers
// use it to fade, grow and slide in and out without being laid out differently. With
// motion Reduced the scale and the offset are left out, so things fade in place; one that
// `follows` a finger or the pen (a page dragged sideways) keeps them, since it is not an
// animation but where the hand put it.
transform_since :: proc(ctx: ^Context, mark: int, opacity: f32 = 1, scale: f32 = 1, origin: [2]f32 = {}, offset: [2]f32 = {}, follows := false) {
	moved, shift := scale, offset
	if ctx.motion == .Reduced && !follows do moved, shift = 1, {}
	d := px(ctx)
	o := origin * d
	off := shift * d
	verts := ctx.draw.vertices[mark:]
	if moved != 1 || off != {} {
		for &v in verts do v.pos = o + (v.pos - o) * moved + off
	}
	if opacity < 1 {
		a := clamp(opacity, 0, 1)
		for &v in verts do v.color.a = u8(f32(v.color.a) * a + 0.5)
	}
}

// The draw list's vertex count now, for transform_since.
vertex_mark :: proc(ctx: ^Context) -> int {
	return len(ctx.draw.vertices)
}

// Maps everything drawn since vertex `mark` from about point `from` onto a slanted plane
// about `to` (points): `from + (x, y)` goes to `to + x * x_axis + y * y_axis`. Text laid out
// flat and then mapped onto a face seen at a slant, as the view gizmo's cube names its
// faces; in a parallel view the map is exact, so the words stay sharp at any turn.
map_since :: proc(ctx: ^Context, mark: int, from, to, x_axis, y_axis: [2]f32) {
	d := px(ctx)
	for &v in ctx.draw.vertices[mark:] {
		p := v.pos / d - from
		v.pos = (to + p.x * x_axis + p.y * y_axis) * d
	}
}

// Turns everything drawn since vertex `mark` by `radians` about `origin` (points): a
// chevron opening its section.
rotate_since :: proc(ctx: ^Context, mark: int, radians: f32, origin: [2]f32) {
	if radians == 0 do return
	o := origin * px(ctx)
	c, s := math.cos(radians), math.sin(radians)
	for &v in ctx.draw.vertices[mark:] {
		d := v.pos - o
		v.pos = o + {d.x * c - d.y * s, d.x * s + d.y * c}
	}
}

// Where something starts in the draw list: its first vertex, index and command. Taking one
// starts a command of its own, so slide_since can move the clip rectangles of what follows
// without moving those of what came before.
Motion_Mark :: struct {
	vertex, index, cmd: int,
}

motion_mark :: proc(ctx: ^Context) -> Motion_Mark {
	dl := &ctx.draw
	if n := len(dl.cmds); n > 0 && dl.cmds[n - 1].index_count > 0 {
		last := dl.cmds[n - 1]
		append(&dl.cmds, Draw_Cmd{first_index = u32(len(dl.indices)), clip = last.clip, texture = last.texture, image = last.image})
	}
	return {len(dl.vertices), len(dl.indices), max(len(dl.cmds) - 1, 0)}
}

// Moves everything drawn since `m` by `offset` (points), clip rectangles too, so a panel
// with a scrolling body slides whole; `limit` (points, when it has a width) cuts it off
// where it slides in from behind something, as a card from behind its dock; `opacity`
// multiplies its alpha. With motion Reduced the move and the cut are left out and only the
// fade is kept, unless it `follows` a finger.
slide_since :: proc(ctx: ^Context, m: Motion_Mark, opacity: f32 = 1, offset: [2]f32 = {}, limit: Rect = {}, follows := false) {
	shift, keep := offset, limit
	if ctx.motion == .Reduced && !follows do shift, keep = {}, {}
	transform_since(ctx, m.vertex, opacity, 1, {}, shift, follows = true)
	if shift == {} && keep.w <= 0 do return
	d := px(ctx)
	off := shift * d
	cut := Rect{keep.x * d, keep.y * d, keep.w * d, keep.h * d}
	for &c in ctx.draw.cmds[min(m.cmd, len(ctx.draw.cmds)):] {
		c.clip.x += off.x
		c.clip.y += off.y
		if keep.w > 0 do c.clip = rect_intersect(c.clip, cut)
	}
}

// What one thing drew in a frame: from its mark to where it ended, and in which frame, so
// that once it stops being drawn the frame after can copy it out of draw_prev. Whether it
// was drawn the frame before is drawn_last.
Draw_Range :: struct {
	using mark:            Motion_Mark,
	vertex_end, index_end: int,
	frame:                 u64,
}

range_end :: proc(ctx: ^Context, m: Motion_Mark) -> Draw_Range {
	return {mark = m, vertex_end = len(ctx.draw.vertices), index_end = len(ctx.draw.indices), frame = ctx.frame}
}

// Whether range `r` was drawn in the frame before this one.
drawn_last :: proc(ctx: ^Context, r: Draw_Range) -> bool {
	return r.frame != 0 && r.frame + 1 == ctx.frame
}

// A copy of what something drew, kept to draw it again while it leaves.
Draw_Copy :: struct {
	vertices: [dynamic]Vertex,
	indices:  [dynamic]u32,
	cmds:     [dynamic]Draw_Cmd,
}

draw_copy_destroy :: proc(c: ^Draw_Copy) {
	delete(c.vertices)
	delete(c.indices)
	delete(c.cmds)
	c^ = {}
}

// Copies range `r` out of last frame's draw list into `out`, when it was drawn last frame.
// Its triangles are found by their vertices, which nothing moves once drawn: what is laid
// under the panels after them (layer_mark) moves indices, not vertices.
copy_prev :: proc(ctx: ^Context, r: Draw_Range, out: ^Draw_Copy) -> bool {
	dl := &ctx.draw_prev
	if r.frame == 0 || r.frame + 1 != ctx.frame || r.vertex_end > len(dl.vertices) || r.vertex_end <= r.vertex do return false
	clear(&out.vertices)
	clear(&out.indices)
	clear(&out.cmds)
	append(&out.vertices, ..dl.vertices[r.vertex:r.vertex_end])
	lo, hi := u32(r.vertex), u32(r.vertex_end)
	for c in dl.cmds {
		first := len(out.indices)
		tris := dl.indices[c.first_index:c.first_index + c.index_count]
		for i := 0; i + 2 < len(tris); i += 3 {
			if tris[i] < lo || tris[i] >= hi do continue
			append(&out.indices, tris[i] - lo, tris[i + 1] - lo, tris[i + 2] - lo)
		}
		if n := len(out.indices) - first; n > 0 {
			append(&out.cmds, Draw_Cmd{first_index = u32(first), index_count = u32(n), clip = c.clip, texture = c.texture, image = c.image})
		}
	}
	return len(out.indices) > 0
}

// Draws copy `c` again where it was, returning its mark for slide_since.
draw_copy :: proc(ctx: ^Context, c: ^Draw_Copy) -> Motion_Mark {
	m := motion_mark(ctx)
	dl := &ctx.draw
	// The copy brings its own commands: the empty one the mark started is not needed.
	if n := len(dl.cmds); n > 0 && dl.cmds[n - 1].index_count == 0 && n - 1 >= dl.keep do pop(&dl.cmds)
	m.cmd = len(dl.cmds)
	base, first := u32(len(dl.vertices)), u32(len(dl.indices))
	append(&dl.vertices, ..c.vertices[:])
	for i in c.indices do append(&dl.indices, i + base)
	for cmd in c.cmds {
		x := cmd
		x.first_index += first
		append(&dl.cmds, x)
	}
	return m
}
