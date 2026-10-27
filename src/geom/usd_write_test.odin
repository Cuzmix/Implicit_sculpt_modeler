package geom

import "core:mem"
import "core:strings"
import "core:testing"

import "../jobs"

// Two triangles with paint, groups and three layers (one moving a point, one moving none,
// one whose name repeats the first's once made an identifier) write as this exact text:
// the points less the first layer at its weight, the shapes by their own names as tokens
// and by identifiers as prims, an empty shape given one still point, and the weights both
// as the default and keyed at frame 1.
@(test)
usda_of_two_triangles :: proc(t: ^testing.T) {
	positions := []Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0.5}, {0, 1, 0}}
	normals := []Vec3{{0, 0, 2}, {0, 0, 1}, {0, 0, 1}, {}}
	m := Mesh_Export {
		name      = "Head 2",
		positions = positions,
		normals   = normals,
		indices   = []u32{0, 1, 2, 0, 2, 3},
		colors    = [][3]u8{{255, 0, 0}, {255, 0, 0}, {0, 255, 0}, {0, 0, 0}},
		groups    = []u16{3, 5},
		morphs    = []Morph_Target {
			{name = "Big \"ears\"", weight = 0.5, vertices = []u32{2}, deltas = []Vec3{{0, 0, 1}}},
			{name = "Off", weight = 0},
			{name = "Big 'ears'", weight = 1.5},
		},
	}
	out := make([dynamic]u8)
	defer delete(out)
	mesh_write_usda(&out, m)
	free_all(context.temp_allocator)
	want := `#usda 1.0
(
    defaultPrim = "Root"
    doc = "Written by Sculpt"
    metersPerUnit = 1
    upAxis = "Y"
)

def SkelRoot "Root"
{
    def Mesh "Head_2" (
        prepend apiSchemas = ["SkelBindingAPI"]
    )
    {
        float3[] extent = [(0, 0, 0), (1, 1, 0)]
        int[] faceVertexCounts = [3, 3]
        int[] faceVertexIndices = [0, 1, 2, 0, 2, 3]
        normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 1, 0)] (
            interpolation = "vertex"
        )
        point3f[] points = [(0, 0, 0), (1, 0, 0), (1, 1, 0), (0, 1, 0)]
        color3f[] primvars:displayColor = [(1, 0, 0), (1, 0, 0), (0, 1, 0), (0, 0, 0)] (
            interpolation = "vertex"
        )
        int[] primvars:polygroup = [3, 5] (
            interpolation = "uniform"
        )
        uniform token subdivisionScheme = "none"
        uniform token[] skel:blendShapes = ["Big \"ears\"", "Off", "Big 'ears'"]
        rel skel:blendShapeTargets = [</Root/Head_2/Big__ears_>, </Root/Head_2/Off>, </Root/Head_2/Big__ears__2>]
        rel skel:skeleton = </Root/Skel>

        def BlendShape "Big__ears_"
        {
            uniform vector3f[] offsets = [(0, 0, 1)]
            uniform int[] pointIndices = [2]
        }

        def BlendShape "Off"
        {
            uniform vector3f[] offsets = [(0, 0, 0)]
            uniform int[] pointIndices = [0]
        }

        def BlendShape "Big__ears__2"
        {
            uniform vector3f[] offsets = [(0, 0, 0)]
            uniform int[] pointIndices = [0]
        }
    }

    def Skeleton "Skel" (
        prepend apiSchemas = ["SkelBindingAPI"]
    )
    {
        uniform token[] joints = []
        uniform matrix4d[] bindTransforms = []
        uniform matrix4d[] restTransforms = []
        rel skel:animationSource = </Root/Skel/Strengths>

        def SkelAnimation "Strengths"
        {
            uniform token[] blendShapes = ["Big \"ears\"", "Off", "Big 'ears'"]
            float[] blendShapeWeights = [0.5, 0, 1.5]
            float[] blendShapeWeights.timeSamples = {
                1: [0.5, 0, 1.5],
            }
        }
    }
}
`
	testing.expect_value(t, string(out[:]), want)
}

// Without layers it is a plain mesh under an Xform; a retopologized mesh's quads go as
// they are, with their UVs a corner at a time; a name that is all digits gets an
// underscore in front, one with nothing to keep the fallback, and the skeleton's own
// name a number.
@(test)
usda_quads_without_layers :: proc(t: ^testing.T) {
	m := Mesh_Export {
		name      = "42",
		positions = []Vec3{{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}},
		normals   = []Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}},
		indices   = []u32{0, 1, 2, 0, 2, 3},
		quads     = [][4]u32{{0, 1, 2, 3}},
		uvs       = [][4][2]f32{{{0, 0}, {1, 0}, {1, 1}, {0, 1}}},
		scale     = 2,
		offset    = {0, 0, 1},
	}
	out := make([dynamic]u8)
	defer delete(out)
	mesh_write_usda(&out, m)
	free_all(context.temp_allocator)
	want := `#usda 1.0
(
    defaultPrim = "Root"
    doc = "Written by Sculpt"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "Root"
{
    def Mesh "_42"
    {
        float3[] extent = [(0, 0, 1), (2, 2, 1)]
        int[] faceVertexCounts = [4]
        int[] faceVertexIndices = [0, 1, 2, 3]
        normal3f[] normals = [(0, 0, 1), (0, 0, 1), (0, 0, 1), (0, 0, 1)] (
            interpolation = "vertex"
        )
        point3f[] points = [(0, 0, 1), (2, 0, 1), (2, 2, 1), (0, 2, 1)]
        texCoord2f[] primvars:st = [(0, 0), (1, 0), (1, 1), (0, 1)] (
            interpolation = "faceVarying"
        )
        uniform token subdivisionScheme = "none"
    }
}
`
	testing.expect_value(t, string(out[:]), want)

	for c in ([][2]string{{"Ü", `def Mesh "_"`}, {"", `def Mesh "Mesh"`}, {"Skel", `def Mesh "Skel_2"`}}) {
		name, prim := c[0], c[1]
		m.name = name
		clear(&out)
		mesh_write_usda(&out, m)
		free_all(context.temp_allocator)
		testing.expectf(t, strings.contains(string(out[:]), prim), "%q is not %s", name, prim)
	}
}

@(test)
usda_is_the_same_on_the_pool :: proc(t: ^testing.T) {
	pool: jobs.Pool
	jobs.pool_init(&pool, 3)
	defer jobs.pool_destroy(&pool)
	sphere := icosphere(7) // more vertices than one range
	defer mesh_destroy(&sphere)
	n := len(sphere.positions)
	colors := make([][3]u8, n)
	defer delete(colors)
	groups := make([]u16, len(sphere.indices) / 3)
	defer delete(groups)
	vertices := make([]u32, n / 3)
	defer delete(vertices)
	deltas := make([]Vec3, n / 3)
	defer delete(deltas)
	for v in 0 ..< n do colors[v] = {u8(v), u8(v >> 8), u8(v >> 16)}
	for &g, i in groups do g = u16(i % 7)
	for &x, i in vertices do x = u32(3 * i)
	for &d, i in deltas do d = sphere.normals[3 * i] * 0.01
	m := Mesh_Export{name = "Sphere", positions = sphere.positions[:], normals = sphere.normals[:], indices = sphere.indices[:], colors = colors, groups = groups, scale = 3, offset = {0, 1, 0}}
	m.morphs = []Morph_Target{{name = "Swell", weight = 0.7, vertices = vertices, deltas = deltas}}
	serial, parallel := make([dynamic]u8), make([dynamic]u8)
	defer delete(serial)
	defer delete(parallel)
	mesh_write_usda(&serial, m)
	mesh_write_usda(&parallel, m, &pool)
	free_all(context.temp_allocator)
	testing.expect(t, len(serial) == len(parallel) && mem.compare(serial[:], parallel[:]) == 0, "the pool changed the file")
}

// A material goes as a UsdPreviewSurface bound to the mesh, named apart from it; with
// paint its diffuse colour reads the displayColor primvar, the material's colour only
// the fallback.
@(test)
usda_carries_the_material :: proc(t: ^testing.T) {
	m := Mesh_Export {
		name      = "Gold",
		positions = []Vec3{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}},
		normals   = []Vec3{{0, 0, 1}, {0, 0, 1}, {0, 0, 1}},
		indices   = []u32{0, 1, 2},
		material  = Export_Material{name = "Gold", base = {1, 0.5, 0.25}, metallic = 1, roughness = 0.3},
	}
	out := make([dynamic]u8)
	defer delete(out)
	mesh_write_usda(&out, m)
	free_all(context.temp_allocator)
	text := string(out[:])
	for want in ([]string {
		`def Mesh "Gold" (
        prepend apiSchemas = ["MaterialBindingAPI"]
    )`,
		`rel material:binding = </Root/Gold_2>`,
		`def Material "Gold_2"`,
		`token outputs:surface.connect = </Root/Gold_2/Surface.outputs:surface>`,
		`uniform token info:id = "UsdPreviewSurface"`,
		`color3f inputs:diffuseColor = (1, 0.5, 0.25)`,
		`float inputs:metallic = 1`,
		`float inputs:roughness = 0.3`,
	}) {
		testing.expectf(t, strings.contains(text, want), "no %q in\n%s", want, text)
	}
	testing.expect(t, !strings.contains(text, "UsdPrimvarReader_float3"))
	m.colors = [][3]u8{{255, 0, 0}, {0, 255, 0}, {0, 0, 255}}
	clear(&out)
	mesh_write_usda(&out, m)
	free_all(context.temp_allocator)
	text = string(out[:])
	for want in ([]string {
		`color3f inputs:diffuseColor.connect = </Root/Gold_2/Paint.outputs:result>`,
		`uniform token info:id = "UsdPrimvarReader_float3"`,
		`string inputs:varname = "displayColor"`,
	}) {
		testing.expectf(t, strings.contains(text, want), "no %q in\n%s", want, text)
	}
	// None leaves the file as it was.
	m.material, m.colors = nil, nil
	clear(&out)
	mesh_write_usda(&out, m)
	free_all(context.temp_allocator)
	testing.expect(t, !strings.contains(string(out[:]), "Material"))
}
