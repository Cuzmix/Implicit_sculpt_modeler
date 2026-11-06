package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:time"

import "../geom"
import "../poly"
import "../render"
import "../sculpt"
import "../ui"

// Model mode's objects: a polygon cage (the poly package) edited with the Model tool, as
// ZBrush's ZModeler edits a PolyMesh. A cage object is a mesh object whose one level is
// the cage cut into triangles, so everything that reads a level (drawing, culling,
// picking, thumbnails, export, booleans, --check-mesh) keeps working on what is drawn;
// the cage itself rides beside it in Object.cage, with maps from the level back to it.
//
// The level is never sculpted: brushes, masks, paint and anything else that changes the
// level in place refuse a cage object (object_editable, CAGE_REFUSED_COMMANDS), since the
// level is made again from the cage after every edit. Tools that rebuild the object from
// its surface (remesh, decimate, mirror and weld, slice, repair, booleans, voxels) drop
// the cage through object_release_mesh, which is what they mean: the result is a mesh of
// the drawn surface. Apply to sculpt does that on purpose.

Cage_Part :: struct {
	mesh:    poly.Mesh,
	look:    Cage_Look,
	// The live stack's mesh, which Smooth and Flat start from in the cage's place, and how
	// the cage maps onto it (poly.Live_Mesh); empty with the stack off. `creased` is which
	// cage edges were creased when it was made, which Bevel creases made strips of.
	live:    poly.Live_Mesh,
	creased: []bool,
	// The cage (or the live mesh) made finer for drawing (none at Smooth 0), whose points
	// start with its own.
	sub:     poly.Subdivision,
	// Per point of the drawn cage (the finest), its vertex in the level, which the
	// sculptor numbers in its own order; per triangle of the level, the cage face it lies in.
	vert_of: []u32,
	face_of: []u32,
	// A cage taken from a sculpt with levels (Edit cage) holds the sculpt's levels as
	// sculpt.levels_write wrote them, so Apply to sculpt can put its detail back; empty
	// for any other cage.
	held:    []u8,
	// The Wrap row's search tree over its object's surface and what it was made from
	// (cage_follow.odin), and the stamp of everything the follow rows read when the cage
	// was last worked out.
	wrap_bvh:     geom.Bvh,
	wrap_made:    bool,
	wrap_stamp:   u64,
	follow_stamp: u64,
	// Sharp edges' copies of drawn points (geom.mesh_split_sharp): per copy, the drawn
	// point it stands for. The level's vertices for them follow vert_of's, after the
	// drawn points'.
	dup_from:     []u32,
}

// How a cage is drawn, as ZBrush's Dynamic Subdivision and Blender's Subdivision Surface
// and modifiers set it: the live stack first (a shell's Thickness, Bevel creases), then
// Smooth steps of Catmull-Clark (0 to poly.SUBDIVIDE_MAX), or with Flat the faces only
// split, for hard surfaces. Saved with the cage and undone with it.
Cage_Look :: struct {
	smooth: int,
	flat:   bool,
	live:   poly.Live,
	follow: Cage_Follow, // the rows that follow other objects: Curve and Wrap
	sharp:  f32, // Sharp edges: the angle in degrees past which edges shade hard; 0 for off
}

// `look` kept to what can be drawn: steps and segments in range, widths finite and not
// below 0.
cage_look_clean :: proc(look: Cage_Look) -> Cage_Look {
	l := look.live
	size :: proc(x: f32) -> f32 {return x if x > 0 && x < 1e6 else 0}
	turn: f32 = poly.LIVE_DEFORM_TURN_MAX if l.deform != .Taper else poly.LIVE_TAPER_MAX
	return {
		clamp(look.smooth, 0, poly.SUBDIVIDE_MAX),
		look.flat,
		{
			mirror = l.mirror & {.X, .Y, .Z},
			thickness = size(l.thickness),
			thickness_segments = clamp(l.thickness_segments, 1, poly.LIVE_THICKNESS_SEGMENTS_MAX),
			side = l.side,
			bevel = size(l.bevel),
			bevel_segments = clamp(l.bevel_segments, 1, poly.BEVEL_SEGMENTS_MAX),
			deform = l.deform,
			deform_axis = l.deform_axis,
			deform_amount = clamp(l.deform_amount, -turn, turn) if abs(l.deform_amount) < 1e6 else 0,
			displace = clamp(l.displace, -1e6, 1e6) if l.displace == l.displace else 0,
			displace_scale = size(l.displace_scale),
		},
		{
			curve = max(look.follow.curve, 0),
			curve_axis = look.follow.curve_axis,
			curve_fit = look.follow.curve_fit,
			wrap = max(look.follow.wrap, 0),
			wrap_offset = clamp(look.follow.wrap_offset, -1e6, 1e6) if look.follow.wrap_offset == look.follow.wrap_offset else 0,
		},
		clamp(look.sharp, 0, CAGE_SHARP_MAX) if look.sharp == look.sharp else 0,
	}
}

// What Smooth and Flat start from: the live stack's mesh, or the cage.
cage_base :: proc(cp: ^Cage_Part) -> ^poly.Mesh {return &cp.live.mesh if cp.live.vert_first != nil else &cp.mesh}

// The cage as drawn: the finest step, or what it starts from.
cage_drawn :: proc(cp: ^Cage_Part) -> ^poly.Mesh {return poly.subdivision_top(&cp.sub, cage_base(cp))}

// Where cage point v shows: on the drawn surface (its point there). Under the live stack,
// its live point's, or where Bevel creases replaced it, the middle of those that took its
// place.
cage_point :: proc(cp: ^Cage_Part, v: u32) -> Vec3 {
	drawn := cage_drawn(cp)
	if cp.live.vert_first == nil do return drawn.positions[v]
	ids := cp.live.vert_ids[cp.live.vert_first[v]:cp.live.vert_first[v + 1]]
	if len(ids) == 0 do return cp.mesh.positions[v]
	sum: Vec3
	for id in ids do sum += drawn.positions[id]
	return sum / f32(len(ids))
}

// Where cage face f's middle shows: its face point on the drawn surface, which every step
// keeps, or its corners' mean when not smoothed. The live stack keeps the cage's faces
// first, in order.
cage_face_center :: proc(cp: ^Cage_Part, f: u32) -> Vec3 {
	base := cage_base(cp)
	if len(cp.sub.steps) == 0 do return poly.face_center(base, f)
	return cage_drawn(cp).positions[len(base.positions) + len(base.crease) + int(f)]
}

// The drawn points cage edge e shows along, from its first end to its other (temp
// memory), or false for an edge Bevel creases made a strip of.
cage_edge_line :: proc(cp: ^Cage_Part, e: u32) -> ([]u32, bool) {
	h := 2 * e
	if cp.live.vert_first != nil do h = cp.live.edge[e]
	if h == poly.NONE do return nil, false
	n := cp.sub.line_points
	line := cp.sub.edge_line[int(poly.edge_of(h)) * n:][:n]
	if h & 1 == 0 do return line, true
	back := make([]u32, n, context.temp_allocator)
	for v, i in line do back[n - 1 - i] = v
	return back, true
}

// The points cage edge e shows along, from its first end to its other, into `out`
// (cleared first): on the drawn surface, so a smoothed cage's edges follow its curves; a
// strip's edge straight between its ends' points.
cage_edge_points :: proc(cp: ^Cage_Part, e: u32, out: ^[dynamic]Vec3) {
	clear(out)
	line, ok := cage_edge_line(cp, e)
	if !ok {
		a, b := poly.edge_verts(&cp.mesh, e)
		append(out, cage_point(cp, a), cage_point(cp, b))
		return
	}
	drawn := cage_drawn(cp)
	for v in line do append(out, drawn.positions[v])
}

// Frees the object's cage, if it has one. Its GPU edges go with the level's buffers.
cage_part_free :: proc(obj: ^Object) {
	cp := obj.cage
	if cp == nil do return
	cage_free_part(cp)
	obj.cage = nil
}

// Makes `cage` (taken, also on failure) the object's cage, drawn as `look` says: the
// level cut from it (made finer first by Smooth), its polygroups on the level's
// triangles, the upload and the cage's edges as lines. The object has no level yet.
// `held` (taken too) is the sculpt the cage was taken from (Cage_Part.held). Returns
// false on a GPU failure, with nothing of the object made.
object_build_cage :: proc(app: ^App, obj: ^Object, cage: poly.Mesh, look := Cage_Look{}, held: []u8 = nil) -> bool {
	start := time.tick_now()
	cp := new(Cage_Part)
	cp.mesh = cage
	cp.held = held
	cp.look = cage_look_clean(look)
	cage_live_make(app, obj, cp)
	// A valid cage always subdivides; were one refused, it is drawn as it is.
	sub, sub_err := poly.subdivide(cage_base(cp), cp.look.smooth, cp.look.flat)
	if sub_err != .None {
		sub, _ = poly.subdivide(cage_base(cp), 0)
		cp.look.smooth = 0
	}
	cp.sub = sub
	cage_drawn_finish(app, obj, cp)
	drawn := cage_drawn(cp)
	mesh := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	poly.triangulate(drawn, &mesh, &tri_face, fixed = len(cp.sub.steps) > 0)
	resize(&mesh.normals, len(mesh.positions))
	// Sharp edges: the drawn points split where faces meet past the angle, so the level
	// shades those edges hard and exports carry the split normals.
	if cp.look.sharp > 0 do cp.dup_from = geom.mesh_split_sharp(&mesh, cp.look.sharp)
	// The triangles' groups are their faces', on the heap: building frees temp memory.
	groups := make([]u16, len(tri_face))
	defer delete(groups)
	for f, t in tri_face do groups[t] = drawn.group[f]
	cp.vert_of = make([]u32, len(mesh.positions))
	tri_from := make([]u32, len(tri_face))
	defer delete(tri_from)
	if !object_build_from(app, obj, mesh, start, normals = true, old_to_new = cp.vert_of, surface = {groups = groups}, tri_from = tri_from) {
		cage_free_part(cp)
		return false
	}
	cp.face_of = make([]u32, len(tri_from))
	for old, t in tri_from {
		f := cp.sub.face_from[tri_face[old]]
		cp.face_of[t] = cp.live.face_from[f] if cp.live.vert_first != nil else f
	}
	obj.cage = cp
	cp.follow_stamp = cage_follow_stamp(app, obj)
	if !cage_upload_edges(app, obj) {
		object_release_mesh(app, obj, rebuild = false)
		return false
	}
	return true
}

// Makes the live stack's mesh for the cage part's look, or none with the stack off; a
// stack that cannot be built (which a valid cage never gives) is turned off.
@(private = "file")
cage_live_make :: proc(app: ^App, obj: ^Object, cp: ^Cage_Part) {
	poly.live_mesh_destroy(&cp.live)
	delete(cp.creased)
	cp.creased = nil
	if !cage_live_wanted(cp.look) do return
	lm, err := poly.live_build(&cp.mesh, cp.look.live)
	if err != .None {
		cp.look.live = {}
		cp.look.follow = {}
		return
	}
	cp.live = lm
	cp.creased = make([]bool, len(cp.mesh.crease))
	for c, e in cp.mesh.crease do cp.creased[e] = c > 0
}

// Whether the cage is drawn through a live mesh: a row of the stack, or a follow row.
cage_live_wanted :: proc(look: Cage_Look) -> bool {return poly.live_on(look.live) || cage_follow_on(look.follow)}

// The drawn surface's last steps, on its finest step (or the live mesh with Smooth off)
// just made again from the cage: along its curve, onto its object, then Displace, each
// on the smoothed points so a bend is smooth, a wrap hugs closely and the noise has the
// points to show in.
@(private = "file")
cage_drawn_finish :: proc(app: ^App, obj: ^Object, cp: ^Cage_Part) {
	if cp.live.vert_first == nil do return
	cage_follow_curve_apply(app, obj, cp, cage_drawn(cp))
	cage_follow_wrap_apply(app, obj, cp, cage_drawn(cp))
	l := cp.look.live
	if l.displace != 0 do poly.live_displace(cage_drawn(cp), l.displace, l.displace_scale)
}

// Sends the cage's vertices `verts` (cage ids), moved without a change of topology, to
// the level: its positions, bounds and normals, and the GPU at the next flush. A smoothed
// cage's finer points, or the live stack's, are worked out again and every one sent,
// since each cage point pulls on the surface round it. Returns false only on a GPU
// failure.
cage_positions_moved :: proc(app: ^App, obj: ^Object, verts: []u32) -> bool {
	cp := obj.cage
	moved := verts
	live := cp.live.vert_first != nil
	// The stack made again matches unless the topology changed, which a move never does;
	// were it not to, the level is made again.
	if live && !poly.live_update(&cp.mesh, cp.look.live, &cp.live) do return cage_rebuild(app, obj)
	cp.follow_stamp = cage_follow_stamp(app, obj)
	if live || len(cp.sub.steps) > 0 {
		poly.subdivision_update(&cp.sub, cage_base(cp), cp.look.flat)
		cage_drawn_finish(app, obj, cp)
		moved = make([]u32, len(cp.vert_of) - len(cp.dup_from), context.temp_allocator)
		for &v, i in moved do v = u32(i)
	}
	drawn := cage_drawn(cp)
	level := make([dynamic]u32, 0, len(moved), context.temp_allocator)
	positions := make([dynamic]Vec3, 0, len(moved), context.temp_allocator)
	for v in moved {
		append(&level, cp.vert_of[v])
		append(&positions, drawn.positions[v])
	}
	// Sharp edges' copies go with the points they stand for.
	if len(cp.dup_from) > 0 {
		first := len(cp.vert_of) - len(cp.dup_from)
		going := make([]bool, first, context.temp_allocator)
		for v in moved do going[v] = true
		for src, k in cp.dup_from do if going[src] {
			append(&level, cp.vert_of[first + k])
			append(&positions, drawn.positions[src])
		}
	}
	sculpt.sculptor_place_vertices(object_sculptor(obj), level[:], positions[:])
	return true
}

// Works the drawn surface out again after creases or corners changed, which the finer
// cages and the live stack take when they are made, and sends every point to the level.
// The topology is the same, so the level and its edges stay, unless Bevel creases has an
// edge to round, or no longer one, when the level is made again. Returns false only on a
// GPU failure.
cage_sharpness_changed :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.cage
	if cp.live.vert_first != nil {
		if cp.look.live.bevel > 0 {
			for c, e in cp.mesh.crease do if (c > 0) != cp.creased[e] do return cage_rebuild(app, obj)
		}
		lm, err := poly.live_build(&cp.mesh, cp.look.live)
		if err != .None do return cage_rebuild(app, obj)
		poly.live_mesh_destroy(&cp.live)
		cp.live = lm
	} else if len(cp.sub.steps) == 0 {
		return true
	}
	sub, err := poly.subdivide(cage_base(cp), cp.look.smooth, cp.look.flat)
	// The same cage subdivided before, so it does again.
	if err != .None do return true
	poly.subdivision_destroy(&cp.sub)
	cp.sub = sub
	return cage_positions_moved(app, obj, nil)
}

@(private = "file")
cage_free_part :: proc(cp: ^Cage_Part) {
	poly.mesh_destroy(&cp.mesh)
	poly.live_mesh_destroy(&cp.live)
	delete(cp.creased)
	poly.subdivision_destroy(&cp.sub)
	delete(cp.vert_of)
	delete(cp.face_of)
	delete(cp.held)
	delete(cp.dup_from)
	if cp.wrap_made do geom.bvh_destroy(&cp.wrap_bvh)
	free(cp)
}

// Sends the cage's edges, as pairs of the level's vertices, to the level's buffers: each
// edge along its line over the drawn surface.
cage_upload_edges :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.cage
	pieces := cp.sub.line_points - 1
	pairs := make([dynamic]u32, 0, 2 * pieces * len(cp.mesh.crease), context.temp_allocator)
	for e in 0 ..< u32(len(cp.mesh.crease)) {
		// An edge Bevel creases made a strip of shows as the strip.
		line := cage_edge_line(cp, e) or_continue
		for i in 0 ..< pieces do append(&pairs, cp.vert_of[line[i]], cp.vert_of[line[i + 1]])
	}
	return render.mesh_buffers_set_edges(&app.renderer, &obj.gpu[0], pairs[:])
}

// Builds the level again from the object's cage after an edit changed it: the strokes,
// buffers and level go and are made anew, keeping the object's place, name, material and
// cage. Returns false on a GPU failure, with the object left without a level for the
// caller to drop.
cage_rebuild :: proc(app: ^App, obj: ^Object) -> bool {
	assert(obj.cage != nil)
	// The autosave thread may be writing the object out; it finishes first.
	autosave_settle(app)
	cage, look, held := obj.cage.mesh, obj.cage.look, obj.cage.held
	obj.cage.mesh, obj.cage.held = {}, nil
	object_release_mesh(app, obj, rebuild = false)
	return object_build_cage(app, obj, cage, look, held)
}

// Adds primitive `kind` as a new cage object, named after it, where the next object goes,
// and selects it. Returns false only on a GPU failure.
scene_add_cage :: proc(app: ^App, kind: poly.Primitive, opts: poly.Primitive_Options, t: Transform) -> bool {
	obj := new(Object)
	obj.transform, obj.file = t, {scale = 1}
	if !object_build_cage(app, obj, poly.primitive(kind, opts)) {
		free(obj)
		return false
	}
	obj.name = fmt.aprintf("%s %d", poly.PRIMITIVE_NAMES[kind], app.scene.next_id + 1)
	scene_append(app, obj)
	c := poly.mesh_check(&obj.cage.mesh)
	log.infof("%s: a cage of %d points, %d edges, %d faces (%d quads)", object_label(obj), c.vertices, c.edges, c.faces, c.quads)
	return true
}

// Apply to sculpt: the cage goes and the object becomes an ordinary mesh, which every
// brush can then sculpt. A closed cage drawn Smooth or Flat becomes subdivision levels as
// ZBrush's Dynamic Subdivision's Apply does: the cage's polygons cut into triangles as the
// base, with the same number of Catmull-Clark levels above it, their creases kept, so the
// top level shows what the cage showed, and each polygon keeps its polygroup (an all-quad
// cage keeps its quads too, for export and UVs); at Smooth 0 that is the one level, whose
// Subdivide then makes Catmull-Clark levels. The live stack is baked in: the levels are
// made from its mesh. A cage Edit cage took from a sculpt gets that sculpt's levels back,
// with its detail riding on the edited cage. An open cage keeps the level it was drawn
// with. Returns whether it had a cage to drop.
object_apply_cage :: proc(app: ^App, obj: ^Object) -> bool {
	if obj.cage == nil do return false
	autosave_settle(app)
	cp := obj.cage
	steps := cp.look.smooth
	rule := sculpt.Subdivision_Rule.Flat if cp.look.flat else .Smooth
	// Displace drawn after Smooth goes onto the finest level, as detail; with Smooth off it
	// is already in the live mesh the levels start from.
	displace, displace_scale := cp.look.live.displace, cp.look.live.displace_scale
	if len(cp.sub.steps) == 0 || cp.live.vert_first == nil do displace = 0
	// The sculpt the cage was taken from, whose levels come back.
	held: sculpt.Levels
	have := false
	defer if have do sculpt.levels_destroy(&held)
	if len(cp.held) > 0 {
		r := geom.byte_reader(cp.held)
		have = sculpt.levels_read(&held, &r, &app.pool)
		if have do steps = len(held.levels) - 1
		else do report(app, nil, {.Warning}, "%s's held sculpt could not be read, so its detail is not put back", object_label(obj))
	}
	// The levels are made from what Smooth starts from: the live stack's mesh (a shell, its
	// creases bevelled), or the cage.
	base := cage_base(cp)
	if poly.mesh_check(base).border_edges > 0 {
		if steps > 0 do report(app, nil, {}, "%s has open edges, so it became one level as drawn: close its holes first for subdivision levels", object_label(obj))
		if len(cp.dup_from) > 0 {
			// Sharp edges' copies would leave the sculpt torn along its hard edges, so
			// they are welded back first; each triangle keeps its face's polygroup.
			level := object_mesh(obj)
			groups := make([]u16, len(level.indices) / 3)
			defer delete(groups)
			for f, t in cp.face_of do groups[t] = cp.mesh.group[f]
			welded := cage_export_welded(cp, level)
			start := time.tick_now()
			object_release_mesh(app, obj, rebuild = false)
			cage_part_free(obj)
			return object_build_from(app, obj, welded, start, normals = true, surface = {groups = groups})
		}
		_ = render.mesh_buffers_set_edges(&app.renderer, &obj.gpu[0], nil)
		cage_part_free(obj)
		return true
	}
	start := time.tick_now()
	// It outlives the object's rebuild, which frees the part, on the heap.
	cage := base^
	base^ = {}
	defer poly.mesh_destroy(&cage)
	mesh := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	tri_face := make([dynamic]u32)
	defer delete(tri_face)
	poly.triangulate(&cage, &mesh, &tri_face)
	resize(&mesh.normals, len(mesh.positions))
	groups := make([]u16, len(tri_face))
	defer delete(groups)
	for f, t in tri_face do groups[t] = cage.group[f]
	vert_of := make([]u32, len(mesh.positions))
	defer delete(vert_of)
	tri_from := make([]u32, len(tri_face))
	defer delete(tri_from)
	object_release_mesh(app, obj, rebuild = false)
	if !object_build_from(app, obj, mesh, start, normals = true, old_to_new = vert_of, surface = {groups = groups}, tri_from = tri_from) do return false
	l := &obj.levels
	if sculpt.levels_set_polys(l, cage_polys(&cage, vert_of, tri_face[:], tri_from), cage_sharp(&cage, vert_of), rule) {
		if quads, all := cage_quads(&cage, vert_of); all {
			sculpt.levels_set_quads(l, quads)
		} else {
			delete(quads)
		}
		for _ in 0 ..< steps do if !sculpt.levels_subdivide(l) do break
	}
	if have do cage_put_back(app, obj, &cage, vert_of, &held)
	if !object_show_level(app, obj, start) do return false
	if displace != 0 {
		mesh := object_mesh(obj)
		verts := make([]u32, len(mesh.positions))
		defer delete(verts)
		moved := make([]Vec3, len(mesh.positions))
		defer delete(moved)
		for p, v in mesh.positions {
			verts[v] = u32(v)
			moved[v] = poly.live_displace_at(p, linalg.normalize0(mesh.normals[v]), displace, displace_scale)
		}
		sculpt.sculptor_place_vertices(object_sculptor(obj), verts, moved)
	}
	return true
}

// Most triangles Edit cage draws its cage with: fewer Smooth steps than the sculpt had
// levels when that many would be more, so each edit stays quick. Apply makes them all.
CAGE_EDIT_TRIANGLES :: 2_000_000

// Whether Model action `a` reaches the selected object: a cage or a curve takes them, and
// with nothing selected they stand ready for the next one. Topo draws a new cage over any
// surface, so it takes a sculpt mesh too, and Measure measures anything shown.
model_actions_apply :: proc(app: ^App, a: Model_Action) -> bool {
	obj := selected_object(app)
	if obj == nil || a == .Topo || a == .Measure do return true
	#partial switch object_type(obj) {
	case .Cage, .Curve: return true
	}
	return false
}

// Whether Edit cage can take a cage from `obj`: a mesh whose base level is polygons (from
// Apply to sculpt) or quads (Retopologize), and not under dynamic topology.
object_can_edit_cage :: proc(obj: ^Object) -> bool {
	if obj == nil || obj.cage != nil || obj.voxel != nil || object_dynamic(obj) do return false
	return obj.levels.levels[0].polys.first != nil || sculpt.levels_has_quads(&obj.levels)
}

// Edit cage, after ZBrush's Dynamic Subdivision on a mesh with levels: the base level's
// polygons (or quads) become a cage again for Model mode, with their polygroups, creases
// and corners, drawn with as many Smooth steps as the sculpt had levels above its base.
// The sculpt's levels ride along in the cage (Cage_Part.held), so Apply to sculpt puts
// their detail back on the edited cage. Polypaint, masks and layers are not kept, and
// the note says so. Returns false only on a GPU failure, true with a note when the base
// does not make a valid cage.
object_edit_cage :: proc(app: ^App, obj: ^Object) -> bool {
	stroke_finish(app)
	object_hd_leave(app, obj)
	autosave_settle(app)
	l := &obj.levels
	sculpt.levels_sync(l)
	sculpt.levels_paint_to(l, 0)
	base := l.levels[0]
	sizes := make([dynamic]int, context.temp_allocator)
	corners := make([dynamic]u32, context.temp_allocator)
	groups := make([dynamic]u16, context.temp_allocator)
	tris := base.sculptor.groups.tris
	if polys := &base.polys; polys.first != nil {
		// Each polygon's group is its first triangle's.
		first := make([]u32, len(polys.first) - 1, context.temp_allocator)
		for &t in first do t = max(u32)
		#reverse for g, t in polys.tri_poly do first[g] = u32(t)
		for f in 0 ..< len(first) {
			append(&sizes, int(polys.first[f + 1] - polys.first[f]))
			append(&groups, tris[first[f]] if tris != nil && first[f] != max(u32) else 0)
		}
		append(&corners, ..polys.corners)
	} else {
		// A quad's group is that of its triangle with its first three corners or its first,
		// second and fourth, whichever way it was cut.
		for &q in l.faces.quads {
			append(&sizes, 4)
			append(&corners, ..q[:])
			group: u16
			if tris != nil {
				for t in geom.vertex_faces_of(base.sculptor.faces, q[0]) {
					tri := base.mesh.indices[3 * t:][:3]
					if slice.contains(tri, q[1]) && (slice.contains(tri, q[2]) || slice.contains(tri, q[3])) do group = tris[t]
				}
			}
			append(&groups, group)
		}
	}
	cage, err := poly.mesh_from_polygons(base.mesh.positions[:], sizes[:], corners[:], groups[:])
	if err != .None {
		report(app, nil, {.Warning}, "Edit cage refused on %s: its base level is not a valid cage (%v)", object_label(obj), err)
		return true
	}
	for key, i in base.sharp.edges {
		h := poly.find_half_edge(&cage, u32(key >> 32), u32(key))
		if h != poly.NONE do cage.crease[poly.edge_of(h)] = base.sharp.edge[i]
	}
	for v, i in base.sharp.verts do cage.corner[v] = base.sharp.vert[i]
	look := Cage_Look{min(len(l.levels) - 1, poly.SUBDIVIDE_MAX), l.rule == .Flat, {}, {}, 0}
	for look.smooth > 0 && 2 * len(corners) << uint(2 * (look.smooth - 1)) > CAGE_EDIT_TRIANGLES do look.smooth -= 1
	held: []u8
	if len(l.levels) > 1 {
		out := make([dynamic]u8)
		_ = sculpt.levels_write(l, &out)
		held = out[:]
	}
	s := &sculpt.levels_current(l).sculptor
	if len(s.layers.list) > 0 || sculpt.sculptor_paint_shows(s) || s.mask != nil {
		report(app, nil, {}, "Edit cage on %s keeps its sculpted detail, but not its polypaint, mask or layers", object_label(obj))
	}
	object_release_mesh(app, obj, rebuild = false)
	return object_build_cage(app, obj, cage, look, held)
}

// Puts the detail of `held` (the sculpt Edit cage took `cage` from) on `obj`'s new
// levels, made from the edited cage (`vert_of`, per cage point its base vertex). While
// the cage's faces are the base's polygons as they were, each level takes the held
// level's detail point for point, so it rides on the moved cage as ZBrush's levels ride
// on an edited base; otherwise the held top is projected onto the new top, as Project
// detail does.
@(private = "file")
cage_put_back :: proc(app: ^App, obj: ^Object, cage: ^poly.Mesh, vert_of: []u32, held: ^sculpt.Levels) {
	l := &obj.levels
	if base_map, ok := cage_base_map(cage, vert_of, held); ok && sculpt.levels_take_detail(l, held, base_map) {
		report(app, nil, {}, "%s took its sculpted detail back on %d levels", object_label(obj), len(l.levels))
		return
	}
	sculpt.levels_sync(held)
	top := held.levels[len(held.levels) - 1].mesh
	bvh := geom.bvh_build_morton(top, geom.BVH_LEAF_SIZE, &app.pool)
	defer geom.bvh_destroy(&bvh)
	m := object_mesh(obj)
	bounds := geom.AABB_EMPTY
	for p in m.positions do geom.aabb_grow(&bounds, p)
	extent := bounds.hi - bounds.lo
	next := make([]Vec3, len(m.positions))
	defer delete(next)
	tris := make([]u32, len(m.positions))
	defer delete(tris)
	size := max(extent.x, extent.y, extent.z)
	hits := geom.project_along_normals(m.positions[:], m.normals[:], top, &bvh, CAGE_PROJECT_REACH * size, &app.pool, next, tris)
	// A point whose normal finds nothing (where the edit moved the surface furthest)
	// goes to the nearest point of the sculpt instead, so none is left behind as a bump.
	for t, v in tris {
		if t != max(u32) do continue
		tri, bary, _, ok := geom.bvh_closest(bvh, top, m.positions[v], size)
		if !ok do continue
		c := top.indices[3 * tri:][:3]
		next[v] = bary[0] * top.positions[c[0]] + bary[1] * top.positions[c[1]] + bary[2] * top.positions[c[2]]
	}
	_ = sculpt.sculptor_project(object_sculptor(obj), next, nil, 1)
	report(app, nil, {}, "%s's cage changed its faces, so the sculpt was projected onto its top level: %.1f%% of points along their normals, the rest to the nearest point", object_label(obj), 100 * f64(hits) / f64(max(len(m.positions), 1)))
}

// How far the projection of Apply to sculpt looks, over the object's size: an edited
// cage may move its surface a good way from the sculpt.
CAGE_PROJECT_REACH :: 0.1

// The held base's vertex for each of the new base's (the map levels_take_detail takes),
// when the cage's faces are the held base's polygons (or quads), corner for corner.
@(private = "file")
cage_base_map :: proc(cage: ^poly.Mesh, vert_of: []u32, held: ^sculpt.Levels) -> (base_map: []u32, ok: bool) {
	base := held.levels[0]
	first, corners := base.polys.first, base.polys.corners
	if first == nil {
		// Quads, as consecutive polygons of four.
		quads := held.faces.quads
		if quads == nil do return nil, false
		corners = slice.reinterpret([]u32, quads)
	}
	faces := len(first) - 1 if first != nil else len(corners) / 4
	if faces != len(cage.face_he) || len(vert_of) != len(base.mesh.positions) do return nil, false
	base_map = make([]u32, len(vert_of), context.temp_allocator)
	for &b in base_map do b = poly.NONE
	verts := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< faces {
		lo, hi := 4 * f, 4 * f + 4
		if first != nil do lo, hi = int(first[f]), int(first[f + 1])
		poly.face_verts(cage, u32(f), &verts)
		if len(verts) != hi - lo do return nil, false
		for v, k in verts {
			at := &base_map[vert_of[v]]
			if at^ != poly.NONE && at^ != corners[lo + k] do return nil, false
			at^ = corners[lo + k]
		}
	}
	for b in base_map do if b == poly.NONE do return nil, false
	return base_map, true
}

// The cage's polygons as the sculptor keeps them (sculpt.Polys), in the level's vertex
// numbers (`vert_of`, per cage point) and triangles (`tri_from`, per level triangle its
// place in `tri_face`, each triangle's cage face). On the heap: the levels take them.
cage_polys :: proc(cage: ^poly.Mesh, vert_of, tri_face, tri_from: []u32) -> (p: sculpt.Polys) {
	p.first = make([]u32, len(cage.face_he) + 1)
	corners := make([dynamic]u32, 0, 4 * len(cage.face_he))
	verts := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< u32(len(cage.face_he)) {
		poly.face_verts(cage, f, &verts)
		for v in verts do append(&corners, vert_of[v])
		p.first[f + 1] = u32(len(corners))
	}
	p.corners = corners[:]
	p.tri_poly = make([]u32, len(tri_from))
	for old, t in tri_from do p.tri_poly[t] = tri_face[old]
	return
}

// The cage's creases and corners as the sculptor keeps them, in the level's numbers and
// sorted. On the heap: the levels take them.
cage_sharp :: proc(cage: ^poly.Mesh, vert_of: []u32) -> (s: sculpt.Sharp) {
	Edge :: struct {
		key: u64,
		c:   f32,
	}
	edges := make([dynamic]Edge, context.temp_allocator)
	for c, e in cage.crease {
		if c <= 0 do continue
		a, b := poly.edge_verts(cage, u32(e))
		append(&edges, Edge{sculpt.sharp_key(vert_of[a], vert_of[b]), c})
	}
	slice.sort_by(edges[:], proc(x, y: Edge) -> bool {return x.key < y.key})
	s.edges, s.edge = make([]u64, len(edges)), make([]f32, len(edges))
	for e, i in edges do s.edges[i], s.edge[i] = e.key, e.c
	Vert :: struct {
		v: u32,
		c: f32,
	}
	verts := make([dynamic]Vert, context.temp_allocator)
	for c, v in cage.corner do if c > 0 do append(&verts, Vert{vert_of[v], c})
	slice.sort_by(verts[:], proc(x, y: Vert) -> bool {return x.v < y.v})
	s.verts, s.vert = make([]u32, len(verts)), make([]f32, len(verts))
	for v, i in verts do s.verts[i], s.vert[i] = v.v, v.c
	return
}

// The cage's faces as quads in the level's numbers, and whether every face is one.
cage_quads :: proc(cage: ^poly.Mesh, vert_of: []u32) -> (quads: [][4]u32, all: bool) {
	quads = make([][4]u32, len(cage.face_he))
	verts := make([dynamic]u32, context.temp_allocator)
	for f in 0 ..< u32(len(cage.face_he)) {
		poly.face_verts(cage, f, &verts)
		if len(verts) != 4 do return quads, false
		quads[f] = {vert_of[verts[0]], vert_of[verts[1]], vert_of[verts[2]], vert_of[verts[3]]}
	}
	return quads, true
}

// Reads the cage object_put wrote in the levels' place into `obj` and builds its level.
// `read` is false when the bytes are damaged (nothing is made); `made` is false on a GPU
// failure.
cage_part_get :: proc(app: ^App, r: ^geom.Byte_Reader, obj: ^Object) -> (read, made: bool) {
	cage, ok := poly.mesh_read(r)
	if !ok do return false, false
	look: Cage_Look
	smooth := int(geom.byte_get(r, u8))
	flat := geom.byte_get(r, u8)
	if !r.ok || smooth > poly.SUBDIVIDE_MAX || flat > 1 {
		poly.mesh_destroy(&cage)
		return false, false
	}
	look = {smooth, flat == 1, {}, {}, 0}
	// The live stack: Thickness and Bevel creases.
	l: poly.Live
	l.thickness = geom.byte_get(r, f32)
	l.thickness_segments = int(geom.byte_get(r, u8))
	side := geom.byte_get(r, u8)
	l.bevel = geom.byte_get(r, f32)
	l.bevel_segments = int(geom.byte_get(r, u8))
	l.side = poly.Thickness_Side(side)
	sizes_ok := l.thickness >= 0 && l.thickness < 1e6 && l.bevel >= 0 && l.bevel < 1e6
	segments_ok := l.thickness_segments <= poly.LIVE_THICKNESS_SEGMENTS_MAX && l.bevel_segments <= poly.BEVEL_SEGMENTS_MAX
	if !r.ok || side > u8(max(poly.Thickness_Side)) || !sizes_ok || !segments_ok {
		poly.mesh_destroy(&cage)
		return false, false
	}
	look.live = l
	// The live mirror's axes.
	axes := geom.byte_get(r, u8)
	all := transmute(u8)poly.Mirror_Axes{.X, .Y, .Z}
	if !r.ok || axes & ~all != 0 {
		poly.mesh_destroy(&cage)
		return false, false
	}
	look.live.mirror = transmute(poly.Mirror_Axes)axes
	// The deformers: Deform's kind, axis and amount, then Displace's strength and size.
	kind := geom.byte_get(r, u8)
	axis := geom.byte_get(r, u8)
	look.live.deform_amount = geom.byte_get(r, f32)
	look.live.displace = geom.byte_get(r, f32)
	look.live.displace_scale = geom.byte_get(r, f32)
	finite :: proc(x: f32) -> bool {return x == x && abs(x) < 1e6}
	if !r.ok || kind > u8(max(poly.Deform_Kind)) || axis > u8(max(poly.Mirror_Axis)) || !finite(look.live.deform_amount) || !finite(look.live.displace) || !finite(look.live.displace_scale) || look.live.displace_scale < 0 {
		poly.mesh_destroy(&cage)
		return false, false
	}
	look.live.deform, look.live.deform_axis = poly.Deform_Kind(kind), poly.Mirror_Axis(axis)
	// The follow rows: Curve's object and axis, Wrap's object and offset.
	curve := geom.byte_get(r, i32)
	curve_axis := geom.byte_get(r, u8)
	curve_fit := geom.byte_get(r, u8)
	wrap := geom.byte_get(r, i32)
	offset := geom.byte_get(r, f32)
	if !r.ok || curve < 0 || wrap < 0 || curve_axis > u8(max(poly.Mirror_Axis)) || curve_fit > 1 || !finite(offset) {
		poly.mesh_destroy(&cage)
		return false, false
	}
	look.follow = {int(curve), poly.Mirror_Axis(curve_axis), curve_fit == 1, int(wrap), offset}
	// Sharp edges' angle.
	look.sharp = geom.byte_get(r, f32)
	if !r.ok || !(look.sharp >= 0 && look.sharp <= CAGE_SHARP_MAX) {
		poly.mesh_destroy(&cage)
		return false, false
	}
	// The sculpt Edit cage took it from, read only on Apply.
	held: []u8
	size := int(geom.byte_get(r, u32))
	bytes := geom.byte_get_bytes(r, size)
	if !r.ok {
		poly.mesh_destroy(&cage)
		return false, false
	}
	if size > 0 do held = slice.clone(bytes)
	return true, object_build_cage(app, obj, cage, look, held)
}

// The selected cage's look, for a command to change part of it.
cage_look_now :: proc(app: ^App) -> (Cage_Look, bool) {
	obj := selected_object(app)
	if obj == nil || obj.cage == nil do return {}, false
	return obj.cage.look, true
}

// How large a cage is (its longest side), which Thickness and Bevel creases are set as a
// share of, so a slider means the same on a small cage and a large one.
cage_size :: proc(cp: ^Cage_Part) -> f32 {
	b := poly.mesh_bounds(&cp.mesh)
	d := b.hi - b.lo
	return max(d.x, d.y, d.z, 1e-6)
}

// The most Thickness and Bevel creases go, as a percentage of the cage's size, and the
// bevel segments offered (of poly.BEVEL_SEGMENTS_MAX).
CAGE_LIVE_PERCENT_MAX :: 20
CAGE_BEVEL_SEGMENTS_SHOWN :: 6

// The most Displace pushes, as a percentage of the cage's size, and the size of its
// features at the start and at most, as shares of it.
CAGE_DISPLACE_PERCENT_MAX :: 10
CAGE_DISPLACE_SCALE_START :: 0.25
CAGE_DISPLACE_SCALE_MAX :: 1

// The Live stack's Deform (a tornado: a twist) and Displace (a rough peak) glyphs, on
// their rows and commands.
ICON_DEFORM :: rune(0xe218)
ICON_DISPLACE :: rune(0xe232)

// Sharp edges' largest angle, and the angle the row starts at (Blender's Smooth by Angle).
CAGE_SHARP_MAX :: 180
CAGE_SHARP_START :: 30

// Panel loops' sizes in percent of the cage's size: the range of each slider and where
// they start (a thin chamfer round a plate standing out by about as much).
PANEL_WIDTH_MIN :: 0.2
PANEL_WIDTH_MAX :: 10.0
PANEL_DEPTH_MAX :: 10.0
PANEL_WIDTH_START :: 0.03
PANEL_DEPTH_START :: 0.02
ICON_SHARP :: rune(0xe242) // gem, whose facets meet at hard edges

// The amount Deform starts at for `kind`: a quarter turn for Bend and Twist, half as wide
// again at the far end for Taper.
cage_deform_start :: proc(kind: poly.Deform_Kind) -> f32 {
	switch kind {
	case .Off: return 0
	case .Bend, .Twist: return math.PI / 2
	case .Taper: return 0.5
	}
	return 0
}

// Draws `obj`'s cage as `look` says, as one undo step; with `drag` (a slider moving), the
// step starts at the first change and ends when the slider lets go (cage_look_drag_end).
// A change of widths alone keeps the drawn topology, so only the points move; anything
// else makes the level again. Returns false only on a GPU failure.
object_set_cage_look :: proc(app: ^App, obj: ^Object, wanted: Cage_Look, drag := false) -> bool {
	look := cage_look_clean(wanted)
	old := obj.cage.look
	if old == look do return true
	what := "cage look"
	switch {
	case look.flat != old.flat:     what = "flat"
	case look.smooth != old.smooth: what = fmt.tprintf("smooth %d", look.smooth)
	case look.live.mirror != old.live.mirror: what = "mirror"
	case look.live.bevel != old.live.bevel || look.live.bevel_segments != old.live.bevel_segments: what = "bevel creases"
	case look.live.deform != old.live.deform || look.live.deform_axis != old.live.deform_axis || look.live.deform_amount != old.live.deform_amount: what = "deform"
	case look.live.displace != old.live.displace || look.live.displace_scale != old.live.displace_scale: what = "displace"
	case look.follow.curve != old.follow.curve || look.follow.curve_axis != old.follow.curve_axis || look.follow.curve_fit != old.follow.curve_fit: what = "along a curve"
	case look.follow.wrap != old.follow.wrap || look.follow.wrap_offset != old.follow.wrap_offset: what = "wrap"
	case look.sharp != old.sharp: what = "sharp edges"
	case: what = "thickness"
	}
	ld := &app.model.look_drag
	if drag && ld.before != nil && ld.object != obj.id do cage_look_drag_end(app, force = true)
	before: ^Object_Snapshot
	if !drag {
		before = history_snapshot(app, obj, what)
	} else if ld.before == nil {
		ld^ = {object = obj.id, before = history_snapshot(app, obj, what)}
	}
	obj.cage.look = look
	same := old.smooth == look.smooth && old.flat == look.flat && old.live.mirror == look.live.mirror && (old.live.thickness > 0) == (look.live.thickness > 0) && (old.live.bevel > 0) == (look.live.bevel > 0) && old.live.thickness_segments == look.live.thickness_segments && old.live.bevel_segments == look.live.bevel_segments && cage_live_wanted(old) == cage_live_wanted(look) && old.sharp == look.sharp
	ok := cage_positions_moved(app, obj, nil) if same && obj.cage.live.vert_first != nil else cage_rebuild(app, obj)
	if !ok {
		if before != nil do history_snapshot_drop(before)
		return false
	}
	if before != nil do history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

// A look slider's drag in progress: the cage it changes and the snapshot from before it.
Cage_Look_Drag :: struct {
	object: int,
	before: ^Object_Snapshot,
}

// Ends a look slider's drag as one undo step once the pointer is up (or now, with
// `force`): called each frame, and with the other panel drags before a scene command.
cage_look_drag_end :: proc(app: ^App, force := false) {
	ld := &app.model.look_drag
	if ld.before == nil || (!force && .Left in app.device.down) do return
	obj := object_by_id(app, ld.object)
	if obj != nil && obj.cage != nil {
		history_record_swap(app, ld.object, ld.before, kind = .Model)
	} else {
		history_snapshot_drop(ld.before)
	}
	ld^ = {}
}

// The cage clean-ups of the Model palette: Blender's Limited dissolve and Merge by
// distance.
Cage_Tidy :: enum u8 {
	Dissolve_Flat,
	Merge_Close,
	Apply_Mirror,
}

@(rodata)
CAGE_TIDY_NAMES := [Cage_Tidy]string {
	.Dissolve_Flat = "Dissolve flat",
	.Merge_Close   = "Merge close points",
	.Apply_Mirror  = "Apply mirror",
}

// How flat two faces must be to join, and how close two points to merge (a share of the
// cage's largest side).
CAGE_FLAT_DEGREES :: 5
CAGE_MERGE_SHARE :: 1e-3

// Runs a clean-up on `obj`'s cage as one undo step, saying what it did. Returns false only
// on a GPU failure.
object_tidy_cage :: proc(app: ^App, obj: ^Object, kind: Cage_Tidy) -> bool {
	cage := &obj.cage.mesh
	faces, points := len(cage.face_he), len(cage.positions)
	if kind == .Apply_Mirror do return object_apply_cage_mirror(app, obj)
	before := history_snapshot(app, obj, "dissolve flat faces" if kind == .Dissolve_Flat else "merge close points")
	r: poly.Edit_Result
	err: poly.Build_Error
	switch kind {
	case .Apply_Mirror:
	// Applied above, since it changes the look too.
	case .Dissolve_Flat:
		r, err = poly.dissolve_by_angle(cage, CAGE_FLAT_DEGREES)
	case .Merge_Close:
		b := poly.mesh_bounds(cage)
		size := b.hi - b.lo
		r, _, err = poly.merge_by_distance(cage, CAGE_MERGE_SHARE * max(size.x, size.y, size.z))
	}
	poly.edit_result_destroy(&r)
	if err != .None {
		history_snapshot_drop(before)
		report(app, nil, {.Warning}, "%s refused on %s: what it would leave is not a valid cage (%v)", CAGE_TIDY_NAMES[kind], object_label(obj), err)
		return true
	}
	if len(cage.face_he) == faces && len(cage.positions) == points {
		history_snapshot_drop(before)
		report(app, nil, {}, "%s: nothing to do on %s", CAGE_TIDY_NAMES[kind], object_label(obj))
		return true
	}
	report(app, nil, {}, "%s: %s went from %d faces and %d points to %d and %d", CAGE_TIDY_NAMES[kind], object_label(obj), faces, points, len(cage.face_he), len(cage.positions))
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

// Apply mirror: the cage's live mirror images become part of it, the seam's points
// shared, and the mirror goes off, as one undo step, as applying Blender's Mirror modifier
// does. The cage's own points and faces keep their ids, so its selection stays. Returns
// false only on a GPU failure.
object_apply_cage_mirror :: proc(app: ^App, obj: ^Object) -> bool {
	cp := obj.cage
	if cp.look.live.mirror == {} {
		report(app, nil, {}, "Apply mirror: %s has no mirror on", object_label(obj))
		return true
	}
	whole, from, err := poly.live_mirror(&cp.mesh, cp.look.live.mirror, poly.mirror_slack(&cp.mesh))
	delete(from)
	if err != .None {
		report(app, nil, {.Warning}, "Apply mirror refused on %s: a face lies across the mirror plane, so the halves would share an edge that already has two faces", object_label(obj))
		return true
	}
	faces := len(cp.mesh.face_he)
	before := history_snapshot(app, obj, "apply mirror")
	poly.mesh_destroy(&cp.mesh)
	cp.mesh = whole
	cp.look.live.mirror = {}
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	report(app, nil, {}, "Apply mirror: %s went from %d faces to %d", object_label(obj), faces, len(obj.cage.mesh.face_he))
	return true
}

// The crease options of the Model palette: ZModeler's Crease by angle and Crease
// polygroups, and taking every crease away.
Cage_Crease :: enum u8 {
	By_Angle,
	Group_Borders,
	Clear,
}

@(rodata)
CAGE_CREASE_NAMES := [Cage_Crease]string {
	.By_Angle      = "Crease by angle",
	.Group_Borders = "Crease polygroup borders",
	.Clear         = "Clear creases",
}

// How far two faces must bend from each other for Crease by angle: Blender's default for
// sharp edges.
CAGE_CREASE_DEGREES :: 30

// Creases `obj`'s cage as `kind` says, as one undo step, saying how many edges it changed.
// Returns false only on a GPU failure.
object_crease_cage :: proc(app: ^App, obj: ^Object, kind: Cage_Crease) -> bool {
	before := history_snapshot(app, obj, strings.to_lower(CAGE_CREASE_NAMES[kind], context.temp_allocator))
	cage := &obj.cage.mesh
	count: int
	switch kind {
	case .By_Angle:      count = poly.crease_by_angle(cage, CAGE_CREASE_DEGREES)
	case .Group_Borders: count = poly.crease_group_borders(cage)
	case .Clear:         count = poly.crease_clear(cage)
	}
	if count == 0 {
		history_snapshot_drop(before)
		report(app, nil, {}, "%s: nothing to do on %s", CAGE_CREASE_NAMES[kind], object_label(obj))
		return true
	}
	report(app, nil, {}, "%s: %d %s on %s", CAGE_CREASE_NAMES[kind], count, "edges and points" if kind == .Clear else "edges", object_label(obj))
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

@(rodata)
CAGE_SELECT_NAMES := [poly.Select_Op]string {
	.All    = "Select all of the cage",
	.None   = "Select none of the cage",
	.Invert = "Invert what the cage has selected",
	.Grow   = "Grow what the cage has selected",
	.Shrink = "Shrink what the cage has selected",
}

// Changes `obj`'s cage selection as one undo step (a selection is undone as Blender's
// is): its faces, or with `pick` edges or points its picked points; None takes both away.
// Nothing is listed when nothing changed. Returns false only on a GPU failure.
object_select_cage :: proc(app: ^App, obj: ^Object, op: poly.Select_Op, pick: Model_Element) -> bool {
	before := history_snapshot(app, obj, strings.to_lower(CAGE_SELECT_NAMES[op], context.temp_allocator))
	cage := &obj.cage.mesh
	changed: bool
	if op == .None {
		faces := poly.select_op(cage, .None)
		points := poly.pick_op(cage, .None)
		changed = faces || points
	} else if pick == .Face {
		changed = poly.select_op(cage, op)
	} else {
		changed = poly.pick_op(cage, op)
	}
	if !changed {
		history_snapshot_drop(before)
		return true
	}
	if !cage_rebuild(app, obj) {
		history_snapshot_drop(before)
		return false
	}
	history_record_swap(app, obj.id, before, kind = .Model)
	return true
}

// The commands a cage object refuses: each changes its level in place (vertices, masks,
// hiding, paint, groups, levels, layers), which the next edit of the cage would undo.
CAGE_REFUSED_COMMANDS :: Command_Set{
	.Dyntopo_Toggle, .Subdivide, .Level_Up, .Level_Down, .Hd_Toggle, .Group_Shortcut, .Mask, .Mask_By, .Mask_Adjust,
	.Show_All, .Invert_Hidden, .Hide_Masked, .Hide_Unmasked, .Grow_Visible, .Shrink_Visible, .Grow_All_Visible,
	.Outer_Ring, .Grow_To_Groups, .Show_Masked, .Store_Selection_Set, .Restore_Selection_Set, .Paint, .Group,
	.Delete_Lower_Levels, .Delete_Higher_Levels, .Hd_Divide, .Hd_Delete, .Hd_Sculpt, .Hd_Leave, .Detail_Skin, .Skin_Apply, .Skin_Squeeze, .Morph_Store,
	.Morph_Delete, .New_Layer, .Layer_Edit, .New_Paint_Layer, .New_Texture_Layer, .Paint_Layer_Edit, .Recall_Earlier, .Recall_Later, .Recall_Oldest, .Smooth_All, .Deformer,
	.Deformation, .Reshape_Repeat, .Delete_Hidden, .Extract_Masked, .Replay_Stroke,
}

// The scene commands a cage object refuses, for the same reason.
CAGE_REFUSED_SCENE :: bit_set[Scene_Command_Kind]{.Subdivide, .Set_Level, .Delete_Higher, .Delete_Lower, .Hd_Enter, .Hd_Leave, .Hd_Steps, .Hd_Delete, .Dyntopo, .Extract, .Unwrap, .Straighten, .Texel_Density, .Skin_Apply, .Squeeze}

// Whether the selected object is a cage.
selected_cage :: proc(app: ^App) -> bool {
	obj := selected_object(app)
	return obj != nil && obj.cage != nil
}

// Whether `obj`'s level may be changed in place (a stroke, a mask, paint); a cage's may
// not, which is said once a press (`say`) so the press does not do nothing in silence.
object_editable :: proc(app: ^App, obj: ^Object, say: bool) -> bool {
	if obj.curve != nil {
		if say do report(app, nil, {.Warning}, "%s is a curve: it has no surface to sculpt", object_label(obj))
		return false
	}
	if obj.cage == nil do return true
	if say do report(app, nil, {.Warning}, "%s is a cage: edit it with the Model tool, or Apply to sculpt to sculpt it", object_label(obj))
	return false
}

// The Model tool's state: the primitive and segments Add cage makes (zero segments for
// the primitive's defaults), the action and target a press uses (model_tool.odin), and
// what the pen is over and dragging.
Model_Tool :: struct {
	primitive: poly.Primitive,
	segments:  poly.Primitive_Options,
	action:    Model_Action,
	// Per action, the target picked for it, for those in `targeted` (the rest use
	// MODEL_DEFAULT_TARGETS), so each action keeps its own as ZModeler's do.
	targets:   [Model_Action]Model_Target,
	targeted:  bit_set[Model_Action],
	group:     u16, // the polygroup Polygroup paints
	check:     bool, // the mesh check's colours are drawn over the shown cages
	bevel_segments: int, // the segments the last round bevel had (0 for none yet)
	// Per drag action, how far it went last (0 for not yet): a tap with it repeats that, as
	// ZModeler's Extrude does.
	last:      [Model_Action]f32,
	hover:     Model_Hover,
	drag:      Model_Drag,
	// The Knife's last tap on an edge (object 0 for none), which the next tap cuts to, as
	// Maya's Multi-Cut does: each tap cuts from the one before until a tap off the cage.
	knife_from: Model_Knife_Tap,
	// The last Align parts join, which a tap on the part turns or flips.
	aligned:   Model_Aligned,
	// The Topo pen's dots and drag (model_topo.odin).
	topo:      Model_Topo,
	measure:   Model_Measure,
	relax:     Model_Relax,
	slide:     Model_Slide,
	look_drag: Cage_Look_Drag,
	// What Select picks (faces, or points through edges and points) and the gizmo's drag of
	// the selection (model_gizmo.odin), with the falloff its move eases out over, a share
	// of the cage's size (0 for none, Blender's proportional editing).
	pick:      Model_Element,
	falloff:   f32,
	// Panel loops' inset width and how far the panel stands out (negative: sunk in), both
	// shares of the cage's size (cage_edit.odin).
	panel_width: f32,
	panel_depth: f32,
	xform:     Cage_Xform,
	xforms:    int, // moves, turns and scales of the selection made, for the exit stats
	edits:     int, // the Edit section's edits made, for the exit stats
	pointer:   [2]f32, // the pointer's last place over the view, where a key's drag starts
	// Since the start, for the exit stats: actions made, and refused.
	done:      int,
	refused:   int,
	// Spine, Extrude and Knife along a curve, and curves made by Loop to curve.
	follows:     int,
	follow_updates: int, // cages worked out again because what their Curve or Wrap row reads changed
	loop_curves: int,
}

// The segments Add cage uses: the ones set, and the defaults for those never set.
model_segments :: proc(m: Model_Tool) -> poly.Primitive_Options {
	s := m.segments
	if s.across <= 0 do s.across = poly.PRIMITIVE_DEFAULTS.across
	if s.around <= 0 do s.around = poly.PRIMITIVE_DEFAULTS.around
	if s.along <= 0 do s.along = poly.PRIMITIVE_DEFAULTS.along
	if s.tube <= 0 do s.tube = poly.PRIMITIVE_DEFAULTS.tube
	return s
}

// The tray's Model palette: the primitive to add as a cage and its segments, Apply to
// sculpt, and what the selected cage is made of.
kit_model_tab :: proc(app: ^App) {
	ctx := &app.kit.ctx
	m := &app.model
	kit_tool_head(ctx, ui.ICON_GRID, "Model", "Builds and edits cages: polygons with their edges shown, as ZBrush's ZModeler and Blender's edit mode work. Pick an action and a target, then press on a cage: the faces it would reach light up under the pen first. Add a primitive here; Apply to sculpt turns a cage into a mesh to sculpt.")
	ui.caption(ctx, "ACTION")
	actions: [len(Model_Action)]string
	for a, i in Model_Action do actions[i] = MODEL_ACTION_NAMES[a]
	if picked := ui.select(ctx, "model action", actions[:], int(m.action)); picked >= 0 do command_run(app, .Model_Action, picked)
	// Select picks faces, edges or points, as Blender's three select modes; what it picks
	// shows a gizmo that moves it, with the falloff the move eases out over.
	if m.action == .Select {
		picks := [3]string{"Faces", "Edges", "Points"}
		if picked := ui.tabs(ctx, "model pick", picks[:], int(m.pick)); picked >= 0 do m.pick = Model_Element(picked)
	}
	ui.caption(ctx, "TARGET")
	// Only the targets the action can take.
	targets := make([dynamic]string, context.temp_allocator)
	which := make([dynamic]Model_Target, context.temp_allocator)
	chosen := 0
	for g in model_targets(m, m.action) {
		if g == model_target(m, m.action) do chosen = len(which)
		append(&targets, MODEL_TARGET_NAMES[g])
		append(&which, g)
	}
	if picked := ui.select(ctx, "model target", targets[:], chosen); picked >= 0 do command_run(app, .Model_Target, int(which[picked]))
	how := MODEL_ACTION_HOW[m.action]
	if alt := MODEL_ACTION_ALT[m.action]; alt != "" {
		ui.paragraph(ctx, fmt.tprintf("%s. Held Ctrl (the dial's Alt): %s.", how, alt))
	} else {
		ui.paragraph(ctx, fmt.tprintf("%s.", how))
	}
	if m.action == .Select {
		f := m.falloff * 100
		if ui.slider(ctx, "Falloff", &f, 0, 100, .Linear, "Off" if m.falloff <= 0 else fmt.tprintf("%.0f%%", f)) do m.falloff = clamp(f / 100, 0, 1)
		kit_snap_rows(app, "model")
		ui.paragraph(ctx, "With something selected, the gizmo at its middle moves, turns or scales it (G, R and S too, X, Y or Z for an axis); tap a handle without moving it to type its value. Falloff carries the points round the selection part of the way, less the further they are, up to that share of the cage's size. Snap (or Ctrl) moves by the grid's steps, onto the nearest point, edge or face middle, or onto a surface.")
	}
	if m.action == .Polygroup {
		g := f32(m.group)
		if ui.slider(ctx, "Polygroup", &g, 0, 64, .Linear, fmt.tprint(m.group)) do m.group = u16(clamp(int(g + 0.5), 0, 64))
	}
	if obj := selected_object(app); obj != nil && obj.cage != nil {
		ui.caption(ctx, "CREASES")
		kit_command_pair(app, .Crease_Cage, .Crease_Cage, arg_a = int(Cage_Crease.By_Angle), arg_b = int(Cage_Crease.Group_Borders), label_a = "By angle", label_b = "Polygroups")
		_ = command_button(app, .Crease_Cage, int(Cage_Crease.Clear), "Clear creases", width = ui.fill_width(ctx))
		ui.paragraph(ctx, "Smooth, Mirror, Thickness and Bevel creases are the cage's rows in the Live stack card.")
	}
	// A selected curve makes cages here (curve_cage.odin).
	if obj := selected_object(app); obj != nil && obj.curve != nil do kit_curve_cage(app)
	check := m.check
	if ui.switch_row(ctx, "Mesh check", &check, keys = command_hint(app, .Cage_Check)) do command_run(app, .Cage_Check)
	ui.caption(ctx, "SELECTION")
	kit_command_pair(app, .Select_Cage, .Select_Cage, arg_a = int(poly.Select_Op.All), arg_b = int(poly.Select_Op.None), label_a = "All", label_b = "None")
	kit_command_pair(app, .Select_Cage, .Select_Cage, arg_a = int(poly.Select_Op.Grow), arg_b = int(poly.Select_Op.Shrink), label_a = "Grow", label_b = "Shrink")
	_ = command_button(app, .Select_Cage, int(poly.Select_Op.Invert), "Invert", width = ui.fill_width(ctx))
	// The edits of the selection, as Blender's edit mode menu: each says what it needs when
	// the selection has none of it.
	if obj := selected_object(app); obj != nil && obj.cage != nil {
		ui.caption(ctx, "EDIT")
		pair :: proc(app: ^App, a, b: Cage_Edit, label_a, label_b: string) {
			kit_command_pair(app, .Cage_Edit, .Cage_Edit, arg_a = int(a), arg_b = int(b), label_a = label_a, label_b = label_b)
		}
		pair(app, .Subdivide, .Poke, "Subdivide", "Poke")
		pair(app, .Tris_To_Quads, .Fill, "Tris to quads", "Fill holes")
		pair(app, .Split, .Separate, "Split", "Separate")
		pair(app, .Bevel_Points, .Join, "Bevel points", "Join below")
		pair(app, .Relax, .Smooth, "Relax", "Smooth")
		pair(app, .Union, .Subtract, "Union below", "Subtract below")
		pair(app, .Intersect, .Panel_Loops, "Intersect below", "Panel loops")
		width, depth := 100 * m.panel_width, 100 * m.panel_depth
		if ui.slider(ctx, "Panel width", &width, PANEL_WIDTH_MIN, PANEL_WIDTH_MAX, .Linear, fmt.tprintf("%.1f%%", width)) do m.panel_width = clamp(width, PANEL_WIDTH_MIN, PANEL_WIDTH_MAX) / 100
		if ui.slider(ctx, "Panel depth", &depth, -PANEL_DEPTH_MAX, PANEL_DEPTH_MAX, .Linear, fmt.tprintf("%+.1f%%", depth)) do m.panel_depth = clamp(depth, -PANEL_DEPTH_MAX, PANEL_DEPTH_MAX) / 100
		faces, points := cage_edit_counts(&obj.cage.mesh)
		ui.paragraph(ctx, fmt.tprintf("%d faces selected, %d points picked. Subdivide, Poke, Split and Separate take the selected faces; Tris to quads the selected faces or all; Fill the hole a picked border edge is on, or every hole; Bevel points the picked points; Relax and Smooth the whole selection, with the Falloff; Join takes in the cage listed below this one, and Union, Subtract and Intersect cut it with that cage exactly, along the faces' planes, the seam creased. Panel loops insets the selected faces by the Panel width and raises them by the Panel depth (sinks them when it is below zero), creasing the three loops so Smooth keeps the panel crisp.", faces, points))
	}
	ui.caption(ctx, "TIDY")
	kit_command_pair(app, .Tidy_Cage, .Tidy_Cage, arg_a = int(Cage_Tidy.Dissolve_Flat), arg_b = int(Cage_Tidy.Merge_Close), label_a = "Dissolve flat", label_b = "Merge close")
	ui.caption(ctx, "NEW CAGE")
	names: [len(poly.Primitive)]string
	for p, i in poly.Primitive do names[i] = poly.PRIMITIVE_NAMES[p]
	if picked := ui.select(ctx, "cage primitive", names[:], int(m.primitive)); picked >= 0 do m.primitive = poly.Primitive(picked)
	m.segments = model_segments(m^)
	segments :: proc(ctx: ^ui.Context, label: string, value: ^int, lo: int) {
		v := f32(value^)
		if ui.slider(ctx, label, &v, f32(lo), 64, .Logarithmic, fmt.tprint(value^)) do value^ = clamp(int(v + 0.5), lo, 64)
	}
	switch m.primitive {
	case .Cube, .Plane, .Sphere:
		segments(ctx, "Segments", &m.segments.across, 2 if m.primitive == .Sphere else 1)
	case .Cylinder:
		segments(ctx, "Around", &m.segments.around, 3)
		segments(ctx, "Along", &m.segments.along, 1)
	case .Torus:
		segments(ctx, "Around", &m.segments.around, 3)
		segments(ctx, "Tube", &m.segments.tube, 3)
	case .Cone:
		segments(ctx, "Around", &m.segments.around, 3)
	}
	kit_command_pair(app, .Add_Cage, .Apply_Cage, arg_a = int(m.primitive), label_a = "Add cage")
	obj := selected_object(app)
	if object_can_edit_cage(obj) do _ = command_button(app, .Edit_Cage, width = ui.fill_width(ctx))
	if obj == nil || obj.cage == nil do return
	c := poly.mesh_check(&obj.cage.mesh)
	creased, corners := poly.crease_count(&obj.cage.mesh)
	ui.paragraph(ctx, fmt.tprintf("%s: %d points, %d edges, %d faces (%d quads, %d triangles, %d polygons), %d creased edges, %d corners, %d poles, %d open edges", object_label(obj), c.vertices, c.edges, c.faces, c.quads, c.triangles, c.ngons, creased, corners, c.poles, c.border_edges))
}

// A cage's rows in the Live stack card (kit_stack), each the body of its folded row: the
// live surface (Smooth, as ZBrush's Dynamic Subdivision: steps of smoothing drawn over the
// cage, which keeps its edges and is what every action works on; and Flat), Mirror's
// axes, then Thickness and Bevel creases, each a width slider (a share of the cage's size,
// one undo step a drag) with its segments, and the shell's side. These change the cage's
// polygons, which it is small enough to build again after every edit, where a sculpt's
// rows only make copies.
kit_cage_smooth :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	steps := [poly.SUBDIVIDE_MAX + 1]string{"Off", "1", "2", "3", "4"}
	step_hints: [poly.SUBDIVIDE_MAX + 1]string
	for &h, i in step_hints do h = command_hint(app, .Cage_Smooth, i)
	if picked := ui.tabs(ctx, "cage smooth", steps[:], cp.look.smooth, keys = step_hints[:]); picked >= 0 do command_run(app, .Cage_Smooth, picked)
	flat := cp.look.flat
	if ui.switch_row(ctx, "Flat corners", &flat, keys = command_hint(app, .Cage_Flat)) do command_run(app, .Cage_Flat)
}

kit_cage_mirror :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	live := cp.look.live
	ui.begin(ctx, "cage mirror axes", {direction = .Row, gap = ui.SPACE_XS})
	for axis in poly.Mirror_Axis {
		if ui.toggle_button(ctx, fmt.tprint(axis), axis in live.mirror, 48, command_hint(app, .Cage_Mirror, int(axis)), fmt.tprintf("Mirror the cage across %v", axis)) do command_run(app, .Cage_Mirror, int(axis))
	}
	ui.end(ctx)
	if cp.live.mirror_refused do ui.paragraph(ctx, "A face lies across the mirror plane, so the halves would overlap: the mirror is off until it is cut there (Insert loop) or moved off.")
}

@(private = "file")
cage_look_drag :: proc(app: ^App, look: Cage_Look) {app.ui.scene_command = {kind = .Cage_Look, look = look, look_drag = true}}

@(private = "file")
CAGE_SEGMENT_NAMES := [?]string{"1", "2", "3", "4", "5", "6"}

kit_cage_thickness :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	size := cage_size(cp)
	live := cp.look.live
	thick := 100 * live.thickness / size
	if ui.slider(ctx, "Thickness", &thick, 0, CAGE_LIVE_PERCENT_MAX, .Linear, "Off" if thick <= 0 else fmt.tprintf("%.1f%%", thick)) {
		look := cp.look
		look.live.thickness = thick / 100 * size
		cage_look_drag(app, look)
	}
	if live.thickness <= 0 do return
	{
		hints: [poly.LIVE_THICKNESS_SEGMENTS_MAX]string
		for &h, i in hints do h = command_hint(app, .Cage_Thickness_Segments, i)
		if picked := ui.tabs(ctx, "thickness segments", CAGE_SEGMENT_NAMES[:poly.LIVE_THICKNESS_SEGMENTS_MAX], live.thickness_segments - 1, keys = hints[:]); picked >= 0 do command_run(app, .Cage_Thickness_Segments, picked)
	}
	sides := [len(poly.Thickness_Side)]string{"Out", "In", "Centre"}
	hints: [len(poly.Thickness_Side)]string
	for &h, i in hints do h = command_hint(app, .Cage_Thickness_Side, i)
	if picked := ui.tabs(ctx, "thickness side", sides[:], int(live.side), keys = hints[:]); picked >= 0 do command_run(app, .Cage_Thickness_Side, picked)
}

kit_cage_bevel :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	size := cage_size(cp)
	live := cp.look.live
	width := 100 * live.bevel / size
	if ui.slider(ctx, "Width", &width, 0, CAGE_LIVE_PERCENT_MAX, .Linear, "Off" if width <= 0 else fmt.tprintf("%.1f%%", width)) {
		look := cp.look
		look.live.bevel = width / 100 * size
		cage_look_drag(app, look)
	}
	if live.bevel <= 0 do return
	hints: [CAGE_BEVEL_SEGMENTS_SHOWN]string
	for &h, i in hints do h = command_hint(app, .Cage_Bevel_Segments, i)
	if picked := ui.tabs(ctx, "bevel segments", CAGE_SEGMENT_NAMES[:CAGE_BEVEL_SEGMENTS_SHOWN], live.bevel_segments - 1, keys = hints[:]); picked >= 0 do command_run(app, .Cage_Bevel_Segments, picked)
	creased, _ := poly.crease_count(&cp.mesh)
	switch {
	case cp.live.bevel_refused: ui.paragraph(ctx, "A creased edge reaches a point with only two edges, which cannot be rounded, so the bevel is off.")
	// A shell's rim edges are creased by Thickness, so a plate bevels with no crease of its own.
	case creased == 0 && live.thickness <= 0: ui.paragraph(ctx, "Crease edges (Crease, or By angle above) to bevel them.")
	}
}

// Deform: Off, Bend, Twist or Taper, the axis, and how far (in degrees for Bend and
// Twist, a percentage for Taper), a drag one undo step.
kit_cage_deform :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	live := cp.look.live
	kinds := [len(poly.Deform_Kind)]string{"Off", "Bend", "Twist", "Taper"}
	kind_hints: [len(poly.Deform_Kind)]string
	for &h, i in kind_hints do h = command_hint(app, .Cage_Deform, i)
	if picked := ui.tabs(ctx, "cage deform kind", kinds[:], int(live.deform), keys = kind_hints[:]); picked >= 0 do command_run(app, .Cage_Deform, picked)
	if live.deform == .Off do return
	axes := [len(poly.Mirror_Axis)]string{"X", "Y", "Z"}
	axis_hints: [len(poly.Mirror_Axis)]string
	for &h, i in axis_hints do h = command_hint(app, .Cage_Deform_Axis, i)
	if picked := ui.tabs(ctx, "cage deform axis", axes[:], int(live.deform_axis), keys = axis_hints[:]); picked >= 0 do command_run(app, .Cage_Deform_Axis, picked)
	look := cp.look
	if live.deform == .Taper {
		share := 100 * live.deform_amount
		if ui.slider(ctx, "Taper", &share, -100 * poly.LIVE_TAPER_MAX, 100 * poly.LIVE_TAPER_MAX, .Linear, fmt.tprintf("%+.0f%%", share)) {
			look.live.deform_amount = share / 100
			cage_look_drag(app, look)
		}
	} else {
		turn := math.to_degrees(live.deform_amount)
		top := f32(math.to_degrees(f32(poly.LIVE_DEFORM_TURN_MAX)))
		if ui.slider(ctx, "Angle" if live.deform == .Bend else "Turn", &turn, -top, top, .Linear, fmt.tprintf("%.0f°", turn)) {
			look.live.deform_amount = math.to_radians(turn)
			cage_look_drag(app, look)
		}
	}
}

// Displace: how far the noise pushes either way and the size of its features, each a
// share of the cage's size and a drag one undo step.
kit_cage_displace :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	size := cage_size(cp)
	live := cp.look.live
	strength := 100 * live.displace / size
	if ui.slider(ctx, "Strength", &strength, 0, CAGE_DISPLACE_PERCENT_MAX, .Linear, "Off" if strength <= 0 else fmt.tprintf("%.1f%%", strength)) {
		look := cp.look
		look.live.displace = strength / 100 * size
		if look.live.displace_scale <= 0 do look.live.displace_scale = CAGE_DISPLACE_SCALE_START * size
		cage_look_drag(app, look)
	}
	if live.displace <= 0 do return
	scale := 100 * live.displace_scale / size
	if ui.slider(ctx, "Feature size", &scale, 2, 100 * CAGE_DISPLACE_SCALE_MAX, .Linear, fmt.tprintf("%.0f%%", scale)) {
		look := cp.look
		look.live.displace_scale = scale / 100 * size
		cage_look_drag(app, look)
	}
}

// The cage's level with Sharp edges' copies welded back onto the points they stand for
// and dropped, for a file with no normals to split (OBJ, PLY, STL).
cage_export_welded :: proc(cp: ^Cage_Part, level: ^geom.Mesh) -> geom.Mesh {
	n := len(level.positions)
	to := make([]u32, n, context.temp_allocator)
	for &v, i in to do v = u32(i)
	first := len(cp.vert_of) - len(cp.dup_from)
	for src, k in cp.dup_from do to[cp.vert_of[first + k]] = cp.vert_of[src]
	// The vertices still used, numbered in order.
	keep := make([]u32, n, context.temp_allocator)
	for &k in keep do k = max(u32)
	for i in level.indices do keep[to[i]] = 0
	out := geom.Mesh{positions = make([dynamic]Vec3), normals = make([dynamic]Vec3), indices = make([dynamic]u32)}
	for &k, v in keep {
		if k == max(u32) do continue
		k = u32(len(out.positions))
		append(&out.positions, level.positions[v])
	}
	for i in level.indices do append(&out.indices, keep[to[i]])
	resize(&out.normals, len(out.positions))
	geom.mesh_recompute_normals(&out)
	return out
}

// Sharp edges' body: the angle past which edges shade hard, as Blender's Smooth by Angle.
// A cage is drawn flat until the row is added; with it, smoothly but for those edges (at
// 180° smooth everywhere). The split is worked out when the cage is made, so a point moved later keeps the edges it
// had until the next change of the cage's faces or of this angle.
kit_cage_sharp :: proc(app: ^App, obj: ^Object) {
	ctx := &app.kit.ctx
	cp := obj.cage
	angle := cp.look.sharp
	if ui.slider(ctx, "Angle", &angle, 0, CAGE_SHARP_MAX, .Linear, "Off" if angle <= 0 else fmt.tprintf("%.0f°", angle)) {
		look := cp.look
		look.sharp = math.round(angle)
		cage_look_drag(app, look)
	}
}
