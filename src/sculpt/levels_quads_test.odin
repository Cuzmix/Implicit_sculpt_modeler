package sculpt

import "core:testing"

import "../geom"

// A retopologized object's quads and UVs read back from the scene file on the same
// corners, though reading renumbers the vertices.
@(test)
quads_round_trip_the_file :: proc(t: ^testing.T) {
	source := geom.icosphere(4)
	defer geom.mesh_destroy(&source)
	bvh := geom.bvh_build(source)
	defer geom.bvh_destroy(&bvh)
	q, _, ok := geom.mesh_retopo(source, &bvh, 600, nil)
	if !testing.expect(t, ok) do return
	uv := geom.quad_uv_unwrap(q, 0.01)
	old_to_new := make([]u32, len(q.positions), context.temp_allocator)
	l: Levels
	levels_init(&l, geom.quad_mesh_triangulate(q), nil, 64, old_to_new)
	defer levels_destroy(&l)
	delete(q.positions)
	for &f in q.quads do for &v in f do v = old_to_new[v]
	levels_set_quads(&l, q.quads)
	levels_set_uvs(&l, uv)
	testing.expect(t, levels_subdivide(&l))
	out := make([dynamic]u8)
	defer delete(out)
	levels_write(&l, &out)

	back: Levels
	r := geom.byte_reader(out[:])
	testing.expect(t, levels_read(&back, &r, nil, 64), "read failed")
	defer levels_destroy(&back)
	testing.expect(t, levels_has_quads(&back) && levels_has_uvs(&back), "quads or UVs were lost")
	if !levels_has_uvs(&back) do return
	a, b := levels_quad_mesh(&l), levels_quad_mesh(&back)
	testing.expect_value(t, len(b.quads), len(a.quads))
	testing.expect_value(t, back.faces.uv.charts, l.faces.uv.charts)
	for f, i in a.quads {
		for k in 0 ..< 4 do testing.expect(t, a.positions[f[k]] == b.positions[b.quads[i][k]], "a corner moved")
		testing.expect(t, back.faces.uv.uvs[i] == l.faces.uv.uvs[i] && back.faces.uv.chart[i] == l.faces.uv.chart[i])
	}
	// Deleting the levels above keeps them; dynamic topology drops them.
	levels_set_current(&back, 0)
	levels_delete_higher(&back)
	testing.expect(t, levels_has_quads(&back))
	testing.expect(t, levels_dyn_enable(&back))
	testing.expect(t, !levels_has_quads(&back), "dynamic topology kept the quads")
}
