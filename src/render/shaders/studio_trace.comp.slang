// One sample of the traced studio render (render/trace.odin) for one item: from every
// viewport pixel on a surface, a ray toward this sample's light, cast against the
// item's own triangles through its two-level tree (a tree over its chunks, then each
// chunk's tree over its triangles). A pixel whose ray hits anything gets 0 in `visible`,
// which starts each sample at 1; every item's dispatch only ever stores 0, so the
// result is the same in any order, and a pixel is lit only when no item blocks it.
// Ambient samples are cosine-weighted about the surface's normal; light samples aim at
// the light the sample picked, jittered over its disc: a sun's around its direction, a
// point or spot light's on its sphere, facing the pixel, with the ray stopping there. Both take this sample's point of the R2
// sequence turned by a hash of the pixel (Cranley-Patterson rotation), so neighbouring
// pixels try different directions and the image converges as noise, not bands; the
// same pixel and sample always cast the same ray, in every item's dispatch.
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

[[vk::binding(0, 0)]] Sampler2D view_depth;
[[vk::binding(1, 0)]] StructuredBuffer<float> positions; // 3 floats a vertex
[[vk::binding(2, 0)]] StructuredBuffer<uint> indices;
// Every chunk's tree, one after another; a leaf's `first` is into its chunk's order.
[[vk::binding(3, 0)]] StructuredBuffer<Node> nodes;
[[vk::binding(4, 0)]] StructuredBuffer<uint> order; // two 16-bit offsets a word
[[vk::binding(5, 0)]] StructuredBuffer<uint4> chunks; // node_off, order_off, first_tri, node_count
// The tree over the shown chunks; a leaf's `first` is a chunk.
[[vk::binding(6, 0)]] StructuredBuffer<Node> tlas;
[[vk::binding(0, 1)]] [[vk::image_format("r32f")]] RWTexture2D<float4> visible;

[[vk::binding(0, 2)]] cbuffer Trace_Uniforms {
	float4x4 inv_view_proj; // viewport clip space back to the world
	float4x4 to_mesh;       // the world into the item's mesh space (the inverse of its model)
	float4 key_base;      // xyz: toward a sun (world, unit); w: 1 for a light sample
	float4 key_side;      // xyz: across a sun's disc; w: the disc's radius
	float4 key_up;        // xyz: the disc's other axis
	float4 params;        // xy: this sample's point of the R2 sequence; z: the least offset (world); w: 1 for a point or spot light
	float4 sphere;        // xyz: a point or spot light's place (world); w: its radius
};

// geom.CHUNK_BVH_STACK for each level: the chunk tree's entries stay below the one
// chunk being walked.
static const int STACK = 2 * 57;
static const uint IN_CHUNK = 0x80000000u;
static const float PI = 3.14159265;

float3 world_at(float2 frag, float depth, float2 size) {
	float2 uv = frag / size;
	float4 w = mul(float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0), inv_view_proj);
	return w.xyz / w.w;
}

float3 vertex(uint v) {
	return float3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
}

// The slab test; a box refit empty (lo above hi) is never entered.
bool enters(Node n, float3 o, float3 inv, float tmax) {
	if (n.lo.x > n.hi.x) return false;
	float3 t0 = (n.lo - o) * inv, t1 = (n.hi - o) * inv;
	float3 near = min(t0, t1), far = max(t0, t1);
	return max(max(near.x, near.y), max(near.z, 0.0)) <= min(min(far.x, tmax), min(far.y, far.z));
}

// Möller-Trumbore, any hit in front of the origin and before `tmax`; a triangle with a repeated corner
// (hidden, or an unused slot) never hits, nor one seen exactly edge on.
bool hits(uint tri, float3 o, float3 d, float tmax) {
	uint a = indices[3 * tri], b = indices[3 * tri + 1], c = indices[3 * tri + 2];
	if (a == b || b == c || a == c) return false;
	float3 p0 = vertex(a);
	float3 e1 = vertex(b) - p0, e2 = vertex(c) - p0;
	float3 pv = cross(d, e2);
	float det = dot(e1, pv);
	if (det == 0.0) return false;
	float f = 1.0 / det;
	float3 tv = o - p0;
	float u = dot(tv, pv) * f;
	if (u < 0.0 || u > 1.0) return false;
	float3 qv = cross(tv, e1);
	float v = dot(d, qv) * f;
	if (v < 0.0 || u + v > 1.0) return false;
	float t = dot(e2, qv) * f;
	return t > 0.0 && t < tmax;
}

// Whether anything lies along `d` from `o` before `tmax` times it.
bool occluded(float3 o, float3 d, float tmax) {
	// No component exactly zero, so the slab test never multiplies zero by infinity.
	float3 safe = select(d == float3(0.0), float3(1e-20), d);
	float3 inv = 1.0 / safe;
	uint stack[STACK];
	int top = 1;
	stack[0] = 0u;
	uint4 ch = uint4(0u);
	while (top > 0) {
		uint e = stack[--top];
		if ((e & IN_CHUNK) == 0u) {
			Node n = tlas[e];
			if (!enters(n, o, inv, tmax)) continue;
			if (n.count == 0u) {
				stack[top++] = n.first;
				stack[top++] = n.first + 1u;
			} else {
				// Everything pushed from here on is this chunk's, and is walked before
				// the chunk tree's next entry comes off the stack.
				ch = chunks[n.first];
				stack[top++] = IN_CHUNK;
			}
			continue;
		}
		Node n = nodes[ch.x + (e & ~IN_CHUNK)];
		if (!enters(n, o, inv, tmax)) continue;
		if (n.count == 0u) {
			stack[top++] = IN_CHUNK | n.first;
			stack[top++] = IN_CHUNK | (n.first + 1u);
			continue;
		}
		for (uint j = n.first; j < n.first + n.count; j++) {
			uint at = ch.y + j;
			uint word = order[at >> 1];
			uint tri = ch.z + ((at & 1u) == 0u ? (word & 0xFFFFu) : (word >> 16));
			if (hits(tri, o, d, tmax)) return true;
		}
	}
	return false;
}

// Two numbers in [0, 1) from the pixel (pcg2d, Jarzynski and Olano 2020).
float2 pixel_hash(uint2 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * 1664525u;
	v.y += v.x * 1664525u;
	v ^= v >> 16u;
	v.x += v.y * 1664525u;
	v.y += v.x * 1664525u;
	v ^= v >> 16u;
	return float2(v >> 8u) / 16777216.0;
}

[numthreads(8, 8, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID, uint3 global_id : SV_DispatchThreadID) {
	float2 size = float2(texture_size(view_depth));
	int2 px = int2(global_id.xy);
	if (px.x >= int(size.x) || px.y >= int(size.y)) return;
	float d = view_depth.Load(int3(px, 0)).r;
	if (d >= 1.0) return;
	float2 frag = float2(px) + 0.5;
	float3 p = world_at(frag, d, size);
	// The surface normal from the depth of the neighbouring pixels, as studio_gather.frag.
	int2 hi = int2(size) - 1;
	float dl = view_depth.Load(int3(clamp(px - int2(1, 0), int2(0), hi), 0)).r;
	float dr = view_depth.Load(int3(clamp(px + int2(1, 0), int2(0), hi), 0)).r;
	float du = view_depth.Load(int3(clamp(px - int2(0, 1), int2(0), hi), 0)).r;
	float dd = view_depth.Load(int3(clamp(px + int2(0, 1), int2(0), hi), 0)).r;
	float3 px_r = abs(dr - d) < abs(d - dl) ? world_at(frag + float2(1, 0), dr, size) - p : p - world_at(frag - float2(1, 0), dl, size);
	float3 px_d = abs(dd - d) < abs(d - du) ? world_at(frag + float2(0, 1), dd, size) - p : p - world_at(frag - float2(0, 1), du, size);
	float3 n = normalize(cross(px_d, px_r));
	float3 toward_eye = normalize(world_at(frag, 0.0, size) - p);
	if (dot(n, toward_eye) < 0.0) n = -n;

	float2 r2 = frac(params.xy + pixel_hash(uint2(px)));
	float3 dir;
	// A sun's ray goes on for ever; a sphere light's stops at the light, at the far end of
	// the unnormalised ray.
	float tmax = asfloat(0x7F800000u);
	if (key_base.w > 0.5 && params.w > 0.5) {
		// The disc through the sphere's centre, square to the pixel, that the sphere
		// fills the same cone of: radius r d / sqrt(d² - r²). A pixel inside the light
		// is lit.
		float3 to = sphere.xyz - p;
		float d2 = dot(to, to), r = sphere.w;
		if (d2 <= r * r) return;
		float3 axis = to * rsqrt(d2);
		float3 side = normalize(cross(axis, abs(axis.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
		float3 up = cross(side, axis);
		float a = 2.0 * PI * r2.y, rr = r * sqrt(d2 / (d2 - r * r)) * sqrt(r2.x);
		dir = to + (side * cos(a) + up * sin(a)) * rr;
		if (dot(n, dir) <= 0.0) return;
		tmax = 1.0;
	} else if (key_base.w > 0.5) {
		float a = 2.0 * PI * r2.y, rr = key_side.w * sqrt(r2.x);
		dir = normalize(key_base.xyz + (key_side.xyz * cos(a) + key_up.xyz * sin(a)) * rr);
		// Facing away: the light never reaches here, which the viewport's shading
		// already shows, so the pixel keeps 1 as the gather's does.
		if (dot(n, dir) <= 0.0) return;
	} else {
		// A frame about the normal (Duff et al. 2017), then a cosine-weighted direction.
		float s = n.z >= 0.0 ? 1.0 : -1.0;
		float a = -1.0 / (s + n.z);
		float b = n.x * n.y * a;
		float3 t = float3(1.0 + s * n.x * n.x * a, s * b, -s * n.x);
		float3 bt = float3(b, s + n.y * n.y * a, -n.y);
		float r = sqrt(r2.x), phi = 2.0 * PI * r2.y;
		dir = normalize(t * (r * cos(phi)) + bt * (r * sin(phi)) + n * sqrt(max(1.0 - r2.x, 0.0)));
	}

	// Off the surface along its normal and toward the eye, so neither the depth buffer's
	// rounding nor the triangles' own curve between pixels shadows the pixel itself: by
	// the least offset, plus twice the pixel's width at this depth, at most a hundred
	// times the least so a pixel seen at a grazing distance cannot leap through a wall.
	float footprint = length(world_at(frag + float2(1, 0), d, size) - p);
	float eps = params.z + min(2.0 * footprint, 100.0 * params.z);
	float3 o = p + (n + toward_eye) * eps;
	// Toward a sphere light the ray is aimed from the offset point, so it still ends on the
	// light. The model is a similarity, so the ray's parameter is the same in mesh space.
	if (tmax == 1.0) dir = p + dir - o;
	float3 om = (mul(float4(o, 1.0), to_mesh)).xyz;
	float3 dm = mul(dir, (float3x3)to_mesh);
	if (occluded(om, dm, tmax)) visible[px] = float4(0.0);
}
