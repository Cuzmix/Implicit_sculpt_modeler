// One sample of render mode (render/path.odin) for a band of rows: a path per pixel from
// the camera, through the merged scene (every traced item's triangles, their chunk trees
// and a tree over all the chunks in world space), bouncing off Lambert and GGX surfaces.
// Each surface the path meets takes light from one of the scene's lights picked by
// strength (next-event estimation) and continues in a direction its material picks;
// a direction that meets a light counts it too, the two weighted by the power heuristic
// so neither is counted twice. A path that leaves the scene takes the environment, which
// is also sampled as a light by its brightness (env_sample.odin's table), weighed against
// the bounces that find it the same way.
// The camera's ray is jittered within its pixel, so the image is anti-aliased, but for
// the first sample's, through the pixel's centre, which also writes the denoiser's guides
// (render_atrous.frag.slang): what the ray met's colour, normal and distance; with depth of
// field every sample adds to them, so they blur as the image does. Every
// random number comes from the pixel and the sample, so a sample is the same however the
// rows are split between dispatches and on every run.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the sampled textures, then the
// read-only storage buffers; set 1 the read-write storage textures; set 2 the uniforms.
// Included by render_trace.comp.slang (nine named map samplers, every backend) and by
// render_trace_maps.comp.slang, which defines MAP_ARRAY: the maps in set 3 as one array
// (the own Vulkan backend with descriptor indexing, Gpu_Caps.texture_arrays). Each has a
// twin defining RAY_QUERY (render_trace_rq.comp.slang, render_trace_maps_rq.comp.slang):
// rays then meet the driver's acceleration structure over every item, at binding 0 of set
// 3 (the maps after it), instead of walking the chunk trees, and `order` holds where each
// item's geometries start among the merged triangles in place of the trees' offsets.

#include "common.slang"
#include "skin_grid.slang"
#include "paint_material.slang"
struct Node {
	float3 lo;
	uint first; // inner: the left child, the right one after it; leaf: see below
	float3 hi;
	uint count; // 0 for an inner node
};

// One traced item (render.Item_Record).
struct Item {
	float4x4 model;      // mesh space into the world, a similarity
	float4x4 inv_model;
	float4 color;      // the base colour, linear
	float4 surface;    // x: metallic, y: roughness
	// x: the item's first vertex in the merged buffers, y: ITEM_ flags, z: under RAY_QUERY
	// where its geometries' first triangles start in `order`, w: where its materials start
	// in `chunks` (material_row), 0 for none
	uint4 offs;
	uint4 slot_group[4];   // the polygroup of each material slot from 1
	// ITEM_TEXTURED: its first triangle (a skinned item's too), where its corners and its preview vertices start
	// in `textured`, and its map slot (bits 0-3, 3 for none; bits 16-23 under MAP_ARRAY), view
	// (4-7: 1 the maps, 2 the normal map, 3 the UV checker) and maps it has (8-10: base
	// colour, ORM, normal)
	uint4 tex;
	// ITEM_SKINNED: where its detail skin's sample normals and triangle records (four words
	// each) start in `attributes`, and the skin's vertex and edge counts; its segments are in
	// the flags from ITEM_SKIN_SHIFT.
	uint4 skin;
};

static const uint ITEM_PAINT = 1u;  // the polypaint shows over the colour
static const uint ITEM_GROUPS = 2u; // each polygroup shows in its own colour instead
static const uint ITEM_SLOTS = 4u;  // groups may have materials of their own
static const uint ITEM_TEXTURED = 8u; // shows its maps through its preview's UVs
static const uint ITEM_SKINNED = 16u; // shades by its detail skin's normals
static const uint ITEM_MATERIAL = 32u; // its paint has roughness and metal (vertex_material)
static const uint ITEM_TRANSMIT = 256u; // a material in its table lets light through (rows 7 and 8)
static const uint ITEM_LAYERS = 128u; // a material in its table has a coat, sheen, glow or its own IOR or specular (rows 4 to 9)
static const uint ITEM_SUBSURFACE = 64u; // a material in its table scatters light under its surface (subsurface_walk)
static const uint ITEM_SKIN_SHIFT = 8u; // the skin's segments, five bits

// The sum so far: radiance over the samples whose camera ray met the scene in rgb, and
// how many did in a.
[[vk::binding(0, 0)]] Sampler2D prev;
// The image environment as loaded, at full size (render/environment.odin's source); a
// black 1 x 1 one while none is bound.
[[vk::binding(1, 0)]] Sampler2D environment_map;
// The table for sampling the environment by its brightness: the image's, or the built-in
// studio's in its own space (render.Env_Table).
[[vk::binding(2, 0)]] Sampler2D env_table;
// The guides so far (below), which with depth of field each sample adds to.
[[vk::binding(3, 0)]] Sampler2D prev_albedo;
[[vk::binding(4, 0)]] Sampler2D prev_normal;
#ifdef RAY_QUERY
[[vk::binding(0, 3)]] RaytracingAccelerationStructure structure;
#endif
#ifdef MAP_ARRAY
// Every map slot's base colour, ORM and normal maps, three a slot in that order, in their
// own set (render.gpu_bind_compute_texture_array), defaults where an item lacks one; after
// the acceleration structure under RAY_QUERY, as the array is the set's last binding.
#ifdef RAY_QUERY
[[vk::binding(1, 3)]] Sampler2D maps[];
#else
[[vk::binding(0, 3)]] Sampler2D maps[];
#endif
[[vk::binding(5, 0)]] StructuredBuffer<float> positions; // 3 floats a vertex, mesh space
[[vk::binding(6, 0)]] StructuredBuffer<uint> indices; // each item's own, from its first vertex
// Each vertex's normal (render.Normal_Packed, one word), then from counts.w each vertex's
// render.Paint_Packed (two words), then its painted roughness and metal (one word).
[[vk::binding(7, 0)]] StructuredBuffer<uint> attributes;
// Every chunk's tree, one after another, a leaf's `first` into its chunk's order; then
// from extra.x the tree over every chunk, a leaf's `first` a chunk.
[[vk::binding(8, 0)]] StructuredBuffer<Node> nodes;
[[vk::binding(9, 0)]] StructuredBuffer<uint> order; // two 16-bit offsets a word
// node_off, order_off, first_tri, and the node count with the item in the top 12 bits.
[[vk::binding(10, 0)]] StructuredBuffer<uint4> chunks;
[[vk::binding(11, 0)]] StructuredBuffer<Item> items;
// Each textured item's preview vertices (render.Textured_Vertex: position, packed normal,
// tangent as four 16-bit snorms, uv; 8 words), then its corners: for each triangle of its
// sculpt mesh, the vertex each corner takes.
[[vk::binding(12, 0)]] StructuredBuffer<uint> textured;
#else
// Each map slot's base colour (sRGB, so it samples linear), ORM and normal maps
// (render.Texture_Map), defaults where an item lacks one (its flags say so).
[[vk::binding(5, 0)]] Sampler2D map0;
[[vk::binding(6, 0)]] Sampler2D map1;
[[vk::binding(7, 0)]] Sampler2D map2;
[[vk::binding(8, 0)]] Sampler2D map3;
[[vk::binding(9, 0)]] Sampler2D map4;
[[vk::binding(10, 0)]] Sampler2D map5;
[[vk::binding(11, 0)]] Sampler2D map6;
[[vk::binding(12, 0)]] Sampler2D map7;
[[vk::binding(13, 0)]] Sampler2D map8;
[[vk::binding(14, 0)]] StructuredBuffer<float> positions; // 3 floats a vertex, mesh space
[[vk::binding(15, 0)]] StructuredBuffer<uint> indices; // each item's own, from its first vertex
// Each vertex's normal (render.Normal_Packed, one word), then from counts.w each vertex's
// render.Paint_Packed (two words), then its painted roughness and metal (one word).
[[vk::binding(16, 0)]] StructuredBuffer<uint> attributes;
// Every chunk's tree, one after another, a leaf's `first` into its chunk's order; then
// from extra.x the tree over every chunk, a leaf's `first` a chunk.
[[vk::binding(17, 0)]] StructuredBuffer<Node> nodes;
[[vk::binding(18, 0)]] StructuredBuffer<uint> order; // two 16-bit offsets a word
// node_off, order_off, first_tri, and the node count with the item in the top 12 bits.
[[vk::binding(19, 0)]] StructuredBuffer<uint4> chunks;
[[vk::binding(20, 0)]] StructuredBuffer<Item> items;
// Each textured item's preview vertices (render.Textured_Vertex: position, packed normal,
// tangent as four 16-bit snorms, uv; 8 words), then its corners: for each triangle of its
// sculpt mesh, the vertex each corner takes.
[[vk::binding(21, 0)]] StructuredBuffer<uint> textured;
#endif
[[vk::binding(0, 1)]] [[vk::image_format("rgba32f")]] RWTexture2D<float4> next;
// The guides, written by the first sample only (by every sample, as running means over
// the samples, with depth of field): the base colour the camera's ray met with
// 1 in a (0 everywhere for a miss), and its normal (world) with the distance in a.
[[vk::binding(1, 1)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> guide_albedo;
[[vk::binding(2, 1)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> guide_normal;

#define LIGHT_COUNT 8

// What the scene may use, as specialization constants (Metal function constants): the
// renderer builds a kernel for each mix a scene needs (render/path.odin's
// Render_Features), and the driver folds away every branch a constant rules out, which
// takes the plain sculpt's kernel from 128 registers a thread to 96 on an RDNA2 GPU
// (scripts/kernel_stats.py). Left unset they allow everything, which is the general
// kernel a run uses until its own is built. All are uints, so Metal sets them with one type.
// The item flags (ITEM_) any item may carry: each item's flags are masked with them.
[[vk::constant_id(0)]] const uint RT_ITEMS = 0xffffffffu;
// 1 when an image environment may be bound.
[[vk::constant_id(1)]] const uint RT_ENV_IMAGE = 1u;
// 1 when depth of field may be on.
[[vk::constant_id(2)]] const uint RT_LENS = 1u;
// 1 when a light with a place (point, spot or area, each traced as a sphere) may be on;
// 0 means suns only.
[[vk::constant_id(3)]] const uint RT_SPHERE_LIGHTS = 1u;
// 1 when a shadow catcher may be on (render.Shadow_Catcher).
[[vk::constant_id(4)]] const uint RT_CATCHER = 1u;

[[vk::binding(0, 2)]] cbuffer Render_Uniforms {
	float4x4 inv_view_proj; // clip space back to the world
	// The lights in world space, as render.Lights carries them in view space (light_at in
	// mesh_shading.slang): toward a sun or where a point or spot light is, kind in w; colour
	// and strength; a spot's axis and cone; distance, reach and spot edge.
	float4 light_pos[LIGHT_COUNT];
	float4 light_color[LIGHT_COUNT];
	float4 light_spot[LIGHT_COUNT];
	float4 light_shape[LIGHT_COUNT];
	// Each light as an area: x a sun's cone's cosine or a sphere's radius, y the radiance
	// a unit of its colour stands for, z the chance it is picked up to and including it, w
	// the chance it is picked.
	float4 light_size[LIGHT_COUNT];
	// The built-in studio's turn into the world, with the ambient light in rig_x.w.
	float4 rig_x;
	float4 rig_y;
	float4 rig_z;
	// Each light's x: highlight less or more than usual (-1 to 1, 0 as usual), y: 1 for a
	// light that casts no shadow (render.Lights.extra).
	float4 light_extra[LIGHT_COUNT];
	// The image environment's axes in the world.
	float4 env_x;
	float4 env_y;
	float4 env_z;
	float4 env;     // x: 1 while an image environment is bound, y: its strength, z: the chance a light sample takes the environment
	float4 scene;   // xyz: the scene's centre, w: its radius
	uint4 counts; // x: this sample, y: the first row of this band, z: bounces, w: where paint starts in `attributes`
	uint4 extra;  // x: where the scene tree starts in `nodes`, y: 1 when it is empty
	// Depth of field (render.Lens): the eye with the lens's radius in w (0: a pinhole),
	// the camera's right with the focal plane's distance along its forward in w, its up,
	// and its forward.
	float4 lens_eye;
	float4 lens_right;
	float4 lens_up;
	float4 lens_fwd;
	// The shadow catcher (render.Shadow_Catcher): x the axis across its plane, y where along
	// it, z how dark its shadow, w 1 when on; the light whose shadow it catches in
	// catcher_light.x.
	float4 catcher;
	float4 catcher_light;
};

#include "panorama.slang"
#include "studio_env.slang"
#include "light_window.slang"
#include "ggx_albedo.slang"
#include "thin_film.slang"

static const float PI = 3.14159265;
// geom.CHUNK_BVH_STACK for each level: a chunk's entries stay above the scene tree's.
static const int STACK = 2 * 57;
static const uint IN_CHUNK = 0x80000000u;
static const float FAR = 3.0e38;
// How blurred the built-in studio is where paths leave the scene: its two narrow lobes
// sharp would be found by a diffuse bounce too rarely to converge.
static const float STUDIO_BLUR = 0.25;
// The largest radiance one sample may add to a pixel: a rare path that finds a bright
// light through a narrow gap would otherwise leave a white speck for hundreds of samples.
static const float SAMPLE_CLAMP = 16.0;

// PCG (O'Neill 2014), the state per invocation.
static uint rng;

uint pcg_next() {
	uint s = rng;
	rng = s * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float rnd() {
	return float(pcg_next() >> 8) / 16777216.0;
}

float3 vertex(uint v) {
	return float3(positions[3u * v], positions[3u * v + 1u], positions[3u * v + 2u]);
}

float3 oct_decode(float2 e) {
	float3 v = float3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0) v.xy = (1.0 - abs(e.yx)) * float2(e.x >= 0.0 ? 1.0 : -1.0, e.y >= 0.0 ? 1.0 : -1.0);
	return normalize(v);
}

// A normal packed as render.Normal_Packed: two 16-bit halves, the mask in the low 4 bits
// of each, which render mode leaves out.
float3 normal_decode(uint w) {
	int2 raw = int2(int(w << 16) >> 16, int(w) >> 16);
	return oct_decode(float2(raw & ~15) / 32767.0);
}

// A skin sample's normal (sculpt.Skin's octahedral pair: all sixteen bits each, no mask).
float3 normal_decode_full(uint w) {
	return oct_decode(max(float2(int2(int(w << 16) >> 16, int(w) >> 16)) / 32767.0, float2(-1.0)));
}

// A vertex's normal in mesh space.
float3 vertex_normal(uint v) {
	return normal_decode(attributes[v]);
}

// A skinned item's shading normal in mesh space (not unit length) at barycentric `gb` of
// its triangle `tri` (its own number), whose corners as drawn are its vertices `gv`: the
// three samples of the skin's small triangle there, mixed, as the viewport shades it.
float3 skin_normal(uint item, uint tri, float3 gb, uint3 gv) {
	uint4 sk = items[item].skin;
	uint S = (items[item].offs.y >> ITEM_SKIN_SHIFT) & 31u;
	uint at = sk.y + 4u * tri;
	uint4 rec = uint4(attributes[at], attributes[at + 1u], attributes[at + 2u], attributes[at + 3u]);
	uint3 x;
	float3 w;
	skin_grid_corners(S, sk.z, sk.w, tri, rec, gb, gv, x, w);
	return normal_decode_full(attributes[sk.x + x.x]) * w.x + normal_decode_full(attributes[sk.x + x.y]) * w.y + normal_decode_full(attributes[sk.x + x.z]) * w.z;
}

// A textured item's preview vertex at word `at` of `textured`: its normal and tangent
// (w the bitangent's side) in mesh space, and its UV (v up).
struct Tex_Vertex {
	float3 n;
	float4 t;
	float2 uv;
};

Tex_Vertex tex_vertex(uint at) {
	Tex_Vertex v;
	v.n = normal_decode(textured[at + 3u]);
	uint a = textured[at + 4u], b = textured[at + 5u];
	v.t = max(float4(int(a << 16) >> 16, int(a) >> 16, int(b << 16) >> 16, int(b) >> 16) / 32767.0, float4(-1.0));
	v.uv = float2(asfloat(textured[at + 6u]), asfloat(textured[at + 7u]));
	return v;
}

// Map `kind` (0 base colour, 1 ORM, 2 normal) of map slot `slot` at `uv`, at the level
// whose texels are as wide as `lod` says the pixel is, in log2 of the UV square (so the
// map's own size adds half the log2 of its texel count). Without MAP_ARRAY the samplers are
// named, not an array: indexing one by a value that differs between pixels needs a device
// feature not every backend offers.
#define MAP_AT(s) { float2 size = float2(texture_size(s)); return s.SampleLevel(uv, max(lod + 0.5 * log2(size.x * size.y), 0.0)); }
#ifdef MAP_ARRAY
float4 map_at(uint slot, uint kind, float2 uv, float lod) {
	MAP_AT(maps[NonUniformResourceIndex(slot * 3u + kind)])
}
#else
float4 map_at(uint slot, uint kind, float2 uv, float lod) {
	switch (slot * 3u + kind) {
	case 0u: MAP_AT(map0)
	case 1u: MAP_AT(map1)
	case 2u: MAP_AT(map2)
	case 3u: MAP_AT(map3)
	case 4u: MAP_AT(map4)
	case 5u: MAP_AT(map5)
	case 6u: MAP_AT(map6)
	case 7u: MAP_AT(map7)
	case 8u: MAP_AT(map8)
	}
	return float4(0.0);
}
#endif

// The size in texels of map `kind` of slot `slot`, as map_at picks it.
#define MAP_SIZE(s) { return texture_size(s); }
#ifdef MAP_ARRAY
int2 map_size(uint slot, uint kind) {
	MAP_SIZE(maps[NonUniformResourceIndex(slot * 3u + kind)])
}
#else
int2 map_size(uint slot, uint kind) {
	switch (slot * 3u + kind) {
	case 0u: MAP_SIZE(map0)
	case 1u: MAP_SIZE(map1)
	case 2u: MAP_SIZE(map2)
	case 3u: MAP_SIZE(map3)
	case 4u: MAP_SIZE(map4)
	case 5u: MAP_SIZE(map5)
	case 6u: MAP_SIZE(map6)
	case 7u: MAP_SIZE(map7)
	case 8u: MAP_SIZE(map8)
	}
	return int2(1);
}
#endif

// The tangent-space normal's tilt the painted height in slot `slot`'s normal place gives
// at `uv`, as mesh_shading.slang's paint_height_slope reads it: four taps a texel apart on
// its finest level, one height unit over a 64th of the UV square a slope of one.
float2 paint_height_slope_at(uint slot, float2 uv) {
	float2 size = float2(map_size(slot, 2u));
	float2 px = 1.0 / size;
	float l = map_at(slot, 2u, uv - float2(px.x, 0.0), -40.0).r;
	float r = map_at(slot, 2u, uv + float2(px.x, 0.0), -40.0).r;
	float up = map_at(slot, 2u, uv - float2(0.0, px.y), -40.0).r;
	float down = map_at(slot, 2u, uv + float2(0.0, px.y), -40.0).r;
	return float2(r - l, up - down) * 0.5 * (size.x / 64.0);
}

// The viewport's UV checker (mesh_shading.slang): 8 by 8 cells, every other one darker,
// each edged with a line and tinted by its column and row; the lines a fixed share of a
// cell, since render mode smooths edges by its samples rather than by pixel derivatives.
float3 uv_checker(float2 uv) {
	float2 c = uv * 8.0;
	float2 f = frac(c);
	float line = step(min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y)), 0.015);
	float2 cell = floor(c);
	float odd = glsl_mod(cell.x + cell.y, 2.0);
	float h = (cell.x + 0.5) / 8.0;
	float3 hue = clamp(abs(frac(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	float3 tint = lerp(float3(1.0), hue, 0.35) * lerp(0.7, 1.0, (cell.y + 0.5) / 8.0);
	return tint * lerp(1.0, 0.72, odd) * (1.0 - 0.5 * line);
}

uint2 vertex_paint(uint v) {
	uint at = counts.w + 2u * v;
	return uint2(attributes[at], attributes[at + 1u]);
}

// A vertex's painted roughness and metal (render.Mesh_Buffers.paint_material, one word):
// after the paint, whose two words a vertex follow the normals' one, so from three times
// counts.w (the vertex count).
uint vertex_material(uint v) {
	return attributes[3u * counts.w + v];
}

float3 srgb_decode(float3 c) {
	return lerp(c / 12.92, pow((c + 0.055) / 1.055, float3(2.4)), step(0.04045, c));
}

// As mesh.vert.slang's: hues a golden angle apart, in two lightnesses.
float3 group_color(uint g) {
	float h = frac(float(g) * 0.618034 + 0.12);
	float3 rgb = clamp(abs(frac(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
	float light = (g & 1u) == 0u ? 0.75 : 0.55;
	return lerp(float3(1.0), rgb, 0.55) * light;
}

// Where a ray along `d` enters the box, or -1 where it misses it or enters beyond `t_max`;
// a box refit empty (lo above hi) is never entered.
float enters(Node n, float3 o, float3 inv, float t_max) {
	if (n.lo.x > n.hi.x) return -1.0;
	float3 t0 = (n.lo - o) * inv, t1 = (n.hi - o) * inv;
	float3 near = min(t0, t1), far = max(t0, t1);
	float t_in = max(max(near.x, near.y), max(near.z, 0.0));
	float t_out = min(far.x, min(far.y, far.z));
	return t_in <= t_out && t_in < t_max ? t_in : -1.0;
}

float3 safe_inverse(float3 d) {
	// No component exactly zero, so the slab test never multiplies zero by infinity.
	return 1.0 / select(d == float3(0.0), float3(1e-20), d);
}

struct Hit {
	float t;
	uint tri;  // in the merged index buffer
	uint item;
	float2 uv;   // barycentrics of the second and third corners
};

#ifdef RAY_QUERY
// Where a candidate of the query lies among the merged triangles: its item's geometries
// start where `order` says, from offs.z.
uint merged_triangle(uint item, uint geometry, uint primitive) {
	return order[items[item].offs.z + geometry] + primitive;
}

// The nearest triangle along the ray before `t_max`, or with `any` the first one found,
// as the walk below finds it. The instances carry their item's model, so t measures the
// world ray as given. Geometries holding a triangle with a repeated corner (hidden, or an
// unused slot) are not opaque, and their candidates come here to be turned down, as the
// walk does.
// The one ray query every trace shares: RADV gives each query object the kernel declares
// registers of its own, even one in a branch a specialised kernel folds away, so a query a
// call (trace is inlined at each) cost a kernel without subsurface materials a quarter of
// its waves once the walk added a call. Traces never overlap, so one object serves them all.
// Metal refuses a ray query as a struct's field or a return value, and slangc keeps module
// statics in a context struct for Metal, so there (shaders_msl.py defines METAL) each trace
// declares its own query instead.
#ifdef METAL
#define TRACE_QUERY RayQuery<RAY_FLAG_NONE> trace_query;
#else
static RayQuery<RAY_FLAG_NONE> trace_query;
#define TRACE_QUERY
#endif

bool trace(float3 o, float3 d, float t_max, bool any, out Hit hit) {
	hit.t = t_max;
	hit.tri = 0u;
	hit.item = 0u;
	hit.uv = float2(0.0);
	if (extra.y != 0u) return false;
	RayDesc ray;
	ray.Origin = o;
	ray.TMin = 0.0;
	ray.Direction = d;
	ray.TMax = t_max;
	TRACE_QUERY
	trace_query.TraceRayInline(structure, any ? RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH : RAY_FLAG_NONE, 0xFF, ray);
	while (trace_query.Proceed()) {
		uint tri = merged_triangle(trace_query.CandidateInstanceID(), trace_query.CandidateGeometryIndex(), trace_query.CandidatePrimitiveIndex());
		uint ia = indices[3u * tri], ib = indices[3u * tri + 1u], ic = indices[3u * tri + 2u];
		if (ia != ib && ib != ic && ia != ic) trace_query.CommitNonOpaqueTriangleHit();
	}
	if (trace_query.CommittedStatus() != COMMITTED_TRIANGLE_HIT) return false;
	hit.t = trace_query.CommittedRayT();
	hit.item = trace_query.CommittedInstanceID();
	hit.tri = merged_triangle(hit.item, trace_query.CommittedGeometryIndex(), trace_query.CommittedPrimitiveIndex());
	hit.uv = trace_query.CommittedTriangleBarycentrics();
	return true;
}
#else
// The nearest triangle along the ray before `t_max`, or with `any` the first one found.
// The scene tree is in world space; at a chunk the ray goes into its item's mesh space
// unnormalised, so t keeps measuring the world ray.
bool trace(float3 o, float3 d, float t_max, bool any, out Hit hit) {
	hit.t = t_max;
	hit.tri = 0u;
	hit.item = 0u;
	hit.uv = float2(0.0);
	if (extra.y != 0u) return false;
	bool found = false;
	float3 inv = safe_inverse(d);
	uint stack[STACK];
	int top = 1;
	stack[0] = extra.x;
	uint4 ch = uint4(0u);
	uint item = 0u, base = 0u;
	float3 om = float3(0.0), dm = float3(0.0), inv_m = float3(0.0);
	while (top > 0) {
		uint e = stack[--top];
		if ((e & IN_CHUNK) == 0u) {
			Node n = nodes[e];
			if (enters(n, o, inv, hit.t) < 0.0) continue;
			if (n.count == 0u) {
				// The nearer child is walked first, so later boxes are cut by its hits.
				uint a = extra.x + n.first, b = a + 1u;
				float ta = enters(nodes[a], o, inv, hit.t), tb = enters(nodes[b], o, inv, hit.t);
				if (ta >= 0.0 && tb >= 0.0) {
					stack[top++] = ta < tb ? b : a;
					stack[top++] = ta < tb ? a : b;
				} else if (ta >= 0.0) {
					stack[top++] = a;
				} else if (tb >= 0.0) {
					stack[top++] = b;
				}
			} else {
				// Everything pushed from here on is this chunk's, and is walked before the
				// scene tree's next entry comes off the stack.
				ch = chunks[n.first];
				item = ch.w >> 20;
				base = items[item].offs.x;
				float4x4 to_mesh = items[item].inv_model;
				om = (mul(float4(o, 1.0), to_mesh)).xyz;
				dm = mul(d, (float3x3)to_mesh);
				inv_m = safe_inverse(dm);
				stack[top++] = IN_CHUNK;
			}
			continue;
		}
		Node n = nodes[ch.x + (e & ~IN_CHUNK)];
		if (enters(n, om, inv_m, hit.t) < 0.0) continue;
		if (n.count == 0u) {
			uint a = n.first, b = a + 1u;
			float ta = enters(nodes[ch.x + a], om, inv_m, hit.t), tb = enters(nodes[ch.x + b], om, inv_m, hit.t);
			if (ta >= 0.0 && tb >= 0.0) {
				stack[top++] = IN_CHUNK | (ta < tb ? b : a);
				stack[top++] = IN_CHUNK | (ta < tb ? a : b);
			} else if (ta >= 0.0) {
				stack[top++] = IN_CHUNK | a;
			} else if (tb >= 0.0) {
				stack[top++] = IN_CHUNK | b;
			}
			continue;
		}
		for (uint j = n.first; j < n.first + n.count; j++) {
			uint at = ch.y + j;
			uint word = order[at >> 1];
			uint tri = ch.z + ((at & 1u) == 0u ? (word & 0xFFFFu) : (word >> 16));
			uint ia = indices[3u * tri], ib = indices[3u * tri + 1u], ic = indices[3u * tri + 2u];
			// A triangle with a repeated corner (hidden, or an unused slot) never hits.
			if (ia == ib || ib == ic || ia == ic) continue;
			// Möller-Trumbore, both sides.
			float3 p0 = vertex(base + ia);
			float3 e1 = vertex(base + ib) - p0, e2 = vertex(base + ic) - p0;
			float3 pv = cross(dm, e2);
			float det = dot(e1, pv);
			if (det == 0.0) continue;
			float f = 1.0 / det;
			float3 tv = om - p0;
			float u = dot(tv, pv) * f;
			if (u < 0.0 || u > 1.0) continue;
			float3 qv = cross(tv, e1);
			float v = dot(dm, qv) * f;
			if (v < 0.0 || u + v > 1.0) continue;
			float t = dot(e2, qv) * f;
			if (t <= 0.0 || t >= hit.t) continue;
			hit.t = t;
			hit.tri = tri;
			hit.item = item;
			hit.uv = float2(u, v);
			found = true;
			if (any) return true;
		}
	}
	return found;
}
#endif

// Off the surface along its geometric normal by a few steps of the float grid, which
// scales with the position itself (Wächter and Binder, "A Fast and Robust Method for
// Avoiding Self-Intersection", Ray Tracing Gems 2019).
float3 offset_ray(float3 p, float3 n) {
	const float ORIGIN = 1.0 / 32.0;
	const float FLOAT_SCALE = 1.0 / 65536.0;
	const float INT_SCALE = 256.0;
	int3 of = int3(INT_SCALE * n);
	float3 p_i = float3(
		asfloat(asint(p.x) + (p.x < 0.0 ? -of.x : of.x)),
		asfloat(asint(p.y) + (p.y < 0.0 ? -of.y : of.y)),
		asfloat(asint(p.z) + (p.z < 0.0 ? -of.z : of.z)));
	return float3(
		abs(p.x) < ORIGIN ? p.x + FLOAT_SCALE * n.x : p_i.x,
		abs(p.y) < ORIGIN ? p.y + FLOAT_SCALE * n.y : p_i.y,
		abs(p.z) < ORIGIN ? p.z + FLOAT_SCALE * n.z : p_i.z);
}

// A frame about `n` (Duff et al. 2017): tangent, bitangent.
void basis(float3 n, out float3 t, out float3 b) {
	float s = n.z >= 0.0 ? 1.0 : -1.0;
	float a = -1.0 / (s + n.z);
	float c = n.x * n.y * a;
	t = float3(1.0 + s * n.x * n.x * a, s * c, -s * n.x);
	b = float3(c, s + n.y * n.y * a, -n.y);
}

// Row `row` of material `k` in an item's table, which starts at `table` in `chunks`
// (render.path_material_rows): 0 its colour, 1 its surface (metallic, roughness), then
// from 2 its layers' eight rows (geom.Material_Layers).
static const uint MATERIAL_ROWS = 10u;
float4 material_row(uint table, uint k, uint row) {
	return asfloat(chunks[table + MATERIAL_ROWS * k + row]);
}

float luminance(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

struct Surface {
	float3 diffuse; // the Lambert part's colour
	float3 f0;      // reflectance seen straight on
	float a;      // GGX alpha, roughness squared
	// A clear coat over it (ITEM_LAYERS): how much, its GGX alpha and its reflectance
	// straight on; and sheen's colour (times its weight) and alpha. All zero for a surface
	// without layers, which every branch on them then folds away.
	float coat, coat_a, coat_f0;
	float3 sheen;
	float sheen_a;
};

// A surface with no coat or sheen: its diffuse colour, reflectance and alpha.
Surface surface_plain(float3 diffuse, float3 f0, float a) {
	Surface s;
	s.diffuse = diffuse;
	s.f0 = f0;
	s.a = a;
	s.coat = 0.0;
	s.coat_a = 1.0;
	s.coat_f0 = 0.0;
	s.sheen = float3(0.0);
	s.sheen_a = 1.0;
	return s;
}

float3 fresnel(float3 f0, float c) {
	return f0 + (1.0 - f0) * pow(1.0 - clamp(c, 0.0, 1.0), 5.0);
}

// The exact Fresnel reflectance of a dielectric interface seen at cosine `c` from the side
// whose IOR over the other's is 1 / `eta` (eta: the far side's IOR over the near side's):
// 1 past the critical angle, where all the light reflects inside.
float fresnel_dielectric(float c, float eta) {
	c = abs(c);
	float g2 = eta * eta - 1.0 + c * c;
	if (g2 <= 0.0) return 1.0;
	float g = sqrt(g2);
	float a = (g - c) / (g + c);
	float b = (c * (g + c) - 1.0) / (c * (g - c) + 1.0);
	return 0.5 * a * a * (1.0 + b * b);
}

float ggx_d(float n_dot_h, float a) {
	float a2 = a * a;
	float d = n_dot_h * n_dot_h * (a2 - 1.0) + 1.0;
	return a2 / (PI * d * d);
}

// Smith's Lambda for GGX.
float ggx_lambda(float c, float a) {
	float c2 = max(c * c, 1e-8);
	return 0.5 * (-1.0 + sqrt(1.0 + a * a * (1.0 - c2) / c2));
}

// The chance the specular lobe is picked, from the Fresnel straight toward the eye: the
// half vector is not known before the lobe is.
float specular_chance(Surface s, float n_dot_v) {
	float3 fv = fresnel(s.f0, n_dot_v);
	float es = luminance(fv), ed = luminance(s.diffuse * (1.0 - fv));
	if (ed <= 0.0) return 1.0;
	return clamp(es / max(es + ed, 1e-6), 0.05, 0.95);
}

// The chance the coat's lobe is picked, by how much it reflects toward the eye, kept
// between bounds so neither it nor the surface under it starves; 0 without a coat.
float coat_chance(Surface s, float n_dot_v) {
	if (s.coat <= 0.0) return 0.0;
	float fc = s.coat_f0 + (1.0 - s.coat_f0) * pow(1.0 - clamp(n_dot_v, 0.0, 1.0), 5.0);
	return s.coat * clamp(4.0 * fc, 0.15, 0.6);
}

// Charlie sheen's distribution (Estevez and Kulla 2017, as glTF's KHR_materials_sheen
// defines it) and Neubelt's visibility: the soft rim of velvet and fuzz.
float sheen_term(float n_dot_h, float n_dot_l, float n_dot_v, float a) {
	float inv = 1.0 / max(a, 1e-3);
	float sin2 = max(1.0 - n_dot_h * n_dot_h, 0.0);
	float D = (2.0 + inv) * pow(sin2, 0.5 * inv) / (2.0 * PI);
	return D / (4.0 * (n_dot_l + n_dot_v - n_dot_l * n_dot_v));
}

// The BSDF times the cosine toward `l`, and the pdf of picking `l` with bsdf_sample (the
// mixture of its lobes); `shine` scales the specular lobe, as a light's Highlight does
// (1 as usual). A coat (OpenPBR's, layered as Filament does) reflects by its own GGX lobe
// and dims what is under it by its Fresnel, toward the eye and toward the light; sheen
// adds to the diffuse part, sampled with it.
float3 bsdf_eval(Surface s, float3 n, float3 v, float3 l, out float pdf, float shine = 1.0) {
	pdf = 0.0;
	float n_dot_l = dot(n, l), n_dot_v = dot(n, v);
	if (n_dot_l <= 0.0 || n_dot_v <= 0.0) return float3(0.0);
	float3 h = normalize(v + l);
	float n_dot_h = max(dot(n, h), 0.0), v_dot_h = max(dot(v, h), 0.0);
	float D = ggx_d(n_dot_h, s.a);
	float lv = ggx_lambda(n_dot_v, s.a), ll = ggx_lambda(n_dot_l, s.a);
	float3 F = fresnel(s.f0, v_dot_h);
	// Given back the light its microfacets scatter between them; worked out here rather
	// than kept with the surface, which held registers across the whole bounce.
	float3 spec = F * energy_compensation(s.f0, n_dot_v, sqrt(s.a)) * (D / ((1.0 + lv + ll) * 4.0 * n_dot_v * n_dot_l));
	float3 diff = s.diffuse * (1.0 - fresnel(s.f0, n_dot_v)) / PI;
	float ps = specular_chance(s, n_dot_v);
	// The visible normals' pdf of h, carried over to l: G1(v) D / (4 n.v).
	float pdf_spec = D / ((1.0 + lv) * 4.0 * n_dot_v);
	pdf = ps * pdf_spec + (1.0 - ps) * n_dot_l / PI;
	float3 f = (diff + spec * shine) * n_dot_l;
	if (any(s.sheen > 0.0)) f += s.sheen * (sheen_term(n_dot_h, n_dot_l, n_dot_v, s.sheen_a) * n_dot_l);
	if (s.coat > 0.0) {
		float dc = ggx_d(n_dot_h, s.coat_a);
		float cv = ggx_lambda(n_dot_v, s.coat_a), cl = ggx_lambda(n_dot_l, s.coat_a);
		float fc = s.coat_f0 + (1.0 - s.coat_f0) * pow(1.0 - v_dot_h, 5.0);
		float coat = s.coat * fc * dc / ((1.0 + cv + cl) * 4.0 * n_dot_v);
		float fv = s.coat_f0 + (1.0 - s.coat_f0) * pow(1.0 - n_dot_v, 5.0);
		float fl = s.coat_f0 + (1.0 - s.coat_f0) * pow(1.0 - n_dot_l, 5.0);
		f = f * ((1.0 - s.coat * fv) * (1.0 - s.coat * fl)) + coat * shine;
		float pc = coat_chance(s, n_dot_v);
		pdf = pc * dc / ((1.0 + cv) * 4.0 * n_dot_v) + (1.0 - pc) * pdf;
	}
	return f;
}

// Whether light `i` is lit by next-event estimation alone, never by a ray the BSDF picked
// meeting it: one that casts no shadow (its light arrives through whatever is between)
// or gives more or less highlight than usual (which scales only the specular lobe of its
// own samples).
bool light_nee_only(int i) {
	return light_extra[i].y > 0.5 || light_extra[i].x != 0.0;
}

// A half vector from GGX's visible normals (Heitz 2018), in the frame where n is +z.
float3 sample_vndf(float3 ve, float a, float2 u) {
	float3 vh = normalize(float3(a * ve.x, a * ve.y, ve.z));
	float lensq = vh.x * vh.x + vh.y * vh.y;
	float3 t1 = lensq > 0.0 ? float3(-vh.y, vh.x, 0.0) * rsqrt(lensq) : float3(1.0, 0.0, 0.0);
	float3 t2 = cross(vh, t1);
	float r = sqrt(u.x), phi = 2.0 * PI * u.y;
	float p1 = r * cos(phi), p2 = r * sin(phi);
	float s = 0.5 * (1.0 + vh.z);
	p2 = (1.0 - s) * sqrt(max(1.0 - p1 * p1, 0.0)) + s * p2;
	float3 nh = p1 * t1 + p2 * t2 + sqrt(max(1.0 - p1 * p1 - p2 * p2, 0.0)) * vh;
	return normalize(float3(a * nh.x, a * nh.y, max(nh.z, 0.0)));
}

// A direction to continue in, picked from one lobe; false where it would go under the
// surface.
bool bsdf_sample(Surface s, float3 n, float3 v, out float3 l) {
	float3 t, b;
	basis(n, t, b);
	float n_dot_v = max(dot(n, v), 1e-4);
	float2 u = float2(rnd(), rnd());
	if (s.coat > 0.0 && rnd() < coat_chance(s, n_dot_v)) {
		float3 ve = float3(dot(v, t), dot(v, b), dot(v, n));
		float3 hl = sample_vndf(ve, s.coat_a, u);
		l = reflect(-v, t * hl.x + b * hl.y + n * hl.z);
	} else if (rnd() < specular_chance(s, n_dot_v)) {
		float3 ve = float3(dot(v, t), dot(v, b), dot(v, n));
		float3 hl = sample_vndf(ve, s.a, u);
		float3 h = t * hl.x + b * hl.y + n * hl.z;
		l = reflect(-v, h);
	} else {
		float r = sqrt(u.x), phi = 2.0 * PI * u.y;
		l = normalize(t * (r * cos(phi)) + b * (r * sin(phi)) + n * sqrt(max(1.0 - u.x, 0.0)));
	}
	return dot(n, l) > 0.0;
}

// Subsurface scattering by a random walk through the inside of the mesh (Chiang, Kutz and
// Burley 2016, "Practical and Controllable Subsurface Scattering for Production Path
// Tracing", as Cycles' and Arnold's random walks do it): the light crosses the surface,
// scatters from point to point inside, losing a share each time, and leaves where the walk
// next meets the surface. It needs a closed mesh, which sculpts are; a walk that finds no
// way out within WALK_STEPS is taken as absorbed. Thin parts (ears, fingers, the rim of a
// leaf) let light through by themselves, which a diffusion profile spread over the
// surface does not.
static const int WALK_STEPS = 256;

// The pdf a glass's lobe passes on for weighing the lights its ray meets: large enough that
// they count whole (power_weight squares it, so it stays far below the float range).
static const float CLEAR_PDF = 1e15;

// The single-scattering albedo whose many scatterings give colour `a` back (van de Hulst's
// relation as Chiang et al. fit it), so the material's colour is the colour seen.
float3 walk_albedo(float3 a) {
	a = clamp(a, float3(0.0), float3(0.999));
	float3 s = 4.09712 + 4.20863 * a - sqrt(9.59217 + 41.6808 * a + 17.7126 * a * a);
	return 1.0 - s * s;
}

// A direction scattered from `d` by Henyey and Greenstein's phase function with mean
// cosine `g` (0 the same every way, toward 1 onward, toward -1 back), sampled exactly, so
// the phase function over its pdf is 1.
float3 sample_phase(float3 d, float g) {
	float u = rnd(), phi = 2.0 * PI * rnd();
	float c = 1.0 - 2.0 * u;
	if (abs(g) > 1e-3) {
		float q = (1.0 - g * g) / (1.0 - g + 2.0 * g * u);
		c = clamp((1.0 + g * g - q * q) / (2.0 * g), -1.0, 1.0);
	}
	float sn = sqrt(max(1.0 - c * c, 0.0));
	float3 t, b;
	basis(d, t, b);
	return normalize(t * (sn * cos(phi)) + b * (sn * sin(phi)) + d * c);
}

// A walk in from `p` (outward geometric normal `ng`) through a medium of colour `color`
// whose light travels `radius` (per channel, in world units) between scatterings, with
// phase `g`. On the way out it gives where it left, the outward geometric and shading
// normals there, and multiplies `weight` by what the walk let through; false when the
// light was absorbed inside.
// Henyey and Greenstein's phase function at cosine `c` between the old and new directions.
float phase_hg(float c, float g) {
	float k = 1.0 + g * g - 2.0 * g * c;
	return (1.0 - g * g) / (4.0 * PI * k * sqrt(k));
}

// Dwivedi's guiding (Krivanek and d'Eon 2014, "A Zero-variance-based Sampling Scheme for
// Monte Carlo Subsurface Scattering", as Cycles' random walk uses it): in a medium that
// scatters most of its light, a walk wanders far before it finds the surface, so steps are
// also drawn leaning toward it, by the pdf a zero-variance walk in a half space would use.
// `v` is that walk's diffusion length for single-scattering albedo `a` (their eq. 67),
// kept above 1 where the albedo is low and guiding hardly matters.
float3 dwivedi_v(float3 a) {
	a = clamp(a, float3(0.05), float3(0.999));
	float3 e = 2.44294 - 0.0215813 * a + 0.578637 / a;
	return max(1.0 / sqrt(max(1.0 - pow(a, e), 1e-12)), float3(1.01));
}

// A direction leaning toward `axis` with Dwivedi's pdf over the cosine mu to it,
// 1 / ((v - mu) log((v + 1) / (v - 1))), sampled exactly.
float3 sample_dwivedi(float3 axis, float v) {
	float mu = clamp(v - (v + 1.0) * pow((v - 1.0) / (v + 1.0), rnd()), -1.0, 1.0);
	float phi = 2.0 * PI * rnd(), sn = sqrt(max(1.0 - mu * mu, 0.0));
	float3 t, b;
	basis(axis, t, b);
	return normalize(t * (sn * cos(phi)) + b * (sn * sin(phi)) + axis * mu);
}

// That direction's pdf over solid angle.
float dwivedi_pdf(float mu, float v) {
	return 1.0 / (2.0 * PI * (v - mu) * log((v + 1.0) / (v - 1.0)));
}

// The chance a step after the first is drawn by Dwivedi's guiding rather than the phase
// function (Cycles' choice); both are weighed together, so either alone stays unbiased.
static const float WALK_GUIDED = 0.75;

bool subsurface_walk(float3 p, float3 ng, float3 color, float3 radius, float g, inout float3 weight, out float3 p_out, out float3 ng_out, out float3 n_out) {
	p_out = p;
	ng_out = ng;
	n_out = ng;
	float3 sigma_t = 1.0 / max(radius, float3(1e-6));
	float3 albedo = walk_albedo(color);
	// In through the surface, cosine-weighted about the inward normal: the light the
	// surface lets in comes in at every angle.
	float3 t, b;
	basis(-ng, t, b);
	float2 u = float2(rnd(), rnd());
	float r = sqrt(u.x), phi = 2.0 * PI * u.y;
	float3 d = normalize(t * (r * cos(phi)) + b * (r * sin(phi)) - ng * sqrt(max(1.0 - u.x, 0.0)));
	float3 o = offset_ray(p, -ng);
	float3 through = float3(1.0);
	// The guided steps lean toward the surface the light came in by.
	float3 v = dwivedi_v(albedo);
	float mu = 0.0, phase = 1.0;
	for (int step = 0; step < WALK_STEPS; step++) {
		// A step drawn by one channel, picked by how much each still carries; after the
		// first, by the phase function or by Dwivedi's guiding, its direction then its
		// length (a guided step's medium thinned the more the step leans toward the surface,
		// as the zero-variance walk's is). Each step is weighed against drawing it every way
		// (the one-sample balance heuristic over channels and techniques), so a channel that
		// travels far (red in skin) is followed without the others' noise.
		float3 chance = through / max(through.r + through.g + through.b, 1e-12);
		float pick = rnd();
		int c = pick < chance.r ? 0 : (pick < chance.r + chance.g ? 1 : 2);
		float sigma = sigma_t[c];
		if (step > 0) {
			float3 before = d;
			bool guided = rnd() < WALK_GUIDED;
			d = guided ? sample_dwivedi(ng, v[c]) : sample_phase(before, g);
			mu = dot(d, ng);
			phase = phase_hg(dot(before, d), g);
			if (guided) sigma *= 1.0 - mu / v[c];
		}
		float dist = -log(max(1.0 - rnd(), 1e-12)) / sigma;
		Hit hit;
		bool out_now = trace(o, d, dist, false, hit);
		float t_step = out_now ? hit.t : dist;
		float3 pass = exp(-sigma_t * t_step);
		// The chance of this step, every way it could have been drawn: stopping at t_step
		// (scattering) or getting past it (leaving).
		float3 classic = out_now ? pass : sigma_t * pass;
		float pdf = dot(chance, classic);
		if (step > 0) {
			float3 sigma_g = sigma_t * (1.0 - mu / v);
			float3 pass_g = exp(-sigma_g * t_step);
			float3 guided_t = out_now ? pass_g : sigma_g * pass_g;
			float3 dir_g = float3(dwivedi_pdf(mu, v.x), dwivedi_pdf(mu, v.y), dwivedi_pdf(mu, v.z));
			pdf = dot(chance, WALK_GUIDED * dir_g * guided_t + (1.0 - WALK_GUIDED) * phase * classic);
		}
		if (out_now) {
			// Out: the light got this far without scattering again.
			through *= phase * pass / max(pdf, 1e-12);
			uint ia = indices[3u * hit.tri], ib = indices[3u * hit.tri + 1u], ic = indices[3u * hit.tri + 2u];
			uint base = items[hit.item].offs.x;
			float4x4 model = items[hit.item].model;
			float3 p0 = vertex(base + ia), p1 = vertex(base + ib), p2 = vertex(base + ic);
			float w0 = 1.0 - hit.uv.x - hit.uv.y;
			p_out = (mul(float4(p0 * w0 + p1 * hit.uv.x + p2 * hit.uv.y, 1.0), model)).xyz;
			ng_out = normalize(mul(cross(p1 - p0, p2 - p0), (float3x3)model));
			if (dot(ng_out, d) < 0.0) ng_out = -ng_out;
			float3 nm = vertex_normal(base + ia) * w0 + vertex_normal(base + ib) * hit.uv.x + vertex_normal(base + ic) * hit.uv.y;
			n_out = normalize(mul(nm, (float3x3)model));
			if (dot(n_out, ng_out) < 0.0) n_out = -n_out;
			weight *= through;
			return true;
		}
		// Scattered here: what was not absorbed, over the chance of stopping here.
		through *= phase * albedo * sigma_t * pass / max(pdf, 1e-12);
		o += d * dist;
		// Russian roulette once the walk is long, by how much it still carries.
		if (step >= 8) {
			float q = clamp(max(through.r, max(through.g, through.b)), 0.05, 0.95);
			if (rnd() > q) return false;
			through /= q;
		}
	}
	return false;
}

// A direction uniformly over the whole sphere.
float3 sample_sphere() {
	float z = 1.0 - 2.0 * rnd(), phi = 2.0 * PI * rnd();
	float r = sqrt(max(1.0 - z * z, 0.0));
	return float3(r * cos(phi), r * sin(phi), z);
}

// A direction in the cone of cosine `cos_max` about `axis`, uniformly.
float3 sample_cone(float3 axis, float cos_max) {
	float3 t, b;
	basis(axis, t, b);
	float c = 1.0 - rnd() * (1.0 - cos_max);
	float s = sqrt(max(1.0 - c * c, 0.0)), phi = 2.0 * PI * rnd();
	return normalize(t * (s * cos(phi)) + b * (s * sin(phi)) + axis * c);
}

float cone_pdf(float cos_max) {
	return 1.0 / (2.0 * PI * max(1.0 - cos_max, 1e-7));
}

// How much of a point or spot light's radiance arrives at distance² `d2` from it along `l`
// (toward the light): its window at its reach and a spot's cone.
float light_falloff(int i, float d2, float3 l) {
	return light_window(light_pos[i], light_shape[i], light_spot[i], d2, l);
}

// Where a ray from `o` along unit `d` meets the sphere, or -1.
float sphere_hit(float3 o, float3 d, float3 c, float r) {
	float3 oc = o - c;
	float b = dot(oc, d);
	float q = dot(oc, oc) - r * r;
	float disc = b * b - q;
	if (disc < 0.0) return -1.0;
	float s = sqrt(disc);
	float t = -b - s;
	if (t < 0.0) t = -b + s;
	return t;
}

// The cone of directions sphere light `i` fills seen from `p`: its cosine, or 2 when `p`
// is inside it.
float sphere_cone(int i, float3 p) {
	float3 d = light_pos[i].xyz - p;
	float d2 = dot(d, d), r = light_size[i].x;
	if (d2 <= r * r) return 2.0;
	return sqrt(1.0 - r * r / d2);
}

float power_weight(float a, float b) {
	return a * a / max(a * a + b * b, 1e-30);
}

// What a path that leaves the scene along `d` takes: the image environment, or the
// built-in studio at the ambient light's strength as the viewport's diffuse takes it.
float3 environment(float3 d) {
	if (RT_ENV_IMAGE != 0u && env.x > 0.5) {
		float3 e = mul(d, transpose(float3x3(env_x.xyz, env_y.xyz, env_z.xyz)));
		return environment_map.SampleLevel(panorama_uv(e), 0.0).rgb * env.y;
	}
	float3x3 to_rig = transpose(float3x3(rig_x.xyz, rig_y.xyz, rig_z.xyz));
	return studio(mul(d, to_rig), STUDIO_BLUR) * (0.7 * rig_x.w);
}

// The environment's frame: its own axes in the world, an image's or the studio's.
float3x3 env_frame() {
	return RT_ENV_IMAGE != 0u && env.x > 0.5 ? float3x3(env_x.xyz, env_y.xyz, env_z.xyz) : float3x3(rig_x.xyz, rig_y.xyz, rig_z.xyz);
}

// A direction (world) picked by the environment's table, and its density.
float3 env_sample(out float pdf) {
	int2 ts = texture_size(env_table);
	int count = ts.x * ts.y;
	float u = rnd() * float(count);
	int i = min(int(u), count - 1);
	float4 e = load_texel(env_table, int2(i % ts.x, i / ts.x));
	if (frac(u) >= e.x) {
		i = int(e.y);
		e = load_texel(env_table, int2(i % ts.x, i / ts.x));
	}
	float2 uv = (float2(i % ts.x, i / ts.x) + float2(rnd(), rnd())) / float2(ts);
	float3 local = panorama_dir(uv);
	pdf = e.z / max(sqrt(max(1.0 - local.y * local.y, 0.0)), 1e-4);
	return mul(local, env_frame());
}

// The density env_sample gives direction `d` (world).
float env_pdf(float3 d) {
	float3 local = mul(d, transpose(env_frame()));
	int2 ts = texture_size(env_table);
	int2 at = min(int2(panorama_uv(local) * float2(ts)), ts - 1);
	return load_texel(env_table, at).z / max(sqrt(max(1.0 - local.y * local.y, 0.0)), 1e-4);
}

// One light's light at a surface (next-event estimation): the environment or a light,
// picked by how much light each gives, a direction toward it, the BSDF there and a shadow
// ray, weighted against finding the light by the BSDF.
float3 direct_light(Surface s, float3 p, float3 ng, float3 n, float3 v) {
	float pick = rnd();
	if (pick < env.z) {
		float pdf_env;
		float3 l = env_sample(pdf_env);
		if (dot(ng, l) <= 0.0) return float3(0.0);
		float pdf_bsdf;
		float3 f = bsdf_eval(s, n, v, l, pdf_bsdf);
		if (luminance(f) <= 0.0) return float3(0.0);
		float3 radiance = environment(l);
		float pdf_light = env.z * pdf_env;
		if (luminance(radiance) <= 0.0 || pdf_light <= 0.0) return float3(0.0);
		Hit shadow;
		if (trace(offset_ray(p, ng), l, FAR, true, shadow)) return float3(0.0);
		return f * radiance * (power_weight(pdf_light, pdf_bsdf) / pdf_light);
	}
	int i = -1;
	for (int k = 0; k < LIGHT_COUNT; k++) {
		if (light_size[k].w > 0.0 && pick < light_size[k].z) {
			i = k;
			break;
		}
	}
	if (i < 0) return float3(0.0);
	float3 l;
	float dist = FAR, pdf_dir;
	float3 radiance = light_color[i].rgb * light_size[i].y;
	if (RT_SPHERE_LIGHTS == 0u || light_pos[i].w < 0.5) {
		l = sample_cone(light_pos[i].xyz, light_size[i].x);
		pdf_dir = cone_pdf(light_size[i].x);
	} else {
		float cos_max = sphere_cone(i, p);
		if (cos_max > 1.0) return float3(0.0);
		float3 to = light_pos[i].xyz - p;
		l = sample_cone(normalize(to), cos_max);
		pdf_dir = cone_pdf(cos_max);
		dist = sphere_hit(p, l, light_pos[i].xyz, light_size[i].x);
		if (dist <= 0.0) return float3(0.0);
		radiance *= light_falloff(i, dot(to, to), normalize(to));
	}
	if (dot(ng, l) <= 0.0 || luminance(radiance) <= 0.0) return float3(0.0);
	float pdf_bsdf;
	float3 f = bsdf_eval(s, n, v, l, pdf_bsdf, 1.0 + light_extra[i].x);
	if (luminance(f) <= 0.0) return float3(0.0);
	float pdf_light = light_size[i].w * pdf_dir;
	if (light_nee_only(i)) {
		Hit blocked;
		if (light_extra[i].y < 0.5 && trace(offset_ray(p, ng), l, dist, true, blocked)) return float3(0.0);
		return f * (radiance / pdf_light);
	}
	Hit shadow;
	if (trace(offset_ray(p, ng), l, dist, true, shadow)) return float3(0.0);
	return f * radiance * (power_weight(pdf_light, pdf_bsdf) / pdf_light);
}

// The lights a ray picked by the BSDF meets before `t_hit` (suns only when it leaves the
// scene), weighted against finding them by next-event estimation.
float3 lights_met(float3 o, float3 d, float t_hit, bool escaped, float pdf_bsdf) {
	float3 sum = float3(0.0);
	for (int i = 0; i < LIGHT_COUNT; i++) {
		if (light_size[i].w <= 0.0 || light_nee_only(i)) continue;
		float3 radiance = light_color[i].rgb * light_size[i].y;
		float pdf_dir;
		if (RT_SPHERE_LIGHTS == 0u || light_pos[i].w < 0.5) {
			if (!escaped || dot(d, light_pos[i].xyz) < light_size[i].x) continue;
			pdf_dir = cone_pdf(light_size[i].x);
		} else {
			float t = sphere_hit(o, d, light_pos[i].xyz, light_size[i].x);
			float cos_max = sphere_cone(i, o);
			if (t <= 0.0 || t >= t_hit || cos_max > 1.0) continue;
			float3 to = light_pos[i].xyz - o;
			radiance *= light_falloff(i, dot(to, to), normalize(to));
			pdf_dir = cone_pdf(cos_max);
		}
		sum += radiance * power_weight(pdf_bsdf, light_size[i].w * pdf_dir);
	}
	return sum;
}


[numthreads(8, 8, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID, uint3 global_id : SV_DispatchThreadID) {
	int2 size = texture_size(prev);
	int2 px = int2(global_id.x, global_id.y + counts.y);
	if (px.x >= size.x || px.y >= size.y) return;
	rng = uint(px.y * size.x + px.x) * 9781u + counts.x * 6271u + 1u;
	pcg_next();
	rng ^= counts.x * 2654435761u;
	pcg_next();

	// The camera's ray through a random point of the pixel, or the first sample's through
	// its centre.
	float2 jitter = float2(rnd(), rnd());
	bool first = counts.x == 0u;
	if (first) jitter = float2(0.5);
	float2 uv = (float2(px) + jitter) / float2(size);
	float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
	float4 near = mul(float4(ndc, 0.0, 1.0), inv_view_proj);
	float4 far = mul(float4(ndc, 1.0, 1.0), inv_view_proj);
	float3 o = near.xyz / near.w;
	float3 d = normalize(far.xyz / far.w - o);
	// The ray through the next pixel across, for how wide a pixel is where the camera's ray
	// meets something (the maps' level).
	float2 ndc_dx = ndc + float2(2.0 / float(size.x), 0.0);
	float4 near_dx = mul(float4(ndc_dx, 0.0, 1.0), inv_view_proj);
	float4 far_dx = mul(float4(ndc_dx, 1.0, 1.0), inv_view_proj);
	float3 o_dx = near_dx.xyz / near_dx.w;
	float3 d_dx = normalize(far_dx.xyz / far_dx.w - o_dx);
	// Depth of field: a thin lens across the eye. The pixel's ray meets the focal plane
	// where it would through a pinhole, and the ray goes there from a point of the lens
	// instead, picked over its disc (Shirley's concentric map), then starts back where the
	// pinhole's did, so the near plane clips as the viewport does. Measured from the eye's
	// plane, so it holds for an orthographic view too, whose rays start far behind it.
	bool lens = RT_LENS != 0u && lens_eye.w > 0.0;
	if (lens) {
		float2 u = 2.0 * float2(rnd(), rnd()) - 1.0;
		float2 disc = float2(0.0);
		if (any(u != float2(0.0))) {
			bool wide = abs(u.x) > abs(u.y);
			float r = wide ? u.x : u.y;
			float phi = wide ? 0.78539816 * (u.y / u.x) : 1.57079633 - 0.78539816 * (u.x / u.y);
			disc = r * float2(cos(phi), sin(phi));
		}
		float3 fwd = lens_fwd.xyz;
		float along = dot(d, fwd);
		float3 e = o + d * (dot(lens_eye.xyz - o, fwd) / along);
		float3 focal = e + d * (lens_right.w / along);
		float3 from = e + lens_eye.w * (disc.x * lens_right.xyz + disc.y * lens_up.xyz);
		float3 dl = normalize(focal - from);
		o = from + dl * (dot(o - from, fwd) / dot(dl, fwd));
		d = dl;
	}

	float3 radiance = float3(0.0), weight = float3(1.0), absorb = float3(0.0);
	float covered = 0.0, pdf_bsdf = 0.0;
	float4 guide_a = float4(0.0), guide_n = float4(0.0);
	int bounces = int(counts.z);
	for (int bounce = 0; bounce <= bounces; bounce++) {
		Hit hit;
		bool met = trace(o, d, FAR, false, hit);
		// The shadow catcher: a camera ray meeting its plane nearer than the scene asks one
		// ray toward the light whether the point is in shadow; the pixel then covers by that
		// shadow, adding no light. Only sets values, so a kernel without it folds it away.
		bool caught = false;
		float shadowed = 0.0;
		if (RT_CATCHER != 0u && bounce == 0 && catcher.w > 0.5) {
			int axis = int(catcher.x);
			float dt = d[axis];
			float t_plane = abs(dt) > 1e-8 ? (catcher.y - o[axis]) / dt : -1.0;
			if (t_plane > 0.0 && (!met || t_plane < hit.t)) {
				float3 pp = o + d * t_plane;
				float3 np = float3(0.0);
				np[axis] = o[axis] > catcher.y ? 1.0 : -1.0;
				int li = int(catcher_light.x);
				float3 l;
				float reach = FAR;
				if (light_pos[li].w < 0.5) {
					l = sample_cone(light_pos[li].xyz, light_size[li].x);
				} else {
					float3 to = light_pos[li].xyz + light_size[li].x * sample_sphere() - pp;
					reach = length(to);
					l = to / max(reach, 1e-8);
				}
				Hit blocker;
				shadowed = dot(l, np) > 0.0 && trace(offset_ray(pp, np), l, reach, true, blocker) ? catcher.z : 0.0;
				caught = true;
			}
		}
		if (caught) {
			covered = shadowed;
			break;
		}
		// Light absorbed on the way through a glass's inside (Beer and Lambert), zero
		// outside one.
		if (met && any(absorb > 0.0)) weight *= exp(-absorb * hit.t);
		// The camera never sees the lights, as in the viewport.
		if (bounce > 0) radiance += weight * lights_met(o, d, met ? hit.t : FAR, !met, pdf_bsdf);
		if (!met) {
			// Weighed against the environment's own samples, when it has any.
			if (bounce > 0) radiance += weight * environment(d) * (env.z > 0.0 ? power_weight(pdf_bsdf, env.z * env_pdf(d)) : 1.0);
			break;
		}
		if (bounce == 0) covered = 1.0;
		if (bounce == bounces) break;

		uint ia = indices[3u * hit.tri], ib = indices[3u * hit.tri + 1u], ic = indices[3u * hit.tri + 2u];
		uint base = items[hit.item].offs.x, flags = items[hit.item].offs.y & RT_ITEMS;
		float4x4 model = items[hit.item].model;
		float w0 = 1.0 - hit.uv.x - hit.uv.y;
		float3 p0 = vertex(base + ia), p1 = vertex(base + ib), p2 = vertex(base + ic);
		float3 p = (mul(float4(p0 * w0 + p1 * hit.uv.x + p2 * hit.uv.y, 1.0), model)).xyz;
		float3 ng = normalize(mul(cross(p1 - p0, p2 - p0), (float3x3)model));
		// Whether the ray met the triangle's front (the mesh's outside), before the normal
		// is turned to face it: glass refracts in or out by it.
		bool front = dot(ng, d) <= 0.0;
		if (dot(ng, d) > 0.0) ng = -ng;
		float3 nm = (flags & ITEM_SKINNED) != 0u
			? skin_normal(hit.item, hit.tri - items[hit.item].tex.x, float3(w0, hit.uv), uint3(ia, ib, ic))
			: vertex_normal(base + ia) * w0 + vertex_normal(base + ib) * hit.uv.x + vertex_normal(base + ic) * hit.uv.y;
		float3 n = normalize(mul(nm, (float3x3)model));
		if (dot(n, ng) < 0.0) n = -n;
		float3 v = -d;
		// A shading normal facing away from the eye shades as the triangle does.
		if (dot(n, v) <= 0.0) n = ng;

		float3 albedo = items[hit.item].color.rgb;
		float2 surf = items[hit.item].surface.xy;
		// Which of the item's materials the hit takes (slot 0 its own) in its table.
		uint table = items[hit.item].offs.w, material = 0u;
		if ((flags & (ITEM_PAINT | ITEM_GROUPS | ITEM_SLOTS)) != 0u) {
			// The group from the corner the triangle is drawn from, as mesh.vert.slang takes it.
			uint group = vertex_paint(base + ia).y & 0xFFFFu;
			if ((flags & ITEM_SLOTS) != 0u) {
				for (uint k = 1u; k < 16u; k++) {
					if (items[hit.item].slot_group[k >> 2][k & 3u] == group) {
						albedo = material_row(table, k, 0u).rgb;
						surf = material_row(table, k, 1u).xy;
						material = k;
					}
				}
			}
			if ((flags & ITEM_PAINT) != 0u) {
				float4 c0 = unpackUnorm4x8ToFloat(vertex_paint(base + ia).x);
				float4 c1 = unpackUnorm4x8ToFloat(vertex_paint(base + ib).x);
				float4 c2 = unpackUnorm4x8ToFloat(vertex_paint(base + ic).x);
				float4 paint = float4(srgb_decode(c0.rgb), c0.a) * w0 + float4(srgb_decode(c1.rgb), c1.a) * hit.uv.x + float4(srgb_decode(c2.rgb), c2.a) * hit.uv.y;
				albedo = lerp(albedo, paint.rgb, paint.a);
				// Painted roughness and metal, on a physically based item as the view shades them.
				if (surf.y > 0.0 && (flags & ITEM_MATERIAL) != 0u) {
					float4 m = paint_material(vertex_material(base + ia)) * w0 + paint_material(vertex_material(base + ib)) * hit.uv.x + paint_material(vertex_material(base + ic)) * hit.uv.y;
					surf = paint_surface(surf, m);
				}
			}
			if ((flags & ITEM_GROUPS) != 0u) albedo = group_color(group);
		}
		if ((flags & ITEM_TEXTURED) != 0u) {
			// The preview's corners for this triangle, in its own corner order.
			uint4 tex = items[hit.item].tex;
			uint at = tex.y + 3u * (hit.tri - tex.x);
			Tex_Vertex t0 = tex_vertex(tex.z + 8u * textured[at]);
			Tex_Vertex t1 = tex_vertex(tex.z + 8u * textured[at + 1u]);
			Tex_Vertex t2 = tex_vertex(tex.z + 8u * textured[at + 2u]);
#ifdef MAP_ARRAY
			uint slot = (tex.w >> 16) & 255u, view = (tex.w >> 4) & 15u, maps = (tex.w >> 8) & 31u;
#else
			uint slot = tex.w & 15u, view = (tex.w >> 4) & 15u, maps = tex.w >> 8;
#endif
			float2 uv_up = t0.uv * w0 + t1.uv * hit.uv.x + t2.uv * hit.uv.y;
			float2 uv = float2(uv_up.x, 1.0 - uv_up.y);
			// The level the maps are read at: the camera's ray at the size of its pixel
			// where it meets the triangle, over the triangle's UVs; a path's later
			// bounces, which only gather light, a coarse one.
			float lod = -6.0;
			if (bounce == 0) {
				float3 e1 = mul((p1 - p0), (float3x3)model), e2 = mul((p2 - p0), (float3x3)model);
				float2 u1 = t1.uv - t0.uv, u2 = t2.uv - t0.uv;
				float world_area = length(cross(e1, e2));
				float uv_area = abs(u1.x * u2.y - u1.y * u2.x);
				float footprint = length(o_dx + d_dx * hit.t - p);
				lod = log2(max(footprint * sqrt(uv_area / max(world_area, 1e-30)), 1e-12));
			}
			// The normal from the preview's vertices, then the normal map, in the frame the
			// bake solved for (the interpolated normal and tangent, unnormalized, the
			// bitangent from their cross product), all turned without the object's scale,
			// as textured.vert.slang does; then turned round whole on the back, as the viewport
			// does, so the map is not mirrored there.
			float3x3 turn = (float3x3)model / length(model[0].xyz);
			float3 nv = mul(t0.n * w0 + t1.n * hit.uv.x + t2.n * hit.uv.y, turn);
			float4 tw = t0.t * w0 + t1.t * hit.uv.x + t2.t * hit.uv.y;
			float3 tv = mul(tw.xyz, turn);
			float3 mapped = normalize(nv);
			if ((view == 1u || view == 2u) && (maps & 20u) != 0u) {
				// The painted height, when there is any, holds the normal map's place.
				float3 tn = float3(0.0, 0.0, 1.0);
				if ((maps & 16u) != 0u) tn.xy -= paint_height_slope_at(slot, uv);
				else tn = map_at(slot, 2u, uv, lod).xyz * 2.0 - 1.0;
				float3 bv = (tw.w < 0.0 ? -1.0 : 1.0) * cross(nv, tv);
				float3 m = tn.x * tv + tn.y * bv + tn.z * nv;
				if (dot(m, m) > 0.0) mapped = normalize(m);
			}
			if (dot(mul(cross(p1 - p0, p2 - p0), (float3x3)model), d) > 0.0) mapped = -mapped;
			n = dot(mapped, v) > 0.0 ? mapped : ng;
			// A normal map tilts the normal far from the triangle's, and the eye's mirror
			// direction about it can then point into the surface, where a smooth surface's
			// paths end black: bend the normal just enough to keep that direction on the
			// surface's side (the half vector between the eye and the mirror direction laid
			// on the horizon, as production path tracers do).
			float3 r = reflect(-v, n);
			float under = dot(ng, r);
			if (under < 0.0) n = normalize(v + normalize(r - ng * (under - 1e-3)));
			if (view == 1u && (maps & 1u) != 0u) albedo = items[hit.item].color.rgb * map_at(slot, 0u, uv, lod).rgb;
			if (view == 1u && (maps & 2u) != 0u) {
				float3 orm = map_at(slot, 1u, uv, lod).rgb;
				surf = float2(orm.b, max(orm.g, 0.04));
			}
			// Texture paint (path.odin's TEX_MAPS_PAINT) in the base colour and ORM slots,
			// premultiplied, over the material and the vertex paint, as mesh_shading lays it.
			if (view == 1u && (maps & 8u) != 0u) {
				float4 pc = map_at(slot, 0u, uv, lod);
				albedo = albedo * (1.0 - pc.a) + pc.rgb;
				if (surf.y > 0.0) {
					float4 pm = map_at(slot, 1u, uv, lod);
					surf.x = surf.x * (1.0 - pm.w) + pm.z;
					surf.y = max(surf.y * (1.0 - pm.y) + pm.x, 0.04);
				}
			}
			if (view == 3u) albedo *= uv_checker(uv);
		}
		if (bounce == 0) {
			guide_a = float4(albedo, 1.0);
			guide_n = float4(n, hit.t);
		}
		float metallic = clamp(surf.x, 0.0, 1.0);
		Surface s = surface_plain(albedo * (1.0 - metallic), lerp(float3(0.04), albedo, metallic), max(surf.y * surf.y, 1e-3));
		if ((flags & ITEM_LAYERS) != 0u) {
			// The material's layers (rows 4 to 9 of its table, geom.Material_Layers): the
			// base's reflectance from its IOR and specular weight, the coat, sheen, and the
			// light it gives off, which a path meeting it gathers (no light estimate aims
			// at a glowing surface, so nothing counts it twice).
			float4 coat = material_row(table, material, 4u);
			float4 sheen = material_row(table, material, 5u);
			float4 glow = material_row(table, material, 6u);
			float sheen_r = material_row(table, material, 8u).z;
			float lessen = material_row(table, material, 9u).w;
			float r0 = (coat.w - 1.0) / (coat.w + 1.0);
			s.f0 = lerp(float3(r0 * r0 * (1.0 - lessen)), albedo, metallic);
			// A thin film's colours over that reflectance, at the angle the eye sees it
			// from, as the viewport takes them.
			float4 film = material_row(table, material, 9u);
			if (film.x > 0.0) s.f0 = lerp(s.f0, thin_film(max(dot(n, v), 1e-4), s.f0, film.y, film.z), film.x);
			float c0 = (coat.z - 1.0) / (coat.z + 1.0);
			s.coat = coat.x;
			s.coat_a = max(coat.y * coat.y, 1e-3);
			s.coat_f0 = c0 * c0;
			s.sheen = sheen.rgb * sheen.w;
			s.sheen_a = max(sheen_r * sheen_r, 1e-3);
			radiance += weight * (glow.rgb * glow.w);
		}

		// What the subsurface branch below changes, so the lighting, sampling and leaving of
		// the loop stay in the one tail after it: a branch holding a break or continue of
		// its own is not folded away when the kernel is specialised to a scene without
		// subsurface materials, and cost such a kernel half its speed (kernel_stats.py).
		bool absorbed = false;
		float lobe = 1.0;
		// Transmission (glass, liquids): with the chance of its weight the surface is a
		// dielectric interface, a microfacet normal drawn from GGX's visible normals, then
		// reflected off it or refracted through it by its exact Fresnel (OpenPBR's
		// specular weight scaling the reflection, as glTF's specular factor does); a
		// thin-walled one lets the light straight through. Its direction is given to the
		// tail below, which neither lights it (a near-mirror lobe gains nothing from a light
		// estimate) nor weighs the lights it meets against one.
		bool clear = false;
		float3 l_clear = float3(0.0);
		if ((flags & ITEM_TRANSMIT) != 0u) {
			float4 tint = material_row(table, material, 7u);
			float4 sheet = material_row(table, material, 8u);
			if (tint.w * (1.0 - metallic) > 0.0 && rnd() < tint.w * (1.0 - metallic)) {
				float ior = material_row(table, material, 4u).w;
				float lessen = material_row(table, material, 9u).w;
				bool thin = sheet.y > 0.5;
				float eta = thin || front ? ior : 1.0 / ior;
				float3 t, b;
				basis(n, t, b);
				float3 ve = float3(dot(v, t), dot(v, b), dot(v, n));
				float3 hl = sample_vndf(ve, s.a, float2(rnd(), rnd()));
				float3 h = normalize(t * hl.x + b * hl.y + n * hl.z);
				float v_dot_h = max(dot(v, h), 1e-4);
				float fr = fresnel_dielectric(v_dot_h, eta);
				if (fr < 1.0) fr *= 1.0 - lessen;
				// A thin film colours what the interface reflects (and so what passes): the
				// film's reflectance per channel at this angle, the chance of reflecting its
				// mean, each way weighted by its colour over that chance.
				float4 film = material_row(table, material, 9u);
				float3 fr3 = float3(fr);
				if ((flags & ITEM_LAYERS) != 0u && film.x > 0.0 && fr < 1.0) {
					fr3 = lerp(fr3, thin_film(v_dot_h, float3(fr), film.y, film.z), film.x);
					fr = clamp((fr3.r + fr3.g + fr3.b) / 3.0, 1e-3, 0.999);
				}
				l_clear = reflect(-v, h);
				bool passes = rnd() >= fr;
				weight *= passes ? (1.0 - fr3) / (1.0 - fr) : fr3 / fr;
				if (passes) {
					// Through: tinted at the surface, or by absorption along the inside when
					// the material gives the depth its colour is reached at.
					if (thin) l_clear -= 2.0 * dot(l_clear, n) * n;
					else l_clear = refract(-v, h, 1.0 / eta);
					float depth = sheet.x * length(model[0].xyz);
					if (thin || sheet.x <= 0.0) weight *= tint.rgb;
					else if (front) absorb = -log(max(tint.rgb, float3(1e-4))) / depth;
					else absorb = float3(0.0);
				}
				// The visible normals' sampling leaves Smith's masking toward the light.
				float lv = ggx_lambda(max(dot(n, v), 1e-4), s.a), ll = ggx_lambda(abs(dot(n, l_clear)), s.a);
				weight *= (1.0 + lv) / (1.0 + lv + ll);
				clear = true;
			}
		}
		if (!clear && (flags & ITEM_SUBSURFACE) != 0u) {
			// With the chance of its subsurface weight this path's diffuse part goes in
			// under the surface instead of off it, so on average the surface shows its
			// specular, the weight's share scattered inside and the rest as diffuse.
			float4 scatter = material_row(table, material, 2u);
			float sss = scatter.w * (1.0 - metallic);
			if (sss > 0.0 && rnd() < sss) {
				// Off the surface by the specular lobe, or in, chosen by how bright each is.
				// Each counts for its chance's worth more, its light (next-event estimation)
				// included, so the tail below lights and samples whichever was picked: a
				// second light estimate here would be another ray query site, which RADV
				// keeps registers for even where the branch is folded away.
				Surface inside = s;
				inside.diffuse = albedo * scatter.rgb;
				float n_dot_v = max(dot(n, v), 1e-4);
				float ps = specular_chance(inside, n_dot_v);
				if (rnd() < ps) {
					s.diffuse = float3(0.0);
					weight /= ps;
					lobe = ps;
				} else {
					float4 reach = material_row(table, material, 3u);
					float g = material_row(table, material, 8u).w;
					float3 radius = reach.rgb * (reach.w * length(model[0].xyz));
					weight *= (1.0 - fresnel(s.f0, n_dot_v)) / (1.0 - ps);
					float3 p_out, ng_out, n_out;
					absorbed = !subsurface_walk(p, ng, albedo * scatter.rgb, radius, g, weight, p_out, ng_out, n_out);
					// Out again as a white Lambert surface (the walk carries the colour),
					// shaded and continued below as any surface is.
					s = surface_plain(float3(1.0), float3(0.0), 1.0);
					p = p_out;
					ng = ng_out;
					n = n_out;
					v = n_out;
				}
			}
		}
		if (absorbed) break;

		float3 l = l_clear;
		if (!clear) {
			radiance += weight * direct_light(s, p, ng, n, v);

			if (!bsdf_sample(s, n, v, l) || dot(l, ng) <= 0.0) break;
			float3 f = bsdf_eval(s, n, v, l, pdf_bsdf);
			if (pdf_bsdf <= 0.0) break;
			weight *= f / pdf_bsdf;
			// A lobe picked with chance `lobe` (its weight already divided by it) has that
			// chance in its pdf when weighed against the lights it meets.
			pdf_bsdf *= lobe;
		} else {
			// A lobe no light estimate shared: the lights it meets count whole.
			pdf_bsdf = CLEAR_PDF;
		}
		o = offset_ray(p, dot(l, ng) >= 0.0 ? ng : -ng);
		d = l;
		// Russian roulette from the third bounce on, by how much the path still carries.
		if (bounce >= 2) {
			float q = clamp(max(weight.r, max(weight.g, weight.b)), 0.05, 0.95);
			if (rnd() > q) break;
			weight /= q;
		}
	}
	float lum = luminance(radiance);
	if (lum > SAMPLE_CLAMP) radiance *= SAMPLE_CLAMP / lum;
	float4 sum = first ? float4(0.0) : load_texel(prev, px);
	next[px] = sum + float4(radiance, covered);
	if (lens) {
		// Running means over the samples whose ray met the scene, the share that did in
		// the colour's a, so the colour divided out is the colour the blurred light has.
		float4 prev_a = first ? float4(0.0) : load_texel(prev_albedo, px);
		float4 prev_n = first ? float4(0.0) : load_texel(prev_normal, px);
		float done = float(counts.x);
		float hit = guide_a.a, hits_before = prev_a.a * done;
		float hits = hits_before + hit;
		if (hits > 0.0) {
			guide_a = float4((prev_a.rgb * hits_before + guide_a.rgb * hit) / hits, hits / (done + 1.0));
			guide_n = (prev_n * hits_before + guide_n * hit) / hits;
		}
		guide_albedo[px] = guide_a;
		guide_normal[px] = guide_n;
	} else if (first) {
		guide_albedo[px] = guide_a;
		guide_normal[px] = guide_n;
	}
}
