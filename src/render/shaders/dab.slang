// A stroke's dabs on the GPU (render/sculpt_gpu.odin, README "Sculpt on the GPU"): what
// the five dab kernels share. Each kernel does for one dab what sculpt.dab_once's jobs do
// on the CPU (job_area, displace, job_smooth_targets, job_smooth_apply), over the dab's
// slabs: up to SLAB owned vertices of one hit node each, cut from the node ranges the
// sculptor handed over, a workgroup a slab and a thread a vertex. The dabs of a frame run
// one after another in the order they were laid, each reading the positions the one before
// it wrote, as the CPU's do.
//
// A dab record is eight float4s, as render.Sculpt_Dab lays it out (the sculptor's
// Gpu_Dab translated by the app): the kinds and flags are the DAB_* constants below.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers. The kernels write the positions in place
// (set 1, binding 0); the dab records, slabs and normals are read-only.

static const uint SLAB = 256;

static const uint DAB_DRAW = 0;
static const uint DAB_INFLATE = 1;
static const uint DAB_CLAY = 2;
static const uint DAB_FLATTEN = 3;
static const uint DAB_PINCH = 4;
static const uint DAB_CREASE = 5;
static const uint DAB_SMOOTH = 6;

static const uint FLAG_RELAX = 1;   // Smooth: only across the surface
static const uint FLAG_VALLEYS = 2; // Smooth: only vertices below their neighbours' mean
static const uint FLAG_PEAKS = 4;   // Smooth: only vertices above it
static const uint FLAG_TILT = 8;    // the area normal is turned by the tilt rows
static const uint FLAG_ONCE = 16;   // Draw, Inflate: Accumulate off, the stroke's heights cap the move

// sculpt's strengths, with their reasons there (brush.odin).
static const float PLANE_RATE = 0.5;
static const float PINCH_RATE = 0.25;
static const float CREASE_PINCH = 0.2;

struct Dab {
	float4 center_r2;     // the centre, and the squared reach
	float4 view_inv_r2;   // Projected: the view direction over the radius (zero for Sphere); 1 / radius²
	float4 facing_amount; // front faces only: the way toward the viewer (zero for off); the signed amount
	float4 tilt0;         // the tilt's rows (FLAG_TILT), .w the strength
	float4 tilt1;         // .w 1 / (the sample radius)²
	float4 tilt2;         // .w Clay's plane offset along the normal (0 for the rest)
	float4 misc;          // Flatten's plane_short above and below, the radius, 0
	uint4 slabs;          // first slab, slab count, kind, flags
};

[[vk::binding(0, 0)]] StructuredBuffer<uint> indices;
[[vk::binding(1, 0)]] StructuredBuffer<uint> offsets; // vertex -> first slot in tris
[[vk::binding(2, 0)]] StructuredBuffer<uint> tris;
[[vk::binding(3, 0)]] StructuredBuffer<uint2> slabs;  // first vertex, count
[[vk::binding(4, 0)]] StructuredBuffer<Dab> dabs;
[[vk::binding(5, 0)]] StructuredBuffer<uint> normals; // packed, mask nibbles low (node_normals.comp.slang)
[[vk::binding(0, 1)]] RWStructuredBuffer<float> positions; // 3 floats a vertex
[[vk::binding(1, 1)]] RWStructuredBuffer<float4> partials; // a slab's area sums: normal.xyz and weight, then the centre
[[vk::binding(2, 1)]] RWStructuredBuffer<float4> areas;    // a dab's area: the normal, then a point on the plane
[[vk::binding(3, 1)]] RWStructuredBuffer<float4> scratch;  // Smooth's targets, a float4 a slot of the dab's slabs
// A vertex's stroke height (sculpt.Layer_Height): the stroke number it holds for, and
// how far that stroke has raised it, as float bits; a vertex an older stroke wrote
// stands at zero.
[[vk::binding(4, 1)]] RWStructuredBuffer<uint2> heights;

[[vk::binding(0, 2)]] cbuffer Params {
	uint dab;      // the record this dispatch works on
	uint groups_x; // the dispatch's width, since many slabs need a second dimension
	float rate;    // Smooth: this pass's share of the step toward the neighbours
	uint stroke;   // the stroke's number for the heights (FLAG_ONCE)
};

float3 at(uint v) {
	return float3(positions[3 * v], positions[3 * v + 1], positions[3 * v + 2]);
}

void put(uint v, float3 p) {
	positions[3 * v] = p.x;
	positions[3 * v + 1] = p.y;
	positions[3 * v + 2] = p.z;
}

// render.unpack_normal: geom.oct_decode of the packed value's top twelve bits, normalised.
float3 normal_at(uint v) {
	uint e = normals[v];
	int x = int(e << 16) >> 16;
	int y = int(e) >> 16;
	float2 p = float2(max(float(x & ~15) / 32767.0, -1.0), max(float(y & ~15) / 32767.0, -1.0));
	float3 n = float3(p.x, p.y, 1.0 - abs(p.x) - abs(p.y));
	if (n.z < 0.0) {
		float sx = n.x >= 0.0 ? 1.0 : -1.0;
		float sy = n.y >= 0.0 ? 1.0 : -1.0;
		n.x = (1.0 - abs(p.y)) * sx;
		n.y = (1.0 - abs(p.x)) * sy;
	}
	float l = length(n);
	return l > 0.0 ? n / l : float3(0.0);
}

float3 normalize0(float3 v) {
	float l = length(v);
	return l > 0.0 ? v / l : float3(0.0);
}

// sculpt.falloff: (1 - x²)² over the squared distance in radii.
float falloff(float x2) {
	if (x2 >= 1.0) return 0.0;
	float t = 1.0 - x2;
	return t * t;
}

// sculpt.dab_weight without an alpha: the round falloff, or Projected's across the view line.
float dab_weight(Dab d, float3 delta, float d2) {
	float x2 = d2 * d.view_inv_r2.w;
	float3 view = d.view_inv_r2.xyz;
	if (any(view != float3(0.0))) {
		float h = dot(delta, view);
		if (h * h >= 1.0) return 0.0;
		x2 -= h * h;
	}
	return falloff(x2);
}

// sculpt.facing_weight: 1 with front faces only off or the vertex facing the viewer, 0
// facing away, a short ramp between.
float facing_weight(Dab d, float3 n) {
	float3 facing = d.facing_amount.xyz;
	if (all(facing == float3(0.0))) return 1.0;
	return clamp(dot(n, facing) * 5.0 + 0.5, 0.0, 1.0);
}

// The slab this workgroup takes and the vertex this thread takes; false past the end.
bool slab_vertex(Dab d, uint3 group_id, uint3 local_id, out uint g, out uint v) {
	g = group_id.y * groups_x + group_id.x;
	v = 0;
	if (g >= d.slabs.y) return false;
	uint2 slab = slabs[d.slabs.x + g];
	if (local_id.x >= slab.y) return false;
	v = slab.x + local_id.x;
	return true;
}
