package main

import "core:hash"
import "core:log"
import "core:math/linalg"
import "core:mem"
import "core:time"

import "../geom"
import "../render"
import "../sculpt"

// Smooth blend in the app (the Live stack row being built; design in
// .claude/project-memory/notes/smooth-blend/design.md): each joined object's field, its
// drawn pages and the chunk boxes the pages grow. So far one way in, `--blend-test=R`:
// on the first frame after any start-up script, every shown sculpt object is joined with every other at radius R
// (world units, full strength), projected once on the CPU (geom.blend_project) and drawn
// moved from then on, so the drawing, the seam and the culling can be looked at before
// the row exists.

// One object's part: its surface (the shown level's mesh and vertex lists, borrowed,
// with a lookup tree of its own: the sculptor's leaves hold a node of triangles each, far
// too many for closest-point queries), its field, its pages, and what the pages need of
// the drawing: per chunk how far its vertices move at most (`pads`, found once per fill
// from each touched page's box through the sculptor's tree, whose leaves are the chunks),
// likewise per simplified-copy group, and the grown boxes drawn, made again only when the
// sculptor's chunks or the pads change.
Blend_Object :: struct {
	id:        int,
	level:     ^sculpt.Level, // the level the surface borrows; the part is dropped when it changes
	vertices:  int,
	surface:   geom.Blend_Surface,
	field:     geom.Blend_Field,
	pages:     render.Blend_Pages,
	reach:     f32,
	pads:      [dynamic]f32, // per chunk; 0 where nothing moves
	lod_pads:  [dynamic]f32, // per simplified-copy group, for the tree it was found for
	lod_tree:  rawptr,       // that tree's groups, so a rebuilt tree is padded afresh
	touched:   [dynamic]geom.Aabb, // each touched page's moved vertices at rest, grown by their reach
	chunks:    [dynamic]geom.Chunk,
	groups:    [dynamic]geom.Chunk,
	lod:       [dynamic]geom.Lod_Group,
	drawn_key: u64, // what the grown boxes were made from: the layout, stamps and pads
	pads_key:  u64,
	lod_key:   u64, // the pads_key lod_pads were found for
}

Blend_State :: struct {
	objects:    [dynamic]Blend_Object,
	tested:     bool,
	// For the exit stats.
	moved:      int,
	bricks:     int,
	fill_ms:    f64,
	project_ms: f64,
	grows:      int,
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
	delete(bo.pads)
	delete(bo.lod_pads)
	delete(bo.touched)
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
		bo.surface = {mesh = lv.mesh, bvh = geom.bvh_build_morton(lv.mesh, geom.LOOKUP_LEAF, &app.pool), faces = lv.sculptor.faces, edge = geom.blend_surface_edge(lv.mesh)}
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
		log.infof("blend test: objects %d and %d want %d and %d bricks", app.blend.objects[p.a].id, app.blend.objects[p.b].id, len(want_a), len(want_b))
	}
	app.blend.fill_ms = time.duration_milliseconds(time.tick_since(t0))
	t1 := time.tick_now()
	for &bo, i in app.blend.objects {
		app.blend.bricks += len(bo.field.keys)
		moves := make([dynamic]geom.Blend_Move, context.temp_allocator)
		_ = geom.blend_project(instances[:], pairs[:], i, &moves, &app.pool)
		blend_pages_fill(app, cmd, &bo, moves[:])
		app.blend.moved += len(moves)
		log.infof("blend test: object %d moved %d vertices, the furthest by %v, through %d pages", bo.id, len(moves), bo.reach, len(bo.touched))
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
	// Each touched page's moved vertices as they rest, and how far they move at most.
	Page_Box :: struct {
		box:   geom.Aabb,
		reach: f32,
	}
	boxes := make([dynamic]Page_Box, context.temp_allocator)
	bo.reach = 0
	for m in moves {
		page := m.vertex / render.BLEND_PAGE_VERTICES
		if table[page] == render.BLEND_PAGE_NONE {
			table[page] = u32(len(entries) / render.BLEND_PAGE_VERTICES)
			resize(&entries, len(entries) + render.BLEND_PAGE_VERTICES)
			append(&boxes, Page_Box{box = geom.AABB_EMPTY})
		}
		entries[int(table[page]) * render.BLEND_PAGE_VERTICES + int(m.vertex % render.BLEND_PAGE_VERTICES)] = render.blend_entry_pack(m.offset, m.normal, m.amount, m.own)
		pb := &boxes[table[page]]
		geom.aabb_grow(&pb.box, bo.level.mesh.positions[m.vertex])
		pb.reach = max(pb.reach, linalg.length(m.offset))
		bo.reach = max(bo.reach, pb.reach)
	}
	// The chunks a moved vertex touches are those whose triangles use it, whose boxes all
	// hold its rest position: the sculptor's leaves within a touched page's box.
	s := &bo.level.sculptor
	resize(&bo.pads, len(s.chunks))
	for &p in bo.pads do p = 0
	leaves := make([dynamic]u32, context.temp_allocator)
	for pb in boxes {
		clear(&leaves)
		middle := (pb.box.lo + pb.box.hi) * 0.5
		geom.bvh_query_leaves(&s.bvh, middle, linalg.length(pb.box.hi - pb.box.lo) * 0.5, &leaves)
		for leaf in leaves {
			node := s.node_of[leaf]
			if int(node) < len(bo.pads) && box_meets(s.chunks[node].bounds, pb.box) do bo.pads[node] = max(bo.pads[node], pb.reach)
		}
	}
	bo.pads_key += 1
	padded := 0
	for p in bo.pads do if p > 0 do padded += 1
	log.infof("blend test: object %d pads %d of %d chunks", bo.id, padded, len(bo.pads))
	clear(&bo.lod_pads)
	bo.lod_tree = nil
	clear(&bo.touched)
	for pb in boxes do append(&bo.touched, geom.Aabb{pb.box.lo - pb.reach, pb.box.hi + pb.reach})
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

// Runs --blend-test once the scene is set up, then gives each item of a blended object its
// pages and boxes grown by its vertices' furthest move where they move, with cones opened
// there, so neither culling nor the simplified copies drop a moved part. The grown boxes
// are made again only when the sculptor's chunks, its simplified copies or the pads
// change. Before the live stack's copies are made: a copy draws the object without pages.
blend_draw_items :: proc(app: ^App, cmd: render.Cmd, draws: []render.Draw_Item, froms: []Item_From) {
	// Once a start-up script has set the scene up, so it blends the objects the script made.
	if app.blend_test > 0 && !app.blend.tested && !app.script.running do blend_test_run(app, cmd, app.blend_test)
	if len(app.blend.objects) == 0 do return
	for &d, i in draws {
		bo := blend_part_of(app, froms[i].obj, d)
		if bo == nil || bo.pages.table == 0 || len(bo.pads) != len(d.chunks) do continue
		d.blend = &bo.pages
		if key := drawn_key(bo, d); key != bo.drawn_key {
			blend_grow(bo, d)
			bo.drawn_key = key
			app.blend.grows += 1
		}
		d.chunks = bo.chunks[:]
		if d.chunk_groups != nil do d.chunk_groups = bo.groups[:]
		d.chunk_layout ~= BLEND_LAYOUT_MIX
		if len(d.lod.groups) > 0 {
			blend_grow_lod(bo, d.lod.groups)
			d.lod.groups = bo.lod[:]
		}
	}
}

// What the grown chunk and group boxes are made from: the chunk layout and stamps and the
// pads.
@(private = "file")
drawn_key :: proc(bo: ^Blend_Object, d: render.Draw_Item) -> u64 {
	Key :: struct {
		layout, pads, chunks: u64,
	}
	k := Key{d.chunk_layout, bo.pads_key, u64(len(d.chunks))}
	h := hash.fnv64a(mem.ptr_to_bytes(&k))
	if len(d.group_stamps) > 0 do h = hash.fnv64a(mem.slice_to_bytes(d.group_stamps), h)
	return h
}

// Makes the item's grown chunk and group boxes from the sculptor's.
@(private = "file")
blend_grow :: proc(bo: ^Blend_Object, d: render.Draw_Item) {
	resize(&bo.chunks, len(d.chunks))
	copy(bo.chunks[:], d.chunks)
	for &c, k in bo.chunks do if bo.pads[k] > 0 do open_box(&c.bounds, &c.cone_cutoff, bo.pads[k])
	resize(&bo.groups, len(d.chunk_groups))
	for &g, k in bo.groups {
		lo := k * geom.CHUNK_GROUP
		hi := min(lo + geom.CHUNK_GROUP, len(bo.chunks))
		padded := false
		for p in bo.pads[lo:hi] do padded ||= p > 0
		g = geom.chunk_group(bo.chunks[lo:hi]) if padded else d.chunk_groups[k]
	}
}

// The simplified copies' groups with the moved parts' boxes grown, every frame: the
// sculptor builds its copies a few groups a frame in place (their bounds, errors and stale
// marks change under the same tree), and the groups are few. Which groups are padded is
// found once per tree and pads: those whose box meets a touched page's.
@(private = "file")
blend_grow_lod :: proc(bo: ^Blend_Object, groups: []geom.Lod_Group) {
	if bo.lod_tree != raw_data(groups) || len(bo.lod_pads) != len(groups) || bo.lod_key != bo.pads_key {
		resize(&bo.lod_pads, len(groups))
		for g, k in groups {
			bo.lod_pads[k] = 0
			for t in bo.touched do if box_meets(g.bounds, t) {
				bo.lod_pads[k] = bo.reach
				break
			}
		}
		bo.lod_tree, bo.lod_key = raw_data(groups), bo.pads_key
	}
	resize(&bo.lod, len(groups))
	copy(bo.lod[:], groups)
	for &g, k in bo.lod do if bo.lod_pads[k] > 0 do open_box(&g.bounds, &g.cone_cutoff, bo.lod_pads[k])
}

// Grows a box by `reach` and opens its normal cone (a cutoff of 1 or more is never culled
// as facing away): what a moved part's chunk needs.
@(private = "file")
open_box :: proc(b: ^geom.Aabb, cutoff: ^f32, reach: f32) {
	b.lo -= reach
	b.hi += reach
	cutoff^ = 2
}

@(private = "file")
box_meets :: proc(a, b: geom.Aabb) -> bool {
	return a.lo.x <= b.hi.x && a.hi.x >= b.lo.x && a.lo.y <= b.hi.y && a.hi.y >= b.lo.y && a.lo.z <= b.hi.z && a.hi.z >= b.lo.z
}
