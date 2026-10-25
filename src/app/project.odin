package main

import "core:fmt"
import "core:log"
import "core:math/linalg"
import "core:time"
import imgui "deps:odin-imgui"

import "../geom"
import "../sculpt"

// Project detail, after ZBrush's ProjectAll: the selected object's shown level takes the
// shape (and polypaint) of another object where it lies close to it. Each vertex looks
// along its normal both ways, as far as Reach, for the other object's surface, and moves
// to the nearer hit, by Strength, held back by the mask. The usual way: duplicate a
// sculpt, remesh or retopologize the copy, subdivide it a few times, and project the
// sculpt's detail back onto each level in turn from the lowest up.

Project_Settings :: struct {
	source:   int, // id of the object to project from; 0 for none chosen
	reach:    f32, // how far each vertex looks, over the target's size
	strength: f32,
	paint:    bool, // bring the source's polypaint too, when it has some
	// Where the objects sit in the scene matters; otherwise each is read in its own space,
	// as baking does, so a copy made by Duplicate or Retopologize (put beside the
	// original) projects as if it were on top of it.
	as_placed: bool,
}

PROJECT_DEFAULTS :: Project_Settings{reach = 0.03, strength = 1, paint = true}

// Projects `src`'s shown level onto the shown level of `obj`, as one undo step.
project_detail :: proc(app: ^App, obj, src: ^Object) {
	stroke_finish(app)
	if obj == nil || src == nil || obj == src do return
	object_hd_leave(app, obj)
	object_hd_leave(app, src)
	if object_dynamic(obj) {
		log.warn("project detail: turn dynamic topology off on the target first")
		return
	}
	settings := app.ui.project
	start := time.tick_now()
	view, packed := object_shape(src, top = false)
	defer {
		delete(view.normals)
		geom.mesh_destroy(&packed)
	}
	bvh := geom.bvh_build_morton(view, geom.BVH_LEAF_SIZE, &app.pool)
	defer geom.bvh_destroy(&bvh)

	// The target's vertices and normals in the source's space.
	m := object_mesh(obj)
	from, to := obj.transform, src.transform
	if !settings.as_placed do from, to = {scale = 1}, {scale = 1}
	count := len(m.positions)
	points := make([]geom.Vec3, count)
	defer delete(points)
	normals := make([]geom.Vec3, count)
	defer delete(normals)
	bounds := geom.AABB_EMPTY
	for p, v in m.positions {
		geom.aabb_grow(&bounds, p)
		points[v] = to_local(to, to_world(from, p))
		normals[v] = linalg.normalize0(to_local_dir(to, to_world_dir(from, m.normals[v])))
	}
	extent := bounds.hi - bounds.lo
	reach := settings.reach * max(extent.x, extent.y, extent.z) * from.scale / to.scale
	next := make([]geom.Vec3, count)
	defer delete(next)
	tris := make([]u32, count)
	defer delete(tris)
	hits := geom.project_along_normals(points, normals, view, &bvh, reach, &app.pool, next, tris)

	// The colour where each vertex lands, from the corners of the triangle it lands on.
	colors: []sculpt.Color
	defer delete(colors)
	source_colors := object_sculptor(src).color
	if settings.paint && !object_dynamic(src) && source_colors != nil {
		colors = make([]sculpt.Color, count)
		own := object_sculptor(obj).color
		for v in 0 ..< count {
			tri := tris[v]
			if tri == max(u32) {
				colors[v] = own[v] if own != nil else {}
				continue
			}
			c := [3]u32{view.indices[3 * tri], view.indices[3 * tri + 1], view.indices[3 * tri + 2]}
			w := barycentric(next[v], view.positions[c[0]], view.positions[c[1]], view.positions[c[2]])
			sum: [4]f32
			for k in 0 ..< 3 do sum += w[k] * linalg.array_cast(source_colors[c[k]], f32)
			colors[v] = linalg.array_cast(linalg.clamp(sum + 0.5, 0, 255), u8)
		}
	}
	for &p in next do p = to_local(from, to_world(to, p))
	changed := sculpt.sculptor_project(object_sculptor(obj), next, colors, settings.strength)
	free_all(context.temp_allocator)
	ms := time.duration_milliseconds(time.tick_since(start))
	app.ui.project_last = {hit = 100 * f64(hits) / f64(max(count, 1)), ms = ms, set = true}
	log.infof("project detail: %s onto %s, %d of %d vertices found the surface, in %.0f ms", object_label(src), object_label(obj), hits, count, ms)
	if changed do history_record(app, obj, .Deform, "Project detail")
}

// The weights of `p` (on the triangle's plane) at the corners a, b and c.
@(private = "file")
barycentric :: proc(p, a, b, c: geom.Vec3) -> [3]f32 {
	e1, e2, d := b - a, c - a, p - a
	d11, d12, d22 := linalg.dot(e1, e1), linalg.dot(e1, e2), linalg.dot(e2, e2)
	d1, d2 := linalg.dot(d, e1), linalg.dot(d, e2)
	den := d11 * d22 - d12 * d12
	if abs(den) < 1e-20 do return {1, 0, 0}
	v := clamp((d22 * d1 - d12 * d2) / den, 0, 1)
	w := clamp((d11 * d2 - d12 * d1) / den, 0, 1 - v)
	return {1 - v - w, v, w}
}

draw_project_section :: proc(app: ^App) {
	p := &app.ui.project
	imgui.SeparatorText("Project detail")
	obj := selected_object(app)
	src := object_by_id(app, p.source)
	if src == obj do src = nil
	imgui.SetNextItemWidth(160)
	if imgui.BeginCombo("Project from", fmt.ctprintf("%s", object_label(src) if src != nil else "(choose)")) {
		for other in app.scene.objects {
			if other == obj do continue
			if imgui.Selectable(fmt.ctprintf("%s##%d", object_label(other), other.id), other == src) do p.source = other.id
		}
		imgui.EndCombo()
	}
	imgui.SetNextItemWidth(110)
	imgui.SliderFloat("Reach##project", &p.reach, 0.002, 0.3, "%.3f", {.Logarithmic})
	imgui.SameLine()
	imgui.SetNextItemWidth(90)
	imgui.SliderFloat("Strength##project", &p.strength, 0, 1, "%.2f")
	imgui.Checkbox("Polypaint too", &p.paint)
	imgui.SameLine()
	imgui.Checkbox("As placed", &p.as_placed)
	if imgui.IsItemHovered() do imgui.SetTooltip("Use where the two objects sit in the scene. Off, each is\nread in its own space, so a duplicate or retopologized copy\nput beside the original projects as if on top of it.")
	imgui.BeginDisabled(obj == nil || src == nil)
	if imgui.Button("Project detail") do project_detail(app, obj, src)
	imgui.EndDisabled()
	if l := app.ui.project_last; l.set {
		imgui.TextDisabled("Last: %.1f%% of vertices found the surface, %.0f ms", l.hit, l.ms)
	}
	imgui.TextDisabled("Moves the selected object's shown level onto the\nother object along its normals, where it is within\nReach (a share of its size). For a remeshed copy:\nsubdivide it and project at each level, lowest first.")
}
