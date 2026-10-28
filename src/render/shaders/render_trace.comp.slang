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

#include "common.slang"
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
	uint4 offs;      // x: the item's first vertex in the merged buffers, y: ITEM_ flags
	uint4 slot_group[4];   // the polygroup of each material slot from 1
	float4 slot_color[16];   // each slot's colour, as `color`
	float4 slot_surface[16]; // ...and surface, as `surface`
	// ITEM_TEXTURED: its first triangle, where its corners and its preview vertices start
	// in `textured`, and its map slot (bits 0-3, 3 for none), view (4-7: 1 the maps, 2 the
	// normal map, 3 the UV checker) and maps it has (8-10: base colour, ORM, normal)
	uint4 tex;
};

static const uint ITEM_PAINT = 1u;  // the polypaint shows over the colour
static const uint ITEM_GROUPS = 2u; // each polygroup shows in its own colour instead
static const uint ITEM_SLOTS = 4u;  // groups may have materials of their own
static const uint ITEM_TEXTURED = 8u; // shows its maps through its preview's UVs

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
// render.Paint_Packed (two words).
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
[[vk::binding(0, 1)]] [[vk::image_format("rgba32f")]] RWTexture2D<float4> next;
// The guides, written by the first sample only (by every sample, as running means over
// the samples, with depth of field): the base colour the camera's ray met with
// 1 in a (0 everywhere for a miss), and its normal (world) with the distance in a.
[[vk::binding(1, 1)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> guide_albedo;
[[vk::binding(2, 1)]] [[vk::image_format("rgba16f")]] RWTexture2D<float4> guide_normal;

#define LIGHT_COUNT 8

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
};

#include "panorama.slang"
#include "studio_env.slang"
#include "light_window.slang"

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

// A vertex's normal in mesh space.
float3 vertex_normal(uint v) {
	return normal_decode(attributes[v]);
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
// map's own size adds half the log2 of its texel count). The samplers are named, not an
// array: indexing one by a value that differs between pixels needs a device feature
// tablets do not promise.
#define MAP_AT(s) { float2 size = float2(texture_size(s)); return s.SampleLevel(uv, max(lod + 0.5 * log2(size.x * size.y), 0.0)); }
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

float luminance(float3 c) {
	return dot(c, float3(0.2126, 0.7152, 0.0722));
}

struct Surface {
	float3 diffuse; // the Lambert part's colour
	float3 f0;      // reflectance seen straight on
	float a;      // GGX alpha, roughness squared
};

float3 fresnel(float3 f0, float c) {
	return f0 + (1.0 - f0) * pow(1.0 - clamp(c, 0.0, 1.0), 5.0);
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

// The BSDF times the cosine toward `l`, and the pdf of picking `l` with bsdf_sample (the
// mixture of both lobes).
float3 bsdf_eval(Surface s, float3 n, float3 v, float3 l, out float pdf) {
	pdf = 0.0;
	float n_dot_l = dot(n, l), n_dot_v = dot(n, v);
	if (n_dot_l <= 0.0 || n_dot_v <= 0.0) return float3(0.0);
	float3 h = normalize(v + l);
	float n_dot_h = max(dot(n, h), 0.0), v_dot_h = max(dot(v, h), 0.0);
	float D = ggx_d(n_dot_h, s.a);
	float lv = ggx_lambda(n_dot_v, s.a), ll = ggx_lambda(n_dot_l, s.a);
	float3 F = fresnel(s.f0, v_dot_h);
	float3 spec = F * (D / ((1.0 + lv + ll) * 4.0 * n_dot_v * n_dot_l));
	float3 diff = s.diffuse * (1.0 - fresnel(s.f0, n_dot_v)) / PI;
	float ps = specular_chance(s, n_dot_v);
	// The visible normals' pdf of h, carried over to l: G1(v) D / (4 n.v).
	float pdf_spec = D / ((1.0 + lv) * 4.0 * n_dot_v);
	pdf = ps * pdf_spec + (1.0 - ps) * n_dot_l / PI;
	return (diff + spec) * n_dot_l;
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
	if (rnd() < specular_chance(s, n_dot_v)) {
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
	if (env.x > 0.5) {
		float3 e = mul(d, transpose(float3x3(env_x.xyz, env_y.xyz, env_z.xyz)));
		return environment_map.SampleLevel(panorama_uv(e), 0.0).rgb * env.y;
	}
	float3x3 to_rig = transpose(float3x3(rig_x.xyz, rig_y.xyz, rig_z.xyz));
	return studio(mul(d, to_rig), STUDIO_BLUR) * (0.7 * rig_x.w);
}

// The environment's frame: its own axes in the world, an image's or the studio's.
float3x3 env_frame() {
	return env.x > 0.5 ? float3x3(env_x.xyz, env_y.xyz, env_z.xyz) : float3x3(rig_x.xyz, rig_y.xyz, rig_z.xyz);
}

// A direction (world) picked by the environment's table, and its density.
float3 env_sample(out float pdf) {
	int2 ts = texture_size(env_table);
	int count = ts.x * ts.y;
	float u = rnd() * float(count);
	int i = min(int(u), count - 1);
	float4 e = env_table.Load(int3(int2(i % ts.x, i / ts.x), 0));
	if (frac(u) >= e.x) {
		i = int(e.y);
		e = env_table.Load(int3(int2(i % ts.x, i / ts.x), 0));
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
	return env_table.Load(int3(at, 0)).z / max(sqrt(max(1.0 - local.y * local.y, 0.0)), 1e-4);
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
	if (light_pos[i].w < 0.5) {
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
	float3 f = bsdf_eval(s, n, v, l, pdf_bsdf);
	if (luminance(f) <= 0.0) return float3(0.0);
	float pdf_light = light_size[i].w * pdf_dir;
	Hit shadow;
	if (trace(offset_ray(p, ng), l, dist, true, shadow)) return float3(0.0);
	return f * radiance * (power_weight(pdf_light, pdf_bsdf) / pdf_light);
}

// The lights a ray picked by the BSDF meets before `t_hit` (suns only when it leaves the
// scene), weighted against finding them by next-event estimation.
float3 lights_met(float3 o, float3 d, float t_hit, bool escaped, float pdf_bsdf) {
	float3 sum = float3(0.0);
	for (int i = 0; i < LIGHT_COUNT; i++) {
		if (light_size[i].w <= 0.0) continue;
		float3 radiance = light_color[i].rgb * light_size[i].y;
		float pdf_dir;
		if (light_pos[i].w < 0.5) {
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
	bool lens = lens_eye.w > 0.0;
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

	float3 radiance = float3(0.0), weight = float3(1.0);
	float covered = 0.0, pdf_bsdf = 0.0;
	float4 guide_a = float4(0.0), guide_n = float4(0.0);
	int bounces = int(counts.z);
	for (int bounce = 0; bounce <= bounces; bounce++) {
		Hit hit;
		bool met = trace(o, d, FAR, false, hit);
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
		uint base = items[hit.item].offs.x, flags = items[hit.item].offs.y;
		float4x4 model = items[hit.item].model;
		float w0 = 1.0 - hit.uv.x - hit.uv.y;
		float3 p0 = vertex(base + ia), p1 = vertex(base + ib), p2 = vertex(base + ic);
		float3 p = (mul(float4(p0 * w0 + p1 * hit.uv.x + p2 * hit.uv.y, 1.0), model)).xyz;
		float3 ng = normalize(mul(cross(p1 - p0, p2 - p0), (float3x3)model));
		if (dot(ng, d) > 0.0) ng = -ng;
		float3 n = normalize(mul((vertex_normal(base + ia) * w0 + vertex_normal(base + ib) * hit.uv.x + vertex_normal(base + ic) * hit.uv.y), (float3x3)model));
		if (dot(n, ng) < 0.0) n = -n;
		float3 v = -d;
		// A shading normal facing away from the eye shades as the triangle does.
		if (dot(n, v) <= 0.0) n = ng;

		float3 albedo = items[hit.item].color.rgb;
		float2 surf = items[hit.item].surface.xy;
		if ((flags & (ITEM_PAINT | ITEM_GROUPS | ITEM_SLOTS)) != 0u) {
			// The group from the corner the triangle is drawn from, as mesh.vert.slang takes it.
			uint group = vertex_paint(base + ia).y & 0xFFFFu;
			if ((flags & ITEM_SLOTS) != 0u) {
				for (uint k = 1u; k < 16u; k++) {
					if (items[hit.item].slot_group[k >> 2][k & 3u] == group) {
						albedo = items[hit.item].slot_color[k].rgb;
						surf = items[hit.item].slot_surface[k].xy;
					}
				}
			}
			if ((flags & ITEM_PAINT) != 0u) {
				float4 c0 = unpackUnorm4x8ToFloat(vertex_paint(base + ia).x);
				float4 c1 = unpackUnorm4x8ToFloat(vertex_paint(base + ib).x);
				float4 c2 = unpackUnorm4x8ToFloat(vertex_paint(base + ic).x);
				float4 paint = float4(srgb_decode(c0.rgb), c0.a) * w0 + float4(srgb_decode(c1.rgb), c1.a) * hit.uv.x + float4(srgb_decode(c2.rgb), c2.a) * hit.uv.y;
				albedo = lerp(albedo, paint.rgb, paint.a);
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
			uint slot = tex.w & 15u, view = (tex.w >> 4) & 15u, maps = tex.w >> 8;
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
			if ((view == 1u || view == 2u) && (maps & 4u) != 0u) {
				float3 tn = map_at(slot, 2u, uv, lod).xyz * 2.0 - 1.0;
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
			if (view == 3u) albedo *= uv_checker(uv);
		}
		if (bounce == 0) {
			guide_a = float4(albedo, 1.0);
			guide_n = float4(n, hit.t);
		}
		Surface s;
		float metallic = clamp(surf.x, 0.0, 1.0);
		s.diffuse = albedo * (1.0 - metallic);
		s.f0 = lerp(float3(0.04), albedo, metallic);
		s.a = max(surf.y * surf.y, 1e-3);

		radiance += weight * direct_light(s, p, ng, n, v);

		float3 l;
		if (!bsdf_sample(s, n, v, l) || dot(l, ng) <= 0.0) break;
		float3 f = bsdf_eval(s, n, v, l, pdf_bsdf);
		if (pdf_bsdf <= 0.0) break;
		weight *= f / pdf_bsdf;
		o = offset_ray(p, ng);
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
	float4 sum = first ? float4(0.0) : prev.Load(int3(px, 0));
	next[px] = sum + float4(radiance, covered);
	if (lens) {
		// Running means over the samples whose ray met the scene, the share that did in
		// the colour's a, so the colour divided out is the colour the blurred light has.
		float4 prev_a = first ? float4(0.0) : prev_albedo.Load(int3(px, 0));
		float4 prev_n = first ? float4(0.0) : prev_normal.Load(int3(px, 0));
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
