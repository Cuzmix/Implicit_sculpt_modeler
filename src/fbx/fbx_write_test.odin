package fbx

import "core:math/linalg"
import "core:testing"

import "../geom"

// What geom.mesh_write_fbx writes reads back through ufbx as it went out: the points (in
// metres, Y up), the triangles, the vertex colours, the material's colour and a shape key
// for each layer.
@(test)
fbx_written_reads_back :: proc(t: ^testing.T) {
	m := geom.icosphere(2)
	defer geom.mesh_destroy(&m)
	colors := make([][3]u8, len(m.positions), context.temp_allocator)
	for &c, v in colors do c = {u8(v % 256), 128, u8(255 - v % 256)}
	moved := [?]u32{0, 5, 9}
	deltas := [?]geom.Vec3{{0, 0.1, 0}, {0.05, 0, 0}, {0, 0, -0.2}}
	out := make([dynamic]u8)
	defer delete(out)
	ok := geom.mesh_write_fbx(&out, {
		name      = "Ball",
		positions = m.positions[:],
		normals   = m.normals[:],
		indices   = m.indices[:],
		colors    = colors,
		scale     = 1,
		material  = geom.Export_Material{name = "Clay", base = {0.8, 0.4, 0.2}, roughness = 0.5},
		morphs    = {{name = "Lift", weight = 0.5, vertices = moved[:], deltas = deltas[:]}},
	})
	testing.expect(t, ok)
	testing.expect(t, recognised(out[:]), "not recognised as FBX")
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	look: geom.Mesh_Look
	defer geom.mesh_look_destroy(&look)
	err, reason, rig := read(&parts, out[:], &look)
	testing.expectf(t, err == .None, "read failed: %v %s", err, reason)
	testing.expect_value(t, rig.shapes, 1)
	if len(parts) != 1 do return
	p := parts[0]
	testing.expect_value(t, p.name, "Ball")
	testing.expect_value(t, len(p.mesh.indices), len(m.indices))
	testing.expect_value(t, len(p.mesh.positions), len(m.positions))
	// The points read are the base, the shown less the layer at its strength.
	worst: f32
	for q, v in p.mesh.positions {
		want := m.positions[v]
		for u, i in moved do if int(u) == v do want -= 0.5 * deltas[i]
		worst = max(worst, linalg.length(q - want))
	}
	testing.expectf(t, worst < 1e-5, "the points moved up to %v", worst)
	testing.expect_value(t, len(p.colors), len(m.positions))
	if len(p.colors) == len(colors) do for c, v in p.colors do if c.r != colors[v].r || c.g != colors[v].g || c.b != colors[v].b {
		testing.expectf(t, false, "vertex %d is %v, not %v", v, c, colors[v])
		break
	}
	testing.expect_value(t, len(look.materials), 1)
	if len(look.materials) == 1 {
		testing.expect_value(t, look.materials[0].name, "Clay")
		testing.expectf(t, abs(look.materials[0].roughness - 0.5) < 0.02, "roughness %v", look.materials[0].roughness)
	}
}

// Quads with UVs go out as quads: each reads back as one polygon of two triangles, its
// UVs at its corners; and per-face materials read as each face's own.
@(test)
fbx_written_quads_read_back :: proc(t: ^testing.T) {
	positions := [?]geom.Vec3{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {0, 1, 0}, {1, 1, 0}, {2, 1, 0}}
	normals := [?]geom.Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}}
	quads := [?][4]u32{{0, 1, 4, 3}, {1, 2, 5, 4}}
	uvs := [?][4][2]f32{{{0, 0}, {0.5, 0}, {0.5, 1}, {0, 1}}, {{0.5, 0}, {1, 0}, {1, 1}, {0.5, 1}}}
	slots := [?]u8{0, 1}
	greens := [?]geom.Export_Material{{name = "Green", base = {0, 1, 0}, roughness = 0.5}}
	out := make([dynamic]u8)
	defer delete(out)
	testing.expect(t, geom.mesh_write_fbx(&out, {
		name            = "Sheet",
		positions       = positions[:],
		normals         = normals[:],
		quads           = quads[:],
		uvs             = uvs[:],
		scale           = 1,
		material        = geom.Export_Material{name = "Red", base = {1, 0, 0}, roughness = 0.5},
		group_materials = greens[:],
		face_material   = slots[:],
	}))
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	look: geom.Mesh_Look
	defer geom.mesh_look_destroy(&look)
	err, reason, _ := read(&parts, out[:], &look)
	testing.expectf(t, err == .None, "read failed: %v %s", err, reason)
	if len(parts) != 1 do return
	p := parts[0]
	testing.expect_value(t, len(p.mesh.indices), 12)
	testing.expect_value(t, len(p.polys), 4)
	if len(p.polys) == 4 {
		testing.expect(t, p.polys[0] == p.polys[1] && p.polys[2] == p.polys[3] && p.polys[0] != p.polys[2], "the quads did not stay whole")
	}
	testing.expect_value(t, len(look.materials), 2)
	if len(p.materials) == 4 && len(look.materials) == 2 {
		testing.expect_value(t, look.materials[p.materials[0]].name, "Red")
		testing.expect_value(t, look.materials[p.materials[3]].name, "Green")
	}
	testing.expect_value(t, len(p.uvs), 12)
}
