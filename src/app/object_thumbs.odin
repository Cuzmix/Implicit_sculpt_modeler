package main

import "core:hash"
import "core:math/linalg"
import "core:mem"
import "core:time"

import "../camera"
import "../geom"
import "../render"
import "../sculpt"

// The Objects card's pictures of objects, as ZBrush for iPad's Subtools rows have them:
// each object the card shows gets a cell of render.Thumbs' atlas, drawn from the front
// in its own turn, fitted to its bounds. A cell is drawn again only once its object has
// stayed unchanged for THUMB_SETTLE, never during a stroke or while the view moves, and
// at most one a frame, so sculpting a large mesh costs nothing until it settles and then
// one draw of its whole mesh.

// How long an object stays unchanged before its picture is drawn again.
THUMB_SETTLE :: 400 * time.Millisecond

// The clay a picture is shaded in, light like ZBrush's, linear like every Draw_Item colour.
THUMB_COLOR :: [4]f32{0.72, 0.72, 0.72, 1}

// A cell of the atlas: the object it shows, what that object looks like now and what the
// cell holds (thumb_key; 0 for nothing yet), when the first last changed, and the frame
// the card last showed it, which decides the cell given up for another object.
Thumb_Slot :: struct {
	id:      int,
	want:    u64,
	drawn:   u64,
	changed: time.Tick,
	used:    int,
}

Thumb_Slots :: struct {
	slots: [render.THUMB_SLOTS]Thumb_Slot,
	frame: int, // counts frames from 1, so a cell never shown has an older frame
	drawn: int, // pictures drawn, for the exit stats
}

// What decides how the object's picture looks: its drawn buffers (positions, normals
// and mask; a clay's surface has one set, a mesh its current level's), its paint and
// whether that shows, and its turn.
thumb_key :: proc(obj: ^Object) -> u64 {
	gpu, _, _ := thumb_shape(obj)
	r := obj.transform.rotation
	keyed := [7]u64{gpu.version, u64(gpu.paint_stamp), u64(obj.levels.current), u64(obj.paint_off), u64(transmute(u32)r.x), u64(transmute(u32)r.y), u64(transmute(u32)r.z)}
	return max(hash.fnv64a(mem.slice_to_bytes(keyed[:])), 1)
}

// What the picture draws: the object's buffers, the object-space box they fill (AABB_EMPTY
// without triangles) and whether its paint shows. A voxel object's are its clay's surface
// and the box around its meshed nodes; a mesh's are its current level's.
@(private = "file")
thumb_shape :: proc(obj: ^Object) -> (gpu: ^render.Mesh_Buffers, local: geom.Aabb, paint: bool) {
	local = geom.AABB_EMPTY
	if vp := obj.voxel; vp != nil {
		for c in vp.clay.surface.chunks do local = geom.aabb_union(local, c.bounds)
		return &vp.gpu, local, false
	}
	lv := sculpt.levels_current(&obj.levels)
	for c in lv.sculptor.chunks do local = geom.aabb_union(local, c.bounds)
	if len(lv.sculptor.chunks) == 0 do for p in lv.mesh.positions do geom.aabb_grow(&local, p)
	return &obj.gpu[obj.levels.current], local, sculpt.sculptor_has_color(&lv.sculptor) && !obj.paint_off
}

// The atlas cell showing `obj`, as texture coordinates, giving it one when it has none;
// ok is false while no picture of it has been drawn yet. Called by the card for each row
// it shows, which keeps those cells from going to other objects.
thumb_for :: proc(app: ^App, obj: ^Object) -> (lo, hi: [2]f32, ok: bool) {
	ts := &app.thumb_slots
	if ts.frame == 0 do ts.frame = 1
	slot := -1
	for s, i in ts.slots do if s.id == obj.id {
		slot = i
		break
	}
	if slot < 0 {
		// The cell shown longest ago, empty ones first; never one shown this frame.
		for s, i in ts.slots {
			if s.id != 0 && s.used == ts.frame do continue
			if slot < 0 || s.used < ts.slots[slot].used do slot = i
		}
		if slot < 0 do return
		ts.slots[slot] = {id = obj.id}
	}
	s := &ts.slots[slot]
	if key := thumb_key(obj); s.want != key do s.want, s.changed = key, time.tick_now()
	s.used = ts.frame
	if s.drawn == 0 do return
	lo, hi = render.thumb_uv(slot)
	return lo, hi, true
}

// Draws at most one picture on `cmd` for this frame: the first cell shown this frame that
// is out of date, once its object has settled (at once when it has no picture yet).
thumbs_frame :: proc(app: ^App, cmd: render.Cmd) {
	ts := &app.thumb_slots
	if ts.frame == 0 do ts.frame = 1
	defer ts.frame += 1
	if app.stroke.active || time.tick_since(app.view_moved) < LOD_SETTLE do return
	for &s, i in ts.slots {
		if s.id == 0 || s.used != ts.frame || s.want == s.drawn do continue
		if s.drawn != 0 && time.tick_since(s.changed) < THUMB_SETTLE do continue
		obj := object_by_id(app, s.id)
		if obj == nil {
			s = {}
			continue
		}
		gpu, local, paint := thumb_shape(obj)
		if gpu.index_count == 0 do continue
		view, proj, model := thumb_camera(obj, local)
		item := render.Draw_Item {
			mesh   = gpu,
			model  = model,
			color  = THUMB_COLOR,
			paint  = paint,
			damage = geom.AABB_EMPTY,
		}
		if render.thumbs_draw(&app.renderer, &app.thumbs, cmd, i, view, proj, item) {
			s.drawn = s.want
			ts.drawn += 1
		}
		return
	}
}

// The object turned as it is in the scene but not moved or scaled, seen from the front
// in parallel projection, fitted to its object-space box `local` with a small margin.
@(private = "file")
thumb_camera :: proc(obj: ^Object, local: geom.Aabb) -> (view, proj, model: render.Mat4) {
	model = transform_matrix({scale = 1, rotation = obj.transform.rotation})
	local := local
	if local.lo.x > local.hi.x do local = {lo = -1, hi = 1}
	world := geom.AABB_EMPTY
	for corner in 0 ..< 8 {
		p := geom.Vec3{local.hi.x if corner & 1 != 0 else local.lo.x, local.hi.y if corner & 2 != 0 else local.lo.y, local.hi.z if corner & 4 != 0 else local.lo.z}
		q := model * [4]f32{p.x, p.y, p.z, 1}
		geom.aabb_grow(&world, q.xyz)
	}
	center := (world.lo + world.hi) * 0.5
	half := (world.hi - world.lo) * 0.5
	reach := max(linalg.length(half), 1e-4)
	eye := center + geom.Vec3{0, 0, 2 * reach}
	view = camera.look_at(eye, center, {0, 1, 0})
	proj = camera.orthographic(max(half.x, half.y, 1e-4) * 1.12, 1, 0, 4 * reach)
	return
}
