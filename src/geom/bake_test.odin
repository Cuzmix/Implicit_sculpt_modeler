package geom

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"

import "../jobs"

// A quad sphere and its triangles as a source: painted red on the +x side, group 1 above
// the middle and group 2 below, the upper group in a material of its own.
@(private = "file")
Painted :: struct {
	q:        Quad_Mesh,
	uvs:      Uv_Layout,
	source:   Mesh,
	bvh:      Bvh,
	paint:    [][4]u8,
	groups:   []u16,
	slots:    []u8,
	surfaces: []Bake_Surface,
}

@(private = "file")
painted_make :: proc(t: ^testing.T) -> (p: Painted, ok: bool) {
	sphere := icosphere(5)
	defer mesh_destroy(&sphere)
	sphere_bvh := bvh_build(sphere)
	defer bvh_destroy(&sphere_bvh)
	p.q, _, ok = mesh_retopo(sphere, &sphere_bvh, 1500, nil)
	if !ok do return
	p.uvs = quad_uv_unwrap(p.q, 4.0 / 256)
	p.source = quad_mesh_triangulate(p.q)
	mesh_recompute_normals(&p.source)
	p.bvh = bvh_build(p.source)
	p.paint = make([][4]u8, len(p.source.positions))
	for v, i in p.source.positions do p.paint[i] = {255, 0, 0, 255} if v.x > 0 else {}
	tris := len(p.source.indices) / 3
	p.groups = make([]u16, tris)
	p.slots = make([]u8, tris)
	for t in 0 ..< tris {
		y := p.source.positions[p.source.indices[3 * t]].y + p.source.positions[p.source.indices[3 * t + 1]].y + p.source.positions[p.source.indices[3 * t + 2]].y
		p.groups[t] = 1 if y > 0 else 2
		p.slots[t] = 1 if y > 0 else 0
	}
	p.surfaces = make([]Bake_Surface, 2)
	p.surfaces[0] = {base = {0.2, 0.2, 0.2}, metallic = 0, roughness = 0.6}
	p.surfaces[1] = {base = {1, 0.77, 0.34}, metallic = 1, roughness = 0.3}
	return p, true
}

@(private = "file")
painted_destroy :: proc(p: ^Painted) {
	quad_mesh_destroy(&p.q)
	uv_layout_destroy(&p.uvs)
	mesh_destroy(&p.source)
	bvh_destroy(&p.bvh)
	delete(p.paint)
	delete(p.groups)
	delete(p.slots)
	delete(p.surfaces)
}

@(private = "file")
painted_source :: proc(p: ^Painted, rays: int, reach: f32) -> Bake_Source {
	return {mesh = p.source, bvh = &p.bvh, paint = p.paint, groups = p.groups, slots = p.slots, surfaces = p.surfaces, occlusion_rays = rays, occlusion_reach = reach}
}

// The base colour is the paint where painted and the face's material elsewhere; the ID
// map holds the groups' colours and no others, chart edges included (and group 0's
// beyond them); on a lone sphere
// nothing occludes, and roughness and metal are the faces' materials'.
@(test)
bake_set_reads_paint_groups_and_materials :: proc(t: ^testing.T) {
	p, ok := painted_make(t)
	defer painted_destroy(&p)
	if !testing.expect(t, ok) do return
	b := bake_maps(p.q, p.uvs, painted_source(&p, 8, 0.5), 256, 0.1, {.Base_Color, .Orm, .Id}, nil)
	defer bake_maps_destroy(&b)
	defer free_all(context.temp_allocator)
	grey: [3]u8 = 124
	gold := [3]u8{255, 227, 158}
	red, plain, gilded := 0, 0, 0
	// Texels no chart's edge reaches show group 0, the object's own.
	one, two, none := group_color_srgb(1), group_color_srgb(2), group_color_srgb(0)
	strange, open, shut := 0, 0, 0
	for at in 0 ..< 256 * 256 {
		c := b.base_color[4 * at:][:4]
		if c[3] == 0 do continue
		rgb := [3]u8{c[0], c[1], c[2]}
		if rgb == {255, 0, 0} do red += 1
		else if rgb == grey do plain += 1
		else if rgb == gold do gilded += 1
		id := [3]u8{b.id[4 * at], b.id[4 * at + 1], b.id[4 * at + 2]}
		if id != one && id != two && id != none do strange += 1
		o := b.orm[4 * at:][:4]
		if o[0] == 255 do open += 1
		if o[0] < 128 do shut += 1
	}
	testing.expectf(t, red > b.covered / 3, "%d red texels of %d", red, b.covered)
	testing.expectf(t, plain > b.covered / 8 && gilded > b.covered / 8, "%d plain and %d gilded texels of %d", plain, gilded, b.covered)
	testing.expectf(t, strange == 0, "%d texels of the ID map in no group's colour", strange)
	testing.expectf(t, open > 99 * b.covered / 100 && shut == 0, "%d of %d texels open, %d shut", open, b.covered, shut)
	// Roughness and metal: the gold's or the grey's, but for dilated blends at chart edges.
	exact := 0
	for at in 0 ..< 256 * 256 {
		o := b.orm[4 * at:][:4]
		if (o[1] == 153 && o[2] == 0) || (o[1] == 77 && o[2] == 255) do exact += 1
	}
	testing.expectf(t, exact >= b.covered, "%d texels with a material's roughness and metal, %d covered", exact, b.covered)
}

// Inside a closed shell every occlusion ray is stopped; and the bake set comes out the
// same on the pool as on one thread, byte for byte.
@(test)
bake_set_occludes_and_is_the_same_on_the_pool :: proc(t: ^testing.T) {
	p, ok := painted_make(t)
	defer painted_destroy(&p)
	if !testing.expect(t, ok) do return
	// The sphere with a shell 1.3 times its size around it, facing in.
	n := len(p.source.positions)
	shell := Mesh{}
	for v in p.source.positions do append(&shell.positions, v)
	for v in p.source.positions do append(&shell.positions, 1.3 * v)
	tris := len(p.source.indices) / 3
	for i in p.source.indices do append(&shell.indices, i)
	for k in 0 ..< tris {
		f := p.source.indices[3 * k:]
		append(&shell.indices, f[0] + u32(n), f[2] + u32(n), f[1] + u32(n))
	}
	resize(&shell.normals, len(shell.positions))
	mesh_recompute_normals(&shell)
	defer mesh_destroy(&shell)
	bvh := bvh_build(shell)
	defer bvh_destroy(&bvh)
	inside := Bake_Source{mesh = shell, bvh = &bvh, occlusion_rays = 8, occlusion_reach = 2}
	b := bake_maps(p.q, p.uvs, inside, 128, 0.1, {.Orm}, nil)
	defer bake_maps_destroy(&b)
	free_all(context.temp_allocator)
	shut := 0
	for at in 0 ..< 128 * 128 do if b.orm[4 * at + 3] == 255 && b.orm[4 * at] == 0 do shut += 1
	testing.expectf(t, shut >= b.covered, "%d texels fully occluded of %d covered", shut, b.covered)

	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	kinds := bit_set[Bake_Kind]{.Base_Color, .Orm, .Id}
	serial := bake_maps(p.q, p.uvs, painted_source(&p, 8, 0.5), 128, 0.1, kinds, nil)
	defer bake_maps_destroy(&serial)
	parallel := bake_maps(p.q, p.uvs, painted_source(&p, 8, 0.5), 128, 0.1, kinds, &pool)
	defer bake_maps_destroy(&parallel)
	free_all(context.temp_allocator)
	for pair in ([?][2][]u8{{serial.normal, parallel.normal}, {serial.base_color, parallel.base_color}, {serial.orm, parallel.orm}, {serial.id, parallel.id}}) {
		testing.expect(t, len(pair[0]) == len(pair[1]) && mem.compare(pair[0], pair[1]) == 0, "the pool changed a map")
	}
}

// The ID map's colours are the viewport's (mesh.vert.slang's group_color) for a few groups.
@(test)
group_colors_match_the_viewport :: proc(t: ^testing.T) {
	// Worked from the shader's formula by hand for groups 0, 1 and 2, through the sRGB curve.
	testing.expect_value(t, group_color_srgb(0), [3]u8{225, 209, 157})
	testing.expect_value(t, group_color_srgb(1), [3]u8{165, 136, 196})
	testing.expect_value(t, group_color_srgb(2), [3]u8{157, 225, 168})
}

// A reader that builds the frame from the split mesh's normals, tangents and UVs, as
// glTF and MikkTSpace say, turns the baked normal map back into the sculpt's normals: a
// bumpy sphere baked onto its own retopology, checked at a texel inside each triangle.
@(test)
normal_map_reads_back_through_the_tangents :: proc(t: ^testing.T) {
	bumpy := icosphere(5)
	defer mesh_destroy(&bumpy)
	for &p in bumpy.positions do p *= 1 + 0.06 * math.sin(6 * p.x) * math.sin(5 * p.y + 1)
	mesh_recompute_normals(&bumpy)
	bvh := bvh_build(bumpy)
	defer bvh_destroy(&bvh)
	q, _, ok := mesh_retopo(bumpy, &bvh, 600, nil)
	defer quad_mesh_destroy(&q)
	if !testing.expect(t, ok) do return
	uvs := quad_uv_unwrap(q, 4.0 / 512)
	defer uv_layout_destroy(&uvs)
	SIZE :: 512
	b := bake_maps(q, uvs, {mesh = bumpy, bvh = &bvh}, SIZE, 0.2, {}, nil)
	defer bake_maps_destroy(&b)
	defer free_all(context.temp_allocator)
	normals := quad_mesh_normals(q, context.temp_allocator)
	frame := quad_mesh_tangents(q, uvs, normals, context.temp_allocator)
	positions, split_normals, texcoords, indices := quad_mesh_split_uvs(q, uvs, normals, frame, context.temp_allocator)
	for tan in frame.tangents {
		l := linalg.length(tan.xyz)
		testing.expectf(t, abs(l - 1) < 1e-4 && abs(tan.w) == 1, "tangent %v is not unit with a sign", tan)
	}
	stack := make([dynamic]u32, 0, 64, context.temp_allocator)
	checked, off, worst := 0, 0, f32(0)
	for tri in 0 ..< len(indices) / 3 {
		c := indices[3 * tri:][:3]
		uv := (texcoords[c[0]] + texcoords[c[1]] + texcoords[c[2]]) / 3
		x, y := int(uv.x * SIZE), int((1 - uv.y) * SIZE)
		centre := [2]f32{(f32(x) + 0.5) / SIZE, 1 - (f32(y) + 0.5) / SIZE}
		// The texel centre's place in the triangle, by its UVs.
		a, bb, cc := texcoords[c[0]], texcoords[c[1]], texcoords[c[2]]
		area := (bb.x - a.x) * (cc.y - a.y) - (cc.x - a.x) * (bb.y - a.y)
		if abs(area) < 1e-12 do continue
		w1 := ((centre.x - a.x) * (cc.y - a.y) - (cc.x - a.x) * (centre.y - a.y)) / area
		w2 := ((bb.x - a.x) * (centre.y - a.y) - (centre.x - a.x) * (bb.y - a.y)) / area
		w := [3]f32{1 - w1 - w2, w1, w2}
		if w[0] < 0.05 || w[1] < 0.05 || w[2] < 0.05 do continue
		p, vn, vt: Vec3
		handed: f32
		for k in 0 ..< 3 {
			p += w[k] * positions[c[k]]
			vn += w[k] * split_normals[c[k]]
			vt += w[k] * frame.tangents[c[k]].xyz
			handed += w[k] * frame.tangents[c[k]].w
		}
		vb := (f32(1) if handed >= 0 else -1) * linalg.cross(vn, vt)
		texel := b.normal[4 * (y * SIZE + x):]
		m := Vec3{f32(texel[0]), f32(texel[1]), f32(texel[2])} / 255 * 2 - 1
		read := linalg.normalize0(m.x * vt + m.y * vb + m.z * vn)
		// The sculpt's normal where the bake's rays meet it.
		n := linalg.normalize0(vn)
		ot, otri, ohit := bvh_raycast_with(bvh, bumpy, p - 1e-3 * n, n, 0.2, &stack)
		it, itri, ihit := bvh_raycast_with(bvh, bumpy, p + 1e-3 * n, -n, 0.2, &stack)
		hit_tri: u32
		hit_at: Vec3
		switch {
		case ohit && (!ihit || ot <= it): hit_tri, hit_at = otri, p - 1e-3 * n + ot * n
		case ihit:                       hit_tri, hit_at = itri, p + 1e-3 * n - it * n
		case:                            continue
		}
		want := source_normal(bumpy, hit_tri, triangle_weights(bumpy, hit_tri, hit_at))
		angle := math.acos(clamp(linalg.dot(read, want), -1, 1)) * 180 / math.PI
		worst = max(worst, angle)
		checked += 1
		if angle > 2 do off += 1
	}
	testing.expectf(t, checked > len(indices) / 3 / 2, "only %d triangles checked", checked)
	testing.expectf(t, off == 0, "%d of %d texels read back more than 2 degrees off (worst %.2f)", off, checked, worst)
}
