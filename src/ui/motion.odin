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
tween :: proc(ctx: ^Context, id: Id, target: f32, duration: f32, e := Ease.Out_Quad, delay: f32 = 0) -> f32 {
	return tween_from(ctx, id, target, target, duration, e, delay)
}

// As tween, but the first time `id` is seen it starts at `start`: for things that
// animate in when they first appear.
tween_from :: proc(ctx: ^Context, id: Id, start, target: f32, duration: f32, e := Ease.Out_Quad, delay: f32 = 0) -> f32 {
	duration := 0 if ctx.reduced_motion else duration
	delay := 0 if ctx.reduced_motion else delay
	tw, found := &ctx.tweens[id]
	if !found {
		ctx.tweens[id] = {from = start, to = target, start = ctx.time, duration = duration, delay = delay, ease = e, seen = ctx.time}
		tw = &ctx.tweens[id]
	}
	tw.seen = ctx.time
	if tw.to != target {
		tw.from = tween_value(ctx, tw^)
		tw.to = target
		tw.start = ctx.time
		tw.duration = duration
		tw.delay = delay
		tw.ease = e
	}
	return tween_value(ctx, tw^)
}

// The share (0 to 1) something that opens and closes is shown: rising while `open`,
// falling after. It starts closed, so the first frame open animates in. Draw it while
// this is above 0.
presence :: proc(ctx: ^Context, id: Id, open: bool, duration: f32) -> f32 {
	return tween_from(ctx, id, 0, 1 if open else 0, duration, .Out_Cubic)
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
// use it to fade, grow and slide in and out without being laid out differently.
transform_since :: proc(ctx: ^Context, mark: int, opacity: f32 = 1, scale: f32 = 1, origin: [2]f32 = {}, offset: [2]f32 = {}) {
	d := px(ctx)
	o := origin * d
	off := offset * d
	verts := ctx.draw.vertices[mark:]
	if scale != 1 || off != {} {
		for &v in verts do v.pos = o + (v.pos - o) * scale + off
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
