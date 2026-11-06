package main

import "core:fmt"
import "core:math/linalg"
import "core:slice"

import "../camera"
import "../gizmo"
import "../poly"

// Two Model actions that move points without changing the cage's topology, each a drag
// that is one undo step:
//
// Relax, a brush for cages, as Blender's Relax and Smooth brushes in edit mode and
// ZModeler's Relax: dragged over a cage, the points under its ring (and their mirror
// images under symmetry) move toward the middle of their neighbours across the surface,
// evening the spacing while keeping the shape; with Ctrl they smooth outright, which
// rounds and shrinks. Points facing away are left, so the far side is untouched.
//
// Slide, as Blender's edge slide (G twice on edges): pressed on an edge (or an edge loop,
// by the target) and dragged, each end of those edges slides along the edge out of it
// that runs most nearly the way the drag goes on screen, all by the same share of their
// rails, so a loop moves through the faces without leaving the surface.

// The Relax brush's ring, in points on screen, and the share of the way to the middle a
// point under its centre goes each frame.
MODEL_RELAX_RADIUS :: 60
MODEL_RELAX_RATE :: 0.35

Model_Relax :: struct {
	object: int,
	before: ^Object_Snapshot,
	smooth: bool, // the stroke smooths (Ctrl at the press) rather than relaxes
	strokes: int, // strokes that moved points, for the exit stats
}

// The Relax brush, a frame. Returns false only on a GPU failure.
model_relax_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	r := &app.model.relax
	if !input.primary {
		if r.before != nil {
			history_record_swap(app, r.object, r.before, kind = .Model)
			r.before = nil
			r.strokes += 1
			app.model.done += 1
		}
		r.object = 0
		return true
	}
	if input.press {
		r.object, r.smooth = 0, input.invert
		if obj, _, _, _, _, ok := model_pick(app, input.mouse_pos, input.size, false); ok do r.object = obj.id
	}
	obj := object_by_id(app, r.object)
	if obj == nil || obj.cage == nil do return true
	cage := &obj.cage.mesh
	vp := view_proj_of(app, input.size)
	radius := MODEL_RELAX_RADIUS * gizmo_scale(app)
	signs := poly.mirror_signs(model_axes(app))
	eye := camera.orbit_eye(app.camera)
	points := make([dynamic]u32, context.temp_allocator)
	weights := make([dynamic]f32, context.temp_allocator)
	for p, v in cage.positions {
		// The share the ring gives the point, at its own place or any mirror image's, so
		// both sides relax alike.
		best: f32
		for s in signs {
			w := to_world(obj.transform, p * s)
			n := linalg.normalize0(to_world(obj.transform, (p + poly.vert_normal(cage, u32(v))) * s) - w)
			if linalg.dot(n, w - eye) > 0 do continue
			at, seen := gizmo.project(vp, w, input.size)
			if !seen do continue
			d := linalg.length(at - input.mouse_pos)
			if d >= radius do continue
			best = max(best, poly.point_move_falloff(d, radius))
		}
		if best <= 0 do continue
		append(&points, u32(v))
		append(&weights, best * MODEL_RELAX_RATE)
	}
	if len(points) == 0 do return true
	goals := poly.smooth_goals(cage, points[:], !r.smooth, context.temp_allocator)
	slack := poly.mirror_slack(cage)
	axes := model_axes(app)
	for v, i in points {
		q := cage.positions[v]
		p := linalg.lerp(q, goals[i], weights[i])
		// A point on a mirror plane stays on it, as the gizmo keeps it.
		for a in axes do if abs(q[int(a)]) <= slack do p[int(a)] = q[int(a)]
		goals[i] = p
	}
	if r.before == nil {
		// The snapshot frees the frame's temporary memory: what moves is kept on the heap
		// across it.
		kept_v := slice.clone(points[:])
		kept_at := slice.clone(goals[:])
		defer delete(kept_v)
		defer delete(kept_at)
		r.before = history_snapshot(app, obj, "relax cage" if !r.smooth else "smooth cage")
		for v, i in kept_v do cage.positions[v] = kept_at[i]
		return cage_positions_moved(app, obj, kept_v)
	}
	for v, i in points do cage.positions[v] = goals[i]
	return cage_positions_moved(app, obj, points[:])
}

// The Relax brush's ring at the pointer, and its name.
draw_relax_overlay :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	if !input.hovered && !input.primary do return
	px := gizmo_scale(app)
	smooth := app.model.relax.smooth if app.model.relax.object != 0 else app.device.ctrl
	overlay_circle(o, input.mouse_pos, MODEL_RELAX_RADIUS * px, overlay_color(GIZMO_HIGHLIGHT), 1.5 * px)
	overlay_label(o, "Smooth" if smooth else MODEL_ACTION_NAMES[.Relax], input.mouse_pos + {0, -MODEL_RELAX_RADIUS * px - 16 * px})
}

// A slide under way: the points, where they began, and the end of the edge each slides
// toward (NONE for a point that stays).
Model_Slide :: struct {
	object: int,
	before: ^Object_Snapshot,
	press:  [2]f32,
	live:   bool,
	points: [dynamic]u32,
	rails:  [dynamic]u32,
	start:  [dynamic]Vec3,
	goal:   [dynamic]Vec3, // where each rail ends, as the slide began
	edges:  [dynamic]u32, // the edges pressed on (with their images), whose ends slide
	share:  f32, // how far along their rails the points are, 0 to 1
	slides: int, // slides made, for the exit stats
}

model_slide_free :: proc(s: ^Model_Slide) {
	if s.before != nil do history_snapshot_drop(s.before)
	delete(s.points)
	delete(s.rails)
	delete(s.start)
	delete(s.goal)
	delete(s.edges)
	s^ = {slides = s.slides}
}

// The Slide action, a frame. Returns false only on a GPU failure.
model_slide_frame :: proc(app: ^App, input: Viewport_Input) -> bool {
	s := &app.model.slide
	if s.object == 0 {
		model_hover(app, input.mouse_pos, input.size, input.hovered || input.primary)
		if !input.primary || !input.press do return true
		h := &app.model.hover
		if h.object == 0 || len(h.items) == 0 do return true
		s.object, s.press, s.live, s.share = h.object, input.mouse_pos, false, 0
		append(&s.edges, ..h.items[:])
		append(&s.edges, ..h.images[:])
		return true
	}
	obj := object_by_id(app, s.object)
	if obj == nil || obj.cage == nil {
		model_slide_free(s)
		return true
	}
	cage := &obj.cage.mesh
	if !input.primary {
		changed := s.live && s.before != nil && s.share != 0
		if changed {
			history_record_swap(app, s.object, s.before, kind = .Model)
			s.before = nil
			s.slides += 1
			app.model.done += 1
		}
		model_slide_free(s)
		return true
	}
	if key_pressed(&app.device, KEY_ESCAPE) {
		ok := true
		if s.live {
			for v, i in s.points do cage.positions[v] = s.start[i]
			ok = cage_positions_moved(app, obj, s.points[:])
		}
		model_slide_free(s)
		return ok
	}
	vp := view_proj_of(app, input.size)
	screen :: proc(vp: matrix[4, 4]f32, obj: ^Object, p: Vec3, size: [2]f32) -> [2]f32 {
		at, _ := gizmo.project(vp, to_world(obj.transform, p), size)
		return at
	}
	drag := input.mouse_pos - s.press
	if !s.live {
		if linalg.length(drag) <= app.kit.ctx.theme.slop do return true
		// The rails, from the way the drag first went.
		way := linalg.normalize(drag)
		ends := make(map[u32]bool, allocator = context.temp_allocator)
		pressed := make(map[u32]bool, allocator = context.temp_allocator)
		for e in s.edges {
			if int(e) >= len(cage.crease) do continue
			pressed[e] = true
			a, b := poly.edge_verts(cage, e)
			ends[a], ends[b] = true, true
		}
		ordered := make([dynamic]u32, context.temp_allocator)
		for v in ends do append(&ordered, v)
		slice.sort(ordered[:])
		for v in ordered {
			at := screen(vp, obj, cage.positions[v], input.size)
			rail, best := poly.NONE, f32(0.2)
			w := poly.vertex_walk(cage, v)
			for h in poly.vertex_walk_next(&w) {
				if poly.edge_of(h) in pressed do continue
				o := poly.he_tip(cage, h)
				d := screen(vp, obj, cage.positions[o], input.size) - at
				if l := linalg.length(d); l > 1 {
					if c := linalg.dot(d / l, way); c > best do rail, best = o, c
				}
			}
			append(&s.points, v)
			append(&s.rails, rail)
			append(&s.start, cage.positions[v])
			append(&s.goal, cage.positions[rail] if rail != poly.NONE else cage.positions[v])
		}
		// The snapshot frees the frame's temporary memory; nothing temporary is used after.
		s.before = history_snapshot(app, obj, "slide")
		s.press = input.mouse_pos
		s.live = true
		return true
	}
	// The share: how far the pointer went along the rails' mean on screen.
	mean: [2]f32
	count := 0
	for _, i in s.points {
		if s.rails[i] == poly.NONE do continue
		mean += screen(vp, obj, s.goal[i], input.size) - screen(vp, obj, s.start[i], input.size)
		count += 1
	}
	if count == 0 do return true
	mean /= f32(count)
	length2 := linalg.dot(mean, mean)
	if length2 < 1 do return true
	share := clamp(linalg.dot(input.mouse_pos - s.press, mean) / length2, 0, 0.98)
	if app.device.shift do share = gizmo.snap(share, 0.25)
	s.share = share
	for v, i in s.points {
		if s.rails[i] == poly.NONE do continue
		cage.positions[v] = linalg.lerp(s.start[i], s.goal[i], share)
	}
	return cage_positions_moved(app, obj, s.points[:])
}

// The slide's readout by the pointer.
draw_slide_label :: proc(app: ^App, o: Overlay, input: Viewport_Input) {
	s := &app.model.slide
	if s.object == 0 || !s.live do return
	overlay_label(o, fmt.tprintf("Slide %.0f%%", s.share * 100), input.mouse_pos + {0, -36})
}
