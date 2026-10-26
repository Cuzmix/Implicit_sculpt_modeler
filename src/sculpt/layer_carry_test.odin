package sculpt

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../jobs"

@(private = "file")
UP :: Vec3{0, 0, 1}

@(private = "file")
near :: proc(a, b: []Vec3, eps: f32) -> bool {
	if len(a) != len(b) do return false
	for p, i in a do if linalg.length(p - b[i]) > eps do return false
	return true
}

// A sculptor of an icosphere with two layers, the second recording a Draw stroke at
// `at`, and the mesh it sculpts. The first layer moved nothing.
@(private = "file")
layered :: proc(s: ^Sculptor, m: ^geom.Mesh, at: Vec3, pool: ^jobs.Pool = nil) {
	m^ = geom.icosphere(4)
	sculptor_init(s, m, pool, 64)
	_ = sculptor_layer_add(s)
	_ = sculptor_layer_add(s)
	sculptor_layer_rename(s, 1, "Pores")
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, at)
	_ = sculptor_stroke_end(s)
}

// A sculptor of `mesh`, as a rebuild makes one from the shown surface.
@(private = "file")
rebuilt :: proc(s: ^Sculptor, m: ^geom.Mesh, mesh: geom.Mesh, pool: ^jobs.Pool = nil) {
	m^ = mesh
	sculptor_init(s, m, pool, 64)
}

@(private = "file")
copy_mesh :: proc(m: geom.Mesh) -> geom.Mesh {
	out: geom.Mesh
	append(&out.positions, ..m.positions[:])
	append(&out.normals, ..m.normals[:])
	append(&out.indices, ..m.indices[:])
	return out
}

// The largest distance from a vertex of `a` to the surface of `b`.
@(private = "file")
farthest :: proc(a, b: geom.Mesh) -> f32 {
	bvh := geom.bvh_build_morton(b)
	defer geom.bvh_destroy(&bvh)
	worst: f32
	for p in a.positions {
		_, _, d, _ := geom.bvh_closest(bvh, b, p, 10)
		worst = max(worst, d)
	}
	return worst
}

// Onto a copy of the same surface, every vertex reads its own displacement: the layers
// come across whole, with their names, sliders and recording, and setting one to 0
// takes the same work off both.
@(test)
layers_carry_onto_the_same_surface :: proc(t: ^testing.T) {
	a, b: Sculptor
	ma, mb: geom.Mesh
	layered(&a, &ma, UP)
	defer {sculptor_destroy(&a); geom.mesh_destroy(&ma)}
	rebuilt(&b, &mb, copy_mesh(ma))
	defer {sculptor_destroy(&b); geom.mesh_destroy(&mb)}
	sm := surface_map_build(&a, &b)
	defer surface_map_destroy(&sm)
	testing.expect_value(t, sculptor_layers_project(&a, &b, sm), 2)
	testing.expect_value(t, sculptor_layer_name(&b.layers.list[1]), "Pores")
	testing.expect_value(t, sculptor_layer_recording(&b), 1)
	testing.expect_value(t, b.layers.named, a.layers.named)
	testing.expect(t, !sculptor_layer_used(b.layers.list[0]), "a layer that moved nothing took displacement")
	testing.expect(t, sculptor_layer_used(b.layers.list[1]), "the layer's work did not come across")
	// The undo memory stays empty: the rebuild is the step.
	testing.expect_value(t, len(b.history.done), 0)
	for s in ([]^Sculptor{&a, &b}) {
		testing.expect(t, sculptor_layer_set(s, 1, 0, true))
		_ = sculptor_stroke_end(s)
	}
	testing.expectf(t, farthest(mb, ma) < 1e-5, "taking the layer off left the copy %v from the original", farthest(mb, ma))
}

// Onto a remesh, setting the layer to 0 takes its work off the new surface too (to
// within the remesh's own error), where without the carry it would stay in the shape.
@(test)
layers_carry_onto_a_remesh :: proc(t: ^testing.T) {
	a, b: Sculptor
	ma, mb: geom.Mesh
	layered(&a, &ma, UP)
	defer {sculptor_destroy(&a); geom.mesh_destroy(&ma)}
	// What the layer added, at its highest.
	before := slice.clone(ma.positions[:], context.temp_allocator)
	testing.expect(t, sculptor_layer_set(&a, 1, 0, true))
	_ = sculptor_stroke_end(&a)
	height: f32
	for p, v in ma.positions do height = max(height, linalg.length(before[v] - p))
	testing.expect(t, sculptor_layer_set(&a, 1, 1, true))
	_ = sculptor_stroke_end(&a)

	remeshed, ok := geom.remesh_voxel(ma, 6000)
	testing.expect(t, ok)
	rebuilt(&b, &mb, remeshed)
	defer {sculptor_destroy(&b); geom.mesh_destroy(&mb)}
	sm := surface_map_build(&a, &b)
	defer surface_map_destroy(&sm)
	testing.expect_value(t, sculptor_layers_project(&a, &b, sm), 2)
	with_layer := farthest(mb, ma)
	for s in ([]^Sculptor{&a, &b}) {
		testing.expect(t, sculptor_layer_set(s, 1, 0, true))
		_ = sculptor_stroke_end(s)
	}
	without := farthest(mb, ma)
	testing.expectf(t, without < with_layer + 0.25 * height, "off on both, the remesh is %v from the original (%v with the layer, which raised it %v)", without, with_layer, height)
	testing.expect(t, height > 0.02, "the stroke raised too little to tell")
}

// Mirror and weld: the far side reads the kept side's displacement mirrored, and the
// seam's vertices stay on the plane, so the surface stays symmetric at any strength.
@(test)
layers_carry_through_mirror_and_weld :: proc(t: ^testing.T) {
	a, b: Sculptor
	ma, mb: geom.Mesh
	layered(&a, &ma, linalg.normalize(Vec3{0.4, 0.1, 1}))
	defer {sculptor_destroy(&a); geom.mesh_destroy(&ma)}
	mirrored, ok := geom.mesh_symmetrize(ma, 0, true, nil)
	testing.expect(t, ok)
	rebuilt(&b, &mb, mirrored)
	defer {sculptor_destroy(&b); geom.mesh_destroy(&mb)}
	wanted := sculptor_layers_wanted(&a)
	defer delete(wanted)
	sm := surface_map_build(&a, &b, {active = true, axis = .X, keep_positive = true}, wanted)
	defer surface_map_destroy(&sm)
	_ = sculptor_layers_project(&a, &b, sm)
	on_plane := make([dynamic]int, context.temp_allocator)
	for p, v in mb.positions do if p.x == 0 do append(&on_plane, v)
	testing.expect(t, sculptor_layer_set(&b, 1, 2.5, true))
	_ = sculptor_stroke_end(&b)
	for v in on_plane do testing.expect(t, mb.positions[v].x == 0, "a seam vertex left the plane")
	asymmetric := 0
	for p in mb.positions {
		q := Vec3{-p.x, p.y, p.z}
		found := false
		for r in mb.positions do if linalg.length(r - q) < 1e-4 {
			found = true
			break
		}
		if !found do asymmetric += 1
	}
	testing.expectf(t, asymmetric == 0, "%d vertices have no mirror image", asymmetric)
}

// A surface far from the old one takes none of the layers, which it keeps empty.
@(test)
layers_carry_nothing_far_away :: proc(t: ^testing.T) {
	a, b: Sculptor
	ma, mb: geom.Mesh
	layered(&a, &ma, UP)
	defer {sculptor_destroy(&a); geom.mesh_destroy(&ma)}
	moved := copy_mesh(ma)
	for &p in moved.positions do p += {5, 0, 0}
	rebuilt(&b, &mb, moved)
	defer {sculptor_destroy(&b); geom.mesh_destroy(&mb)}
	sm := surface_map_build(&a, &b)
	defer surface_map_destroy(&sm)
	testing.expect_value(t, sculptor_layers_project(&a, &b, sm), 2)
	testing.expect(t, !sculptor_layer_used(b.layers.list[1]), "a far surface took displacement")
}

// Threads give the same displacement, bit for bit, as one.
@(test)
layers_carry_by_threads_matches_one :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	runs: [2][]Vec3
	for &run, k in runs {
		p := &pool if k == 1 else nil
		a, b: Sculptor
		ma, mb: geom.Mesh
		layered(&a, &ma, UP, p)
		remeshed, _ := geom.remesh_voxel(ma, 6000, p)
		rebuilt(&b, &mb, remeshed, p)
		sm := surface_map_build(&a, &b)
		_ = sculptor_layers_project(&a, &b, sm)
		run = make([]Vec3, len(mb.positions), context.temp_allocator)
		for d, i in b.layers.list[1].delta do if d != nil do copy(run[b.nodes[i].vert_first:], d)
		surface_map_destroy(&sm)
		sculptor_destroy(&a)
		sculptor_destroy(&b)
		geom.mesh_destroy(&ma)
		geom.mesh_destroy(&mb)
	}
	testing.expect(t, slice.equal(runs[0], runs[1]), "threads changed the carried displacement")
}

// Mapping only what could read a layer's nodes carries the same displacement as
// mapping everything, while most of the new vertices are never searched for.
@(test)
layers_carry_reads_only_near_the_layer :: proc(t: ^testing.T) {
	a: Sculptor
	ma: geom.Mesh
	layered(&a, &ma, UP)
	defer {sculptor_destroy(&a); geom.mesh_destroy(&ma)}
	remeshed, _ := geom.remesh_voxel(ma, 6000)
	defer geom.mesh_destroy(&remeshed)
	wanted := sculptor_layers_wanted(&a)
	defer delete(wanted)
	carried: [2][]Vec3
	mapped: [2]int
	for &c, k in carried {
		b: Sculptor
		mb: geom.Mesh
		rebuilt(&b, &mb, copy_mesh(remeshed))
		sm := surface_map_build(&a, &b, {}, wanted if k == 1 else nil)
		for w in sm.weight do if w > 0 do mapped[k] += 1
		_ = sculptor_layers_project(&a, &b, sm)
		c = make([]Vec3, len(mb.positions), context.temp_allocator)
		for d, i in b.layers.list[1].delta do if d != nil do copy(c[b.nodes[i].vert_first:], d)
		surface_map_destroy(&sm)
		sculptor_destroy(&b)
		geom.mesh_destroy(&mb)
	}
	testing.expect(t, near(carried[0], carried[1], 1e-6), "the narrowed map carried other displacement")
	testing.expectf(t, mapped[1] < mapped[0] / 2, "the narrowed map searched for %d of %d vertices", mapped[1], mapped[0])
}

// Three levels with a recording layer on the top one, stroked at `at`.
@(private = "file")
layered_levels :: proc(at: Vec3) -> Levels {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	for _ in 0 ..< 2 do assert(levels_subdivide(&l))
	s := &levels_current(&l).sculptor
	_ = sculptor_layer_add(s)
	sculptor_layer_rename(s, 0, "Wrinkles")
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, at)
	_ = sculptor_stroke_end(s)
	return l
}

// Delete higher carries the top level's layer down to the base by the sync's own
// weights: setting it to 0 there leaves the base as setting it to 0 on the top level and
// going down would have. A layer on the level in between comes down too.
@(test)
layers_carry_down_on_delete_higher :: proc(t: ^testing.T) {
	want: []Vec3
	{
		l := layered_levels(UP)
		defer levels_destroy(&l)
		testing.expect(t, sculptor_layer_set(&levels_current(&l).sculptor, 0, 0, true))
		_ = sculptor_stroke_end(&levels_current(&l).sculptor)
		levels_set_current(&l, 0)
		want = slice.clone(levels_current(&l).mesh.positions[:], context.temp_allocator)
	}
	l := layered_levels(UP)
	defer levels_destroy(&l)
	levels_set_current(&l, 1)
	_ = sculptor_layer_add(&levels_current(&l).sculptor)
	levels_set_current(&l, 0)
	shaped := slice.clone(levels_current(&l).mesh.positions[:], context.temp_allocator)
	carried, dropped := levels_delete_higher(&l)
	testing.expect_value(t, carried, 2)
	testing.expect_value(t, dropped, 0)
	s := &levels_current(&l).sculptor
	testing.expect_value(t, len(s.layers.list), 2)
	testing.expect_value(t, sculptor_layer_name(&s.layers.list[0]), "Layer 1")
	testing.expect_value(t, sculptor_layer_name(&s.layers.list[1]), "Wrinkles")
	testing.expect(t, near(s.mesh.positions[:], shaped, 0), "carrying moved the base")
	testing.expect(t, sculptor_layer_used(s.layers.list[1]), "the top layer's work did not come down")
	testing.expect(t, sculptor_layer_set(s, 1, 0, true))
	_ = sculptor_stroke_end(s)
	moved: f32
	for p, v in shaped do moved = max(moved, linalg.length(p - want[v]))
	testing.expect(t, moved > 1e-3, "the layer did not reach the base")
	testing.expectf(t, near(s.mesh.positions[:], want, 1e-4), "off on the base, the shape is not what off on the top gives")
}

// Subdivide moves the top level's layer up by Loop's weights: setting it to 0 on the new
// level gives what subdividing without the layer gives, and the old top keeps its shape
// with the layer gone from its list, recording included. (The two new levels number
// their vertices apart, by where they are, so they are compared as surfaces.)
@(test)
layers_move_up_on_subdivide :: proc(t: ^testing.T) {
	two_levels :: proc() -> Levels {
		l: Levels
		levels_init(&l, geom.icosphere(2), nil, 64)
		assert(levels_subdivide(&l))
		s := &levels_current(&l).sculptor
		_ = sculptor_layer_add(s)
		sculptor_stroke_begin(s)
		_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, UP)
		_ = sculptor_stroke_end(s)
		return l
	}
	a := two_levels()
	defer levels_destroy(&a)
	testing.expect(t, sculptor_layer_set(&levels_current(&a).sculptor, 0, 0, true))
	_ = sculptor_stroke_end(&levels_current(&a).sculptor)
	testing.expect(t, levels_subdivide(&a))
	want := levels_current(&a).mesh

	l := two_levels()
	defer levels_destroy(&l)
	old_top := slice.clone(levels_current(&l).mesh.positions[:], context.temp_allocator)
	testing.expect(t, levels_subdivide(&l, carry_layers = true))
	below, top := &l.levels[1].sculptor, &l.levels[2].sculptor
	testing.expect_value(t, len(below.layers.list), 0)
	testing.expect_value(t, sculptor_layer_recording(below), -1)
	testing.expect_value(t, len(top.layers.list), 1)
	testing.expect_value(t, sculptor_layer_recording(top), 0)
	testing.expect(t, near(below.mesh.positions[:], old_top, 0), "the old top moved")
	moved := farthest(top.mesh^, want)
	testing.expect(t, sculptor_layer_set(top, 0, 0, true))
	_ = sculptor_stroke_end(top)
	worst := max(farthest(top.mesh^, want), farthest(want, top.mesh^))
	testing.expectf(t, moved > 1e-3 && worst < 1e-5, "off on the new level, the shape is %v from the subdivision without the layer (%v with it)", worst, moved)
}

// Moving layers up by threads gives the new level the same layer, bit for bit, as one
// thread does.
@(test)
layers_move_up_by_threads_matches_one :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	runs: [2][]Vec3
	for &run, k in runs {
		l: Levels
		levels_init(&l, geom.icosphere(3), &pool if k == 1 else nil, 64)
		s := &levels_current(&l).sculptor
		_ = sculptor_layer_add(s)
		sculptor_stroke_begin(s)
		_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, UP)
		_ = sculptor_stroke_end(s)
		testing.expect(t, levels_subdivide(&l, carry_layers = true))
		top := &levels_current(&l).sculptor
		run = make([]Vec3, len(top.mesh.positions), context.temp_allocator)
		for d, i in top.layers.list[0].delta do if d != nil do copy(run[top.nodes[i].vert_first:], d)
		levels_destroy(&l)
	}
	testing.expect(t, slice.any_of_proc(runs[0], proc(d: Vec3) -> bool {return d != {}}), "nothing moved up")
	testing.expect(t, slice.equal(runs[0], runs[1]), "threads changed the layer moved up")
}

// A layer slider still held when Subdivide moves the layers up ends on the old top, so
// no open step there names a layer it no longer has.
@(test)
layers_move_up_ending_a_held_slider :: proc(t: ^testing.T) {
	l: Levels
	levels_init(&l, geom.icosphere(2), nil, 64)
	defer levels_destroy(&l)
	s := &levels_current(&l).sculptor
	_ = sculptor_layer_add(s)
	sculptor_stroke_begin(s)
	_ = apply_dab(s, {kind = .Draw, radius = 0.5, strength = 1}, UP)
	_ = sculptor_stroke_end(s)
	testing.expect(t, sculptor_layer_set(s, 0, 0.5, true))
	testing.expect(t, s.history.recording, "the drag is under way")
	testing.expect(t, levels_subdivide(&l, carry_layers = true))
	testing.expect(t, !l.levels[0].sculptor.history.recording, "the drag was left open on the old top")
	testing.expect_value(t, levels_current(&l).sculptor.layers.list[0].strength, 0.5)
}
