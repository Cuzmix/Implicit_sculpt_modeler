package main

import "core:math/linalg"
import "core:time"

import "../geom"
import "../render"
import "../sculpt"

// Smooth blend in the app (the Live stack row being built; design in
// .claude/project-memory/notes/smooth-blend/design.md): each joined object's field, its
// drawn pages and the chunk boxes the pages grow. So far one way in, `--blend-test=R`:
// on the first frame, every shown sculpt object is joined with every other at radius R
// (world units, full strength), projected once on the CPU (geom.blend_project) and drawn
// moved from then on, so the drawing, the seam and the culling can be looked at before
// the row exists.

// One object's part: its surface (the shown level's mesh and vertex lists, borrowed,
// with a lookup tree of its own: the sculptor's leaves hold a node of triangles each, far
// too many for closest-point queries), its field, its pages, and what the pages need of
// the drawing: the box of the moved vertices as they rest and the furthest move, from
// which each frame's chunk, group and simplified-copy boxes are grown.
Blend_Object :: struct {
	id:       int,
	level:    ^sculpt.Level, // the level the surface borrows; the part is dropped when it changes
	vertices: int,
	surface:  geom.Blend_Surface,
	field:    geom.Blend_Field,
	pages:    render.Blend_Pages,
	region:   geom.Aabb,
	reach:    f32,
	chunks:   [dynamic]geom.Chunk,
	groups:   [dynamic]geom.Chunk,
	lod:      [dynamic]geom.Lod_Group,
}

Blend_State :: struct {
	objects:    [dynamic]Blend_Object,
	tested:     bool,
	// For the exit stats.
	moved:      int,
	bricks:     int,
	fill_ms:    f64,
	project_ms: f64,
}

// A chunk layout no sculptor gives, mixed into a blended item's: the GPU's copy of its
// chunks then takes the grown boxes whole once, and later only the groups a stroke stamps.
@(private = "file")
BLEND_LAYOUT_MIX :: u64(0x5bd1e9955bd1e995)

blend_destroy :: proc(app: ^App) {
	for &bo in app.blend.objects do blend_object_free(&bo)
	delete(app.blend.objects)
	app.blend.objects = {}
}

@(private = "file")
blend_object_free :: proc(bo: ^Blend_Object) {
	geom.bvh_destroy(&bo.surface.bvh)
	geom.blend_field_destroy(&bo.field)
	render.blend_pages_destroy(&bo.pages)
	delete(bo.chunks)
	delete(bo.groups)
	delete(bo.lod)
}

// Whether an object can take part: a shown sculpt mesh, no cage or clay, no dynamic
// topology (its vertices move between pages as it splits) and no HD window (drawn apart).
@(private = "file")
blend_fits :: proc(app: ^App, obj: ^Object) -> bool {
	if !object_shown(app, obj) || obj.voxel != nil || obj.cage != nil do return false
	if obj.levels.hd.window != nil do return false
	lv := sculpt.levels_current(&obj.levels)
	return lv.sculptor.dyn == nil && len(lv.mesh.positions) > 0
}

// --blend-test: joins every shown sculpt object with every other at `radius` and fills
// their pages, once. Logs what it did; the exit stats say it again.
@(private = "file")
blend_test_run :: proc(app: ^App, cmd: render.Cmd, radius: f32) {
	app.blend.tested = true
	instances := make([dynamic]geom.Blend_Instance, context.temp_allocator)
	for obj in app.scene.objects {
		if !blend_fits(app, obj) do continue
		lv := sculpt.levels_current(&obj.levels)
		scale := max(obj.transform.scale, 1e-6)
		h := geom.blend_spacing(radius / scale)
		append(&app.blend.objects, Blend_Object{id = obj.id, level = lv, vertices = len(lv.mesh.positions)})
		bo := &app.blend.objects[len(app.blend.objects) - 1]
		bo.surface = {mesh = lv.mesh, bvh = geom.bvh_build_morton(lv.mesh, geom.LOOKUP_LEAF, &app.pool), faces = lv.sculptor.faces}
		geom.blend_field_init(&bo.field, h, geom.blend_band(h, radius / scale))
	}
	// The instances point into the objects, which no longer move in memory.
	for &bo in app.blend.objects {
		obj := object_by_id(app, bo.id)
		append(&instances, geom.Blend_Instance{surface = &bo.surface, field = &bo.field, place = transform_matrix(obj.transform), scale = max(obj.transform.scale, 1e-6), id = u32(obj.id)})
	}
	pairs := make([dynamic]geom.Blend_Pair, context.temp_allocator)
	for i in 0 ..< len(instances) do for j in i + 1 ..< len(instances) do append(&pairs, geom.Blend_Pair{a = i, b = j, radius = radius, strength = 1})
	t0 := time.tick_now()
	for p in pairs {
		want_a := make([dynamic]u64, context.temp_allocator)
		want_b := make([dynamic]u64, context.temp_allocator)
		geom.blend_pair_bricks(instances[:], p, &want_a, &want_b, &app.pool)
		geom.blend_field_fill(&app.blend.objects[p.a].field, &app.blend.objects[p.a].surface, want_a[:], &app.pool)
		geom.blend_field_fill(&app.blend.objects[p.b].field, &app.blend.objects[p.b].surface, want_b[:], &app.pool)
	}
	app.blend.fill_ms = time.duration_milliseconds(time.tick_since(t0))
	t1 := time.tick_now()
	for &bo, i in app.blend.objects {
		app.blend.bricks += len(bo.field.keys)
		moves := make([dynamic]geom.Blend_Move, context.temp_allocator)
		_ = geom.blend_project(instances[:], pairs[:], i, &moves, &app.pool)
		blend_pages_fill(app, cmd, &bo, moves[:])
		app.blend.moved += len(moves)
	}
	app.blend.project_ms = time.duration_milliseconds(time.tick_since(t1))
	render.viewport_invalidate(&app.target)
}

// Lays an object's moves into pages of render.BLEND_PAGE_VERTICES vertices, in vertex
// order, notes the box they rest in and the furthest move, and uploads them.
@(private = "file")
blend_pages_fill :: proc(app: ^App, cmd: render.Cmd, bo: ^Blend_Object, moves: []geom.Blend_Move) {
	table := make([]u32, (bo.vertices + render.BLEND_PAGE_VERTICES - 1) / render.BLEND_PAGE_VERTICES, context.temp_allocator)
	for &w in table do w = render.BLEND_PAGE_NONE
	entries := make([dynamic]render.Blend_Entry, context.temp_allocator)
	bo.region, bo.reach = geom.AABB_EMPTY, 0
	for m in moves {
		page := m.vertex / render.BLEND_PAGE_VERTICES
		if table[page] == render.BLEND_PAGE_NONE {
			table[page] = u32(len(entries) / render.BLEND_PAGE_VERTICES)
			resize(&entries, len(entries) + render.BLEND_PAGE_VERTICES)
		}
		entries[int(table[page]) * render.BLEND_PAGE_VERTICES + int(m.vertex % render.BLEND_PAGE_VERTICES)] = render.blend_entry_pack(m.offset, m.normal, m.amount, m.own)
		geom.aabb_grow(&bo.region, bo.level.mesh.positions[m.vertex])
		bo.reach = max(bo.reach, linalg.length(m.offset))
	}
	if len(moves) == 0 {
		render.blend_pages_destroy(&bo.pages)
		return
	}
	_ = render.blend_pages_set(&app.renderer, cmd, &bo.pages, table, entries[:])
}

// The part of the object `obj` an item draws, or nil: an item of its shown level (not
// the HD window's, the boolean preview's or a copy's) whose level is still the one the
// part was made from.
@(private = "file")
blend_part_of :: proc(app: ^App, obj: ^Object, item: render.Draw_Item) -> ^Blend_Object {
	if obj == nil || item.copy != 0 do return nil
	for &bo in app.blend.objects {
		if bo.id != obj.id do continue
		lv := sculpt.levels_current(&obj.levels)
		if lv != bo.level || len(lv.mesh.positions) != bo.vertices || item.source != &lv.mesh do return nil
		return &bo
	}
	return nil
}

// Runs --blend-test on its first frame, then gives each item of a blended object its
// pages and boxes grown by the furthest move wherever they meet the moved region, with
// cones opened there, so neither culling nor the simplified copies drop a moved part.
// Before the live stack's copies are made: a copy draws the object without pages.
blend_draw_items :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item, froms: []Item_From) {
	if app.blend_test > 0 && !app.blend.tested do blend_test_run(app, cmd, app.blend_test)
	if len(app.blend.objects) == 0 do return
	for &d, i in draws {
		bo := blend_part_of(app, froms[i].obj, d)
		if bo == nil || bo.pages.table == 0 do continue
		d.blend = &bo.pages
		zone := geom.Aabb{bo.region.lo - bo.reach, bo.region.hi + bo.reach}
		resize(&bo.chunks, len(d.chunks))
		copy(bo.chunks[:], d.chunks)
		for &c in bo.chunks do grow_box(&c.bounds, &c.cone_cutoff, zone, bo.reach)
		d.chunks = bo.chunks[:]
		if d.chunk_groups != nil {
			resize(&bo.groups, len(d.chunk_groups))
			for &g, k in bo.groups {
				lo := k * geom.CHUNK_GROUP
				g = geom.chunk_group(bo.chunks[lo:min(lo + geom.CHUNK_GROUP, len(bo.chunks))])
			}
			d.chunk_groups = bo.groups[:]
		}
		d.chunk_layout ~= BLEND_LAYOUT_MIX
		if len(d.lod.groups) > 0 {
			resize(&bo.lod, len(d.lod.groups))
			copy(bo.lod[:], d.lod.groups)
			for &g in bo.lod do grow_box(&g.bounds, &g.cone_cutoff, zone, bo.reach)
			d.lod.groups = bo.lod[:]
		}
	}
}

// Grows a box by `reach` and opens its normal cone (a cutoff of 1 or more is never culled
// as facing away) when it meets `zone`.
@(private = "file")
grow_box :: proc(b: ^geom.Aabb, cutoff: ^f32, zone: geom.Aabb, reach: f32) {
	if b.hi.x < zone.lo.x || b.lo.x > zone.hi.x || b.hi.y < zone.lo.y || b.lo.y > zone.hi.y || b.hi.z < zone.lo.z || b.lo.z > zone.hi.z do return
	b.lo -= reach
	b.hi += reach
	cutoff^ = 2
}
