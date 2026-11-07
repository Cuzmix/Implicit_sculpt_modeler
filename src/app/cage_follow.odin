package main

import "core:fmt"
import "core:hash"
import "core:math/linalg"
import "core:slice"

import "../geom"
import "../poly"
import "../ui"

// The Live stack rows of a cage that follow another object, as Blender's Curve and
// Shrinkwrap modifiers do, both on the drawn surface after Smooth (as Blender users put
// them after Subdivision Surface, so a bend is smooth and a wrap close). Curve lays the
// cage along a curve object: the cage's length along an axis becomes length along
// the curve from its start, and its other two directions the curve's sideways frame, so a
// straight tube bends with the curve and moves when the curve is edited. Wrap puts every
// drawn point on the nearest point of another object's surface, an offset
// above it along that surface's normal, so a smooth cage hugs a sculpt for retopology,
// armour or clothing. Both follow their object: each frame a cheap stamp of what they read
// is compared with the one they were made from, and a change works the cage out again
// (cage_follow_frame), as the cage's own moves do.

Cage_Follow :: struct {
	curve:       int, // the curve object's id; 0 for none
	curve_axis:  poly.Mirror_Axis, // the cage's direction laid along the curve
	curve_fit:   bool, // the cage's length stretched to the curve's, end to end
	wrap:        int, // the object wrapped onto; 0 for none
	wrap_offset: f32, // how far above its surface, in the cage's units
}

// Whether any follow row is on (an object picked, which may since have gone).
cage_follow_on :: proc(f: Cage_Follow) -> bool {return f.curve != 0 || f.wrap != 0}

// The curve object the Curve row lays the cage on, while it is in the scene with a
// length; nil otherwise.
cage_follow_curve :: proc(app: ^App, obj: ^Object, f: Cage_Follow) -> ^Object {
	if f.curve == 0 do return nil
	curve := object_by_id(app, f.curve)
	if curve == nil || curve == obj || curve.curve == nil || len(curve.curve.points) < 2 do return nil
	return curve
}

// The object the Wrap row wraps onto, while it is in the scene as triangles (a sculpt or
// a cage, not clay or a curve); nil otherwise.
cage_follow_wrap :: proc(app: ^App, obj: ^Object, f: Cage_Follow) -> ^Object {
	if f.wrap == 0 do return nil
	target := object_by_id(app, f.wrap)
	if target == nil || target == obj || target.voxel != nil || target.curve != nil || !object_draws_triangles(target) do return nil
	if len(object_mesh(target).indices) < 3 do return nil
	return target
}

// Lays `m`'s points (the drawn surface, in the cage's own space) along the Curve row's curve:
// a point's coordinate along the axis, from the cage's low end, is its distance along the
// curve (with Fit, its share of the cage's length is that share of the curve's), and its
// other two coordinates go along the curve's normal and binormal. Past
// an open curve's ends the cage runs on straight along the end's tangent; a closed curve
// goes round again.
cage_follow_curve_apply :: proc(app: ^App, obj: ^Object, cp: ^Cage_Part, m: ^poly.Mesh) {
	curve := cage_follow_curve(app, obj, cp.look.follow)
	if curve == nil do return
	c := curve.curve
	length := geom.bezier_length(c.points[:], c.closed)
	if !(length > 1e-9) do return
	samples := geom.bezier_sample(c.points[:], c.closed, length / CAGE_CURVE_SAMPLES, context.temp_allocator)
	frames := geom.bezier_frames(samples, {0, 1, 0}, c.closed, context.temp_allocator)
	if len(samples) < 2 || len(frames) != len(samples) do return
	total := samples[len(samples) - 1].s
	if c.closed do total = length
	span := poly.mesh_bounds(&cp.mesh)
	lo := span.lo
	a := int(cp.look.follow.curve_axis)
	along := span.hi[a] - lo[a]
	fit := cp.look.follow.curve_fit && along > 1e-9
	ca, cb := (a + 1) % 3, (a + 2) % 3
	scale := obj.transform.scale
	inv := linalg.inverse(transform_matrix(obj.transform))
	turn := transform_rotation(curve.transform)
	for &p in m.positions {
		s := (p[a] - lo[a]) / along * total if fit else (p[a] - lo[a]) * scale
		beyond: f32
		if c.closed {
			s -= total * f32(int(s / total))
			if s < 0 do s += total
		} else if s < 0 {
			beyond, s = s, 0
		} else if s > total {
			beyond, s = s - total, total
		}
		// The two samples either side of s, by halves.
		i, j := 0, len(samples) - 1
		for j - i > 1 {
			mid := (i + j) / 2
			if samples[mid].s <= s do i = mid
			else do j = mid
		}
		span := samples[j].s - samples[i].s
		t := (s - samples[i].s) / span if span > 1e-12 else 0
		at := linalg.lerp(frames[i].p, frames[j].p, t)
		n := linalg.normalize0(linalg.lerp(frames[i].n, frames[j].n, t))
		b := linalg.normalize0(linalg.lerp(frames[i].b, frames[j].b, t))
		tan := linalg.normalize0(linalg.lerp(frames[i].t, frames[j].t, t))
		world := to_world(curve.transform, at) + turn * (n * (p[ca] * scale) + b * (p[cb] * scale) + tan * beyond)
		p = (inv * [4]f32{world.x, world.y, world.z, 1}).xyz
	}
}

// How many pieces the Curve row cuts its curve into: fine enough that a cage along it
// bends smoothly, and cheap beside the cage's own rebuild.
CAGE_CURVE_SAMPLES :: 256

// Puts `m`'s points (the drawn surface, in the cage's own space) on the Wrap row's object:
// each on the nearest point of its surface, the row's offset out along its normal there.
// The object's search tree is kept with the cage and made again only when the object
// changes.
cage_follow_wrap_apply :: proc(app: ^App, obj: ^Object, cp: ^Cage_Part, m: ^poly.Mesh) {
	target := cage_follow_wrap(app, obj, cp.look.follow)
	if target == nil do return
	tm := object_mesh(target)
	stamp := cage_wrap_stamp(target)
	if !cp.wrap_made || cp.wrap_stamp != stamp {
		if cp.wrap_made do geom.bvh_destroy(&cp.wrap_bvh)
		cp.wrap_bvh = geom.bvh_build_morton(tm^, geom.BVH_LEAF_SIZE, &app.pool)
		cp.wrap_made, cp.wrap_stamp = true, stamp
	}
	world := transform_matrix(obj.transform)
	to_target := linalg.inverse(transform_matrix(target.transform)) * world
	back := linalg.inverse(to_target)
	bounds := geom.AABB_EMPTY
	for q in tm.positions do geom.aabb_grow(&bounds, q)
	reach := 2 * linalg.length(bounds.hi - bounds.lo) + 1
	offset := cp.look.follow.wrap_offset * obj.transform.scale / max(target.transform.scale, 1e-6)
	smooth := len(tm.normals) == len(tm.positions)
	for &p in m.positions {
		q := (to_target * [4]f32{p.x, p.y, p.z, 1}).xyz
		tri, bary, _, ok := geom.bvh_closest(cp.wrap_bvh, tm^, q, reach)
		if !ok do continue
		k := tm.indices[3 * tri:][:3]
		pa, pb, pc := tm.positions[k[0]], tm.positions[k[1]], tm.positions[k[2]]
		hit := bary[0] * pa + bary[1] * pb + bary[2] * pc
		n := linalg.normalize0(linalg.cross(pb - pa, pc - pa))
		if smooth {
			if blend := linalg.normalize0(bary[0] * tm.normals[k[0]] + bary[1] * tm.normals[k[1]] + bary[2] * tm.normals[k[2]]); blend != {} do n = blend
		}
		out := hit + n * offset
		p = (back * [4]f32{out.x, out.y, out.z, 1}).xyz
	}
}

// What the Wrap row's search tree was made from: the object, its shown level and its
// size, and its edits (a sculpt's undo steps; a cage's points themselves, since a cage's
// moves are not sculpt steps), so a stroke, an undo or a cage edit makes it again.
@(private = "file")
cage_wrap_stamp :: proc(target: ^Object) -> u64 {
	tm := object_mesh(target)
	h := sculpt_history_of(target)
	parts := [6]u64{u64(target.id), u64(target.levels.current), u64(len(tm.positions)), h.last, u64(h.done), u64(h.undone)}
	stamp := hash.fnv64a(slice.to_bytes(parts[:]))
	if target.cage != nil do stamp ~= hash.fnv64a(slice.to_bytes(tm.positions[:]))
	return stamp
}

@(private = "file")
Sculpt_History_Stamp :: struct {
	last:   u64,
	done:   int,
	undone: int,
}

@(private = "file")
sculpt_history_of :: proc(obj: ^Object) -> Sculpt_History_Stamp {
	hist := &object_sculptor(obj).history
	return {hist.last_id, len(hist.done), len(hist.undone)}
}

// What a cage's follow rows read, as one number: its own place (they work in the world)
// and its curve's points and place, and its wrap object's stamp and place; 0 with no row.
cage_follow_stamp :: proc(app: ^App, obj: ^Object) -> u64 {
	cp := obj.cage
	f := cp.look.follow
	if !cage_follow_on(f) do return 0
	h := hash.fnv64a(slice.to_bytes([]Transform{obj.transform}))
	if curve := cage_follow_curve(app, obj, f); curve != nil {
		h ~= hash.fnv64a(slice.to_bytes(curve.curve.points[:])) ~ hash.fnv64a(slice.to_bytes([]Transform{curve.transform})) * 31
		h ~= u64(curve.curve.closed) << 63
	} else {
		h ~= 0x9e37_79b9
	}
	if target := cage_follow_wrap(app, obj, f); target != nil {
		h ~= cage_wrap_stamp(target) * 7 ~ hash.fnv64a(slice.to_bytes([]Transform{target.transform})) * 13
	} else {
		h ~= 0x7f4a_7c15
	}
	return h | 1
}

// Each frame: every cage whose follow rows read something that changed since it was last
// worked out is worked out again, as a move of its points is. Nothing runs while a stroke
// or a gizmo drag is under way, so a sculpt being wrapped onto is read once the stroke
// ends. Returns false only on a GPU failure.
cage_follow_frame :: proc(app: ^App) -> bool {
	if app.stroke.active do return true
	for obj in app.scene.objects {
		cp := obj.cage
		if cp == nil || !cage_follow_on(cp.look.follow) do continue
		stamp := cage_follow_stamp(app, obj)
		if stamp == cp.follow_stamp do continue
		app.model.follow_updates += 1
		if !cage_positions_moved(app, obj, nil) do return false
	}
	return true
}

// A follow row's object, named in its row and its list.
cage_follow_label :: proc(app: ^App, target: ^Object) -> string {
	return object_label(target)
}

// The farthest Wrap's offset goes either way, as a percentage of the cage's size.
CAGE_WRAP_PERCENT_MAX :: 10

// The first object in the scene the cage can be wrapped onto; 0 for none.
cage_first_wrap :: proc(app: ^App, obj: ^Object) -> int {
	for o in app.scene.objects do if cage_follow_wrap(app, obj, {wrap = o.id}) != nil do return o.id
	return 0
}

@(private = "file")
cage_follow_set :: proc(app: ^App, obj: ^Object, f: Cage_Follow) {
	look := obj.cage.look
	look.follow = f
	app.ui.scene_command = {kind = .Cage_Look, look = look}
}

// The Curve row: which curve object, and which of the cage's axes runs along it.
kit_cage_curve :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	f := obj.cage.look.follow
	curves := make([dynamic]^Object, 0, 4, context.temp_allocator)
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	chosen := -1
	for o in app.scene.objects {
		if o == obj || o.curve == nil do continue
		if o.id == f.curve do chosen = len(curves)
		append(&curves, o)
		append(&names, stack_curve_label(app, o))
	}
	if len(curves) == 0 {
		ui.paragraph(ctx, "Draw a curve object (Curve, then a stroke on the view) to lay the cage along it.")
		return
	}
	if chosen < 0 do ui.paragraph(ctx, "Pick the curve to lay the cage along.")
	if pick := ui.select(ctx, "Curve##cage curve", names[:], chosen); pick != chosen && pick >= 0 {
		g := f
		g.curve = curves[pick].id
		cage_follow_set(app, obj, g)
	}
	ui.caption(ctx, "RUNS ALONG THE CURVE")
	axes := [len(poly.Mirror_Axis)]string{"X", "Y", "Z"}
	if picked := ui.tabs(ctx, "cage curve axis", axes[:], int(f.curve_axis)); picked >= 0 && poly.Mirror_Axis(picked) != f.curve_axis {
		g := f
		g.curve_axis = poly.Mirror_Axis(picked)
		cage_follow_set(app, obj, g)
	}
	fit := f.curve_fit
	if ui.switch_row(ctx, "Fit to the curve", &fit) {
		g := f
		g.curve_fit = fit
		cage_follow_set(app, obj, g)
	}
	line := "The cage is stretched along the whole curve" if f.curve_fit else "The cage starts at the curve's start, its length along the axis becoming length along the curve"
	ui.paragraph(ctx, fmt.tprintf("%s, and follows the curve as it is edited.", line), color = ctx.theme.text_tertiary)
}

// The Wrap row: which object, and how far above its surface.
kit_cage_wrap :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	f := cp.look.follow
	targets := make([dynamic]^Object, 0, 4, context.temp_allocator)
	names := make([dynamic]string, 0, 4, context.temp_allocator)
	chosen := -1
	for o in app.scene.objects {
		if cage_follow_wrap(app, obj, {wrap = o.id}) == nil do continue
		if o.id == f.wrap do chosen = len(targets)
		append(&targets, o)
		append(&names, cage_follow_label(app, o))
	}
	if len(targets) == 0 {
		ui.paragraph(ctx, "Add a sculpt or another cage to wrap this cage onto.")
		return
	}
	if chosen < 0 do ui.paragraph(ctx, "Pick the object to wrap the cage onto.")
	if pick := ui.select(ctx, "Object##cage wrap", names[:], chosen); pick != chosen && pick >= 0 {
		g := f
		g.wrap = targets[pick].id
		cage_follow_set(app, obj, g)
	}
	size := cage_size(cp)
	off := 100 * f.wrap_offset / size
	if ui.slider(ctx, "Offset", &off, -CAGE_WRAP_PERCENT_MAX, CAGE_WRAP_PERCENT_MAX, .Linear, fmt.tprintf("%+.1f%%", off)) {
		look := cp.look
		look.follow.wrap_offset = off / 100 * size
		app.ui.scene_command = {kind = .Cage_Look, look = look, look_drag = true}
	}
	ui.paragraph(ctx, "Every drawn point goes to the nearest point of the object's surface, the offset out along its normal, and follows the object as it is sculpted or moved.", color = ctx.theme.text_tertiary)
}
