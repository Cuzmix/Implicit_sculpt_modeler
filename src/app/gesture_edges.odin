package main

import "../ui"

// Android's back gesture is a swipe in from either side edge, so a drag that starts on a
// dock standing on a side edge (its grip, a value scrubbed, a button carried) would take
// the app back instead. Android lets an app keep strips of those edges for itself, at most
// 200 dp of each edge's height (it keeps the lowest when given more): so each frame the app
// names, for every dock on a side edge, the strip from the window's edge across the dock,
// from the dock's top down to that height, which holds its grip and its first controls.
// The strips go to the window's view only when they change.

// The most strips sent: one for each dock that can stand on a side edge.
GESTURE_EDGE_MOST :: len(Dock_Id)

// How tall a strip is, in points: Android's whole allowance for an edge.
GESTURE_EDGE_H :: 200

Gesture_Edges :: struct {
	sent:  [GESTURE_EDGE_MOST][4]i32, // the strips last sent: left, top, right, bottom in pixels
	count: int, // how many of them
}

when ODIN_PLATFORM_SUBTARGET == .Android {
	// android/app/jni/android_main.c: hands `count` strips (left, top, right, bottom, in
	// the window's pixels) to the activity, which sets them on the window's view.
	@(default_calling_convention = "c")
	foreign {
		sculpt_android_gesture_exclusion :: proc(rects: [^]i32, count: i32) ---
	}
}

// The strips this frame's layout asks for, in pixels: every shown dock on the left or
// right edge, from where it was drawn last frame.
gesture_edges_wanted :: proc(k: ^Kit_State) -> (out: [GESTURE_EDGE_MOST][4]i32, n: int) {
	ctx := &k.ctx
	scale := ctx.input.pixel_density if ctx.input.pixel_density > 0 else 1
	w := ctx.input.window.x
	for d in Dock_Id {
		edge := dock_edge(k, d)
		if (edge != .Left && edge != .Right) || !dock_shown(k, d) do continue
		r := ui.prev_root_rect(ctx, DOCK_ROOTS[d])
		if r.w <= 0 || r.h <= 0 do continue
		// The kit mirrors a left hand's layout, so the side is read from where the dock is.
		left := r.x + r.w * 0.5 < w * 0.5
		x0, x1 := (0 if left else r.x), (r.x + r.w if left else w)
		y0, y1 := r.y, r.y + min(r.h, GESTURE_EDGE_H)
		out[n] = {i32(x0 * scale), i32(y0 * scale), i32(x1 * scale + 0.5), i32(y1 * scale + 0.5)}
		n += 1
	}
	return
}

// Once a frame, after the interface is laid out: sends the strips when they changed. Away
// from Android there is no edge gesture to keep from, and nothing is sent.
gesture_edges_update :: proc(app: ^App) {
	when ODIN_PLATFORM_SUBTARGET == .Android {
		g := &app.gesture_edges
		want, n := gesture_edges_wanted(&app.kit)
		if n == g.count && want == g.sent do return
		g.sent, g.count = want, n
		sculpt_android_gesture_exclusion(cast([^]i32)raw_data(g.sent[:]), i32(n))
	} else {
		_ = app
	}
}
