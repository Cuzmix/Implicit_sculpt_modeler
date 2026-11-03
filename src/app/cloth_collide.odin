package main

import "core:hash"
import "core:math/linalg"
import "core:slice"

import "../sculpt"

// What a cloth stroke and Physics collide with (sculpt.Cloth_Collisions): the floor at
// the bottom of the scene's box, where the floor grid stands, and every other shown mesh
// object as a signed distance volume (sculpt.cloth_volume_build). A volume is kept from
// stroke to stroke and built again only when its object changed: its place, its shown
// level or its undo history (Cloth_Volume_Kept.key), as the floor grid keeps its box.
Cloth_Volume_Kept :: struct {
	object: int,
	key:    u64,
	volume: sculpt.Cloth_Volume,
}

// The collisions for a stroke on `obj` with the cloth settings `set`, in its space. The
// volumes stay in app.cloth_volumes until the next call or the end.
cloth_collisions :: proc(app: ^App, obj: ^Object, set: sculpt.Cloth_Settings) -> (with: sculpt.Cloth_Collisions) {
	t := obj.transform
	if set.floor {
		world := floor_scene_bounds(app)
		y: f32 = -FLOOR_EMPTY_SIZE / 2 if world.lo.x > world.hi.x else world.lo.y
		with.floor, with.floor_at, with.floor_up = true, to_local(t, {0, y, 0}), to_local_dir(t, {0, 1, 0})
	}
	if !set.objects do return
	with.colliders = make([dynamic]sculpt.Cloth_Collider, context.temp_allocator)
	// Volumes of objects gone are dropped first.
	for i := len(app.cloth_volumes) - 1; i >= 0; i -= 1 {
		if object_by_id(app, app.cloth_volumes[i].object) != nil do continue
		sculpt.cloth_volume_destroy(&app.cloth_volumes[i].volume)
		ordered_remove(&app.cloth_volumes, i)
	}
	model := transform_matrix(t)
	for o in app.scene.objects {
		if o.id == obj.id || o.voxel != nil || len(o.levels.levels) == 0 || !object_shown(app, o) do continue
		key := cloth_volume_key(o)
		kept: ^Cloth_Volume_Kept
		for &k in app.cloth_volumes do if k.object == o.id do kept = &k
		if kept == nil {
			append(&app.cloth_volumes, Cloth_Volume_Kept{object = o.id})
			kept = &app.cloth_volumes[len(app.cloth_volumes) - 1]
		}
		if kept.key != key || kept.volume.dist == nil {
			kept.key = 0
			if !sculpt.cloth_volume_build(&kept.volume, sculpt.levels_current(&o.levels).mesh, &app.pool) do continue
			kept.key = key
			app.cloth_volume_builds += 1
		}
		// From the cloth's space into the other object's: the world, then back.
		to := linalg.inverse(transform_matrix(o.transform)) * model
		append(&with.colliders, sculpt.Cloth_Collider{volume = &kept.volume, to_volume = to, scale = o.transform.scale / t.scale})
	}
	return
}

// A hash of what makes an object's volume: its id, place and shown level, and where its
// undo history stands.
@(private = "file")
cloth_volume_key :: proc(o: ^Object) -> u64 {
	lv := sculpt.levels_current(&o.levels)
	h := &lv.sculptor.history
	Keyed :: struct {
		id:        int,
		transform: Transform,
		level:     int,
		vertices:  int,
		stamp:     u32,
		done:      int,
		undone:    int,
		last:      u64,
	}
	k := Keyed{o.id, o.transform, o.levels.current, len(lv.mesh.positions), h.stamp, len(h.done), len(h.undone), h.last_id}
	return max(hash.fnv64a(slice.bytes_from_ptr(&k, size_of(k))), 1)
}

cloth_volumes_destroy :: proc(app: ^App) {
	for &k in app.cloth_volumes do sculpt.cloth_volume_destroy(&k.volume)
	delete(app.cloth_volumes)
	app.cloth_volumes = nil
}
