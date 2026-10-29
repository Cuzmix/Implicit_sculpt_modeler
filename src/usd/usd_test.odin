package usd

import "core:math/linalg"
import "core:slice"
import "core:testing"

import "../geom"
import "../zip"

@(private = "file")
text_bytes :: proc(s: string) -> []u8 {return transmute([]u8)s}

@(private = "file")
expect_near :: proc(t: ^testing.T, got, want: geom.Vec3, loc := #caller_location) {
	testing.expectf(t, linalg.length(got - want) < 1e-5, "%v, not %v", got, want, loc = loc)
}

@(test)
usda_reads_back_what_the_usda_writer_wrote :: proc(t: ^testing.T) {
	sphere := geom.icosphere(3)
	defer geom.mesh_destroy(&sphere)
	rgb := make([][3]u8, len(sphere.positions))
	defer delete(rgb)
	for &c, v in rgb do c = {u8(v), u8(255 - v % 256), 128}
	groups := make([]u16, len(sphere.indices) / 3)
	defer delete(groups)
	for &g, f in groups do g = u16(f % 5)
	out := make([dynamic]u8)
	defer delete(out)
	geom.mesh_write_usda(&out, {name = "Ball", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:], colors = rgb, groups = groups, scale = 2, offset = {1, 0, 0}})
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	_, err, line := read(&parts, out[:])
	testing.expectf(t, err == .None, "%v at line %d", err, line)
	testing.expect_value(t, len(parts), 1)
	if len(parts) != 1 do return
	p := parts[0]
	testing.expect_value(t, p.name, "Ball")
	testing.expect(t, slice.equal(p.mesh.indices[:], sphere.indices[:]), "triangles")
	worst: f32
	for q, v in p.mesh.positions do worst = max(worst, linalg.length(q - (sphere.positions[v] * 2 + {1, 0, 0})))
	testing.expectf(t, worst < 1e-5, "positions off by %v", worst)
	for c, v in p.colors {
		if c != {rgb[v].r, rgb[v].g, rgb[v].b, 255} {
			testing.expectf(t, false, "vertex %d: %v, not %v", v, c, rgb[v])
			break
		}
	}
	testing.expect(t, slice.equal(p.groups[:], groups), "polygroups")
}

@(test)
usda_places_prims_and_follows_what_a_viewer_shows :: proc(t: ^testing.T) {
	text := `#usda 1.0
(
    doc = """A test
with lines"""
    upAxis = "Z"
    metersPerUnit = 0.5
)

def Xform "World" (
    kind = "group"
)
{
    double3 xformOp:translate = (10, 0, 0)
    float3 xformOp:rotateXYZ = (0, 0, 90)
    uniform token[] xformOpOrder = ["xformOp:translate", "xformOp:rotateXYZ"]

    def Mesh "Quad"
    {
        int[] faceVertexCounts = [4, 3]
        int[] faceVertexIndices = [0, 1, 2, 3, 0, 1, 2]
        int[] holeIndices = [1]
        point3f[] points.timeSamples = {
            2: [(9, 9, 9), (9, 9, 9), (9, 9, 9), (9, 9, 9)],
            1: [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)],
        }
        color3f[] primvars:displayColor = [(1, 0, 0), (0, 0, 1)] (
            interpolation = "faceVarying"
        )
        int[] primvars:displayColor:indices = [0, 0, 1, 1, 0, 0, 0]
        rel material:binding = </World/Mat>
        def GeomSubset "Top"
        {
            uniform token familyName = "materialBind"
            int[] indices = [0]
        }
    }

    def Mesh "Hidden"
    {
        token visibility = "invisible"
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
    }

    def Mesh "Off" (
        active = false
    )
    {
    }

    def Mesh "Left" (
        prepend references = @other.usda@</Thing>
    )
    {
        uniform token orientation = "leftHanded"
        int[] faceVertexCounts = [3]
        int[] faceVertexIndices = [0, 1, 2]
        point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
        color3f[] primvars:displayColor = [(0, 1, 0)]
    }
    variantSet "look" = {
        "a" {
            def Mesh "Variant" {}
        }
    }
}

class Mesh "Template"
{
    int[] faceVertexCounts = [3]
    int[] faceVertexIndices = [0, 1, 2]
    point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
}
`
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	skipped, err, line := read(&parts, text_bytes(text))
	testing.expectf(t, err == .None, "%v at line %d", err, line)
	testing.expect_value(t, len(parts), 2)
	testing.expect_value(t, skipped.composed, 2)
	if len(parts) != 2 do return
	quad := parts[0]
	testing.expect_value(t, quad.name, "Quad")
	// The hole (face 1) is left out: two triangles of the quad.
	testing.expect(t, slice.equal(quad.mesh.indices[:], []u32{0, 1, 2, 0, 2, 3}), "the quad's fan")
	// Point (1, 0, 0): turned 90 degrees about z to (0, 1, 0), moved to (10, 1, 0), at
	// 0.5 m a unit (5, 0.5, 0), then Z up to Y up: (5, 0, -0.5).
	expect_near(t, quad.mesh.positions[1], {5, 0, -0.5})
	// Corner colours by index: vertices 0 and 1 red, 2 and 3 blue.
	testing.expect(t, slice.equal(quad.colors[:], []geom.Vertex_Color{{255, 0, 0, 255}, {255, 0, 0, 255}, {0, 0, 255, 255}, {0, 0, 255, 255}}), "faceVarying colours")
	testing.expect(t, slice.equal(quad.groups[:], []u16{1, 1}), "the subset's group")
	left := parts[1]
	testing.expect_value(t, left.name, "Left")
	testing.expect(t, slice.equal(left.mesh.indices[:], []u32{0, 2, 1}), "leftHanded turned round")
	testing.expect_value(t, left.colors[2], geom.Vertex_Color{0, 255, 0, 255})
}

@(test)
usda_refuses_what_it_cannot_follow :: proc(t: ^testing.T) {
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	_, not_usd, _ := read(&parts, text_bytes("#usdb 1.0\n"))
	testing.expect_value(t, not_usd, geom.Mesh_File_Error.Not_Recognised)
	_, unclosed, line := read(&parts, text_bytes("#usda 1.0\n\ndef Mesh \"M\"\n{\n    int[] faceVertexCounts = [3\n"))
	testing.expect_value(t, unclosed, geom.Mesh_File_Error.Bad_Structure)
	testing.expect(t, line >= 5, "the line")
	_, bad_index, _ := read(&parts, text_bytes("#usda 1.0\ndef Mesh \"M\" { int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0, 1, 7]\n point3f[] points = [(0,0,0),(1,0,0),(0,1,0)] }\n"))
	testing.expect_value(t, bad_index, geom.Mesh_File_Error.Bad_Index)
	_, empty, _ := read(&parts, text_bytes("#usda 1.0\ndef Xform \"X\" {}\n"))
	testing.expect_value(t, empty, geom.Mesh_File_Error.Empty)
	// Every cut of a good file is refused or read, never a crash.
	good := "#usda 1.0\n(upAxis = \"Z\")\ndef Mesh \"M\" (active = true) { int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0, 1, 2]\n point3f[] points = [(0,0,0),(1,0,0),(0,1,0)]\n color3f[] primvars:displayColor = [(1, 0.5, 0)] }\n"
	for n in 0 ..< len(good) {
		cut := make([dynamic]geom.Mesh_Part)
		_, _, _ = read(&cut, text_bytes(good[:n]))
		geom.mesh_parts_destroy(&cut)
	}
	free_all(context.temp_allocator)
}

@(test)
lz4_blocks_decode_and_refuse_what_overflows :: proc(t: ^testing.T) {
	// One literal, a match of 19 one back (overlapping itself), then two last literals.
	block := []u8{0x1F, 'a', 1, 0, 0, 0x20, 'b', 'c'}
	out: [32]u8
	n, ok := lz4_block(block, out[:])
	testing.expect(t, ok)
	testing.expect_value(t, string(out[:n]), "aaaaaaaaaaaaaaaaaaaabc")
	_, small := lz4_block(block, out[:10])
	testing.expect(t, !small, "a match past the room is refused")
	_, back := lz4_block([]u8{0x10, 'a', 2, 0}, out[:])
	testing.expect(t, !back, "an offset before the start is refused")
	_, cut := lz4_block(block[:3], out[:])
	testing.expect(t, !cut, "a cut offset is refused")
}

@(test)
usdz_reads_the_layer_it_packs :: proc(t: ^testing.T) {
	layer := "#usda 1.0\ndef Mesh \"Tri\" { int[] faceVertexCounts = [3]\n int[] faceVertexIndices = [0, 1, 2]\n point3f[] points = [(0,0,0),(1,0,0),(0,1,0)] }\n"
	packed, ok := zip.write({{name = "scene.usda", data = text_bytes(layer)}, {name = "textures/x.png", data = text_bytes("png")}}, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, recognised(packed), "known by its first entry")
	parts := make([dynamic]geom.Mesh_Part)
	defer geom.mesh_parts_destroy(&parts)
	_, err, _ := read(&parts, packed)
	testing.expect_value(t, err, geom.Mesh_File_Error.None)
	testing.expect_value(t, len(parts), 1)
	// A crate cut short or with its version changed is refused, never trusted.
	crate := make([]u8, 88, context.temp_allocator)
	copy(crate, USDC_MAGIC)
	crate[9] = 8
	_, cut, _ := read(&parts, crate)
	testing.expect(t, cut != .None, "an empty table is refused")
	crate[9] = 3
	_, old, _ := read(&parts, crate)
	testing.expect_value(t, old, geom.Mesh_File_Error.Not_Recognised)
	free_all(context.temp_allocator)
}
