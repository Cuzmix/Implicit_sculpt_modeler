// slangc: -fp-mode precise
// Smooth blend's projection on the GPU: geom.blend_project's project_vertex step for step
// (src/geom/blend.odin, its constants copied below), for the vertices of one instance's
// pages. Each workgroup takes a quarter of a page (1024 vertices); every thread writes its
// vertex's entry, zero where nothing moves, so the pages need no clearing and their layout
// is the host's. The first line keeps every multiply and add unfused, as the CPU's.
//
// SDL_GPU's SPIR-V layout for compute: set 0 holds the read-only storage buffers, set 1
// the read-write ones, set 2 the uniform buffers.

// The instance's mesh positions, three floats a vertex.
[[vk::binding(0, 0)]] StructuredBuffer<float> positions;
// Per slot of the pages, the page (vertex >> 10) it holds.
[[vk::binding(1, 0)]] StructuredBuffer<uint> page_list;
// Per field: its spacing (float bits), its table's first entry, its table's mask (the top
// bit set when the field holds painted weights) and its first slot among every field's.
[[vk::binding(2, 0)]] StructuredBuffer<uint4> fields;
// Every field's hash table (geom.Blend_Field.table and .slots): the key's low and high
// words, the slot (or anything for a free entry, whose key is all ones), unused.
[[vk::binding(3, 0)]] StructuredBuffer<uint4> brick_table;
// Every field's samples, 729 a slot, x fastest; and their weights, four bytes a word.
[[vk::binding(4, 0)]] StructuredBuffer<float> brick_values;
[[vk::binding(5, 0)]] StructuredBuffer<uint> brick_weights;
// Per term (0 the instance itself, then its group's others): the rows of the transform
// into the term's space, then x the factor back to this space, y the term's mean edge in
// this space, z the term's id (float bits), w the term's field (float bits).
[[vk::binding(6, 0)]] StructuredBuffer<float4> terms;
[[vk::binding(0, 1)]] RWStructuredBuffer<uint4> pages;

[[vk::binding(0, 2)]] cbuffer Blend_Params {
	uint vertex_count;
	uint slot_count;
	uint term_count;
	uint groups_x; // the dispatch's width, since many pages need a second dimension
	float reach;   // the largest radius the instance is joined at
	float self_edge;
	uint _pad0;
	uint _pad1;
	// Per pair of terms (TERMS_MAX x TERMS_MAX, row-major, two pairs a vector): the joining
	// pair's radius in this space and its fullness, zero when the two are not joined. In
	// the uniforms, so the kernel binds the eight storage buffers WebGPU allows a stage.
	float4 pair_table[32];
};

static const uint TERMS_MAX = 8;
static const uint BRICK = 8;
static const uint SIDE = 9;
static const uint SAMPLES = 729;
static const uint KEY_OFFSET = 1048576u; // 1 << 20
static const uint KEY_MASK = 2097151u;   // (1 << 21) - 1
static const float FULL_COS = -0.3;
static const float NONE_COS = -0.8;
static const uint STEPS = 6u;
static const float STEP_MAX = 0.5;
static const float TOLERANCE = 1e-4;
static const float HIDDEN_DEPTH = 0.5;
static const float SEAM_CUT = 0.05;
static const float SEAM_LIFT = 0.002;
static const float SEAM_SAG = 0.75;
static const float SEAM_BAND = 0.5;
static const float FAR = 3.4028235e38;

float2 term_pair(uint a, uint b) {
	uint i = a * TERMS_MAX + b;
	float4 two = pair_table[i >> 1u];
	return (i & 1u) == 0u ? two.xy : two.zw;
}

// Odin's math.lerp, a*(1-t) + b*t, so the CPU's and the GPU's sums are made alike.
float mixf(float a, float b, float t) { return a * (1.0 - t) + b * t; }
float3 mix3(float3 a, float3 b, float t) { return a * (1.0 - t) + b * t; }

float3 normalize0(float3 v) {
	float l = length(v);
	return l > 0.0 ? v / l : float3(0.0);
}

// geom.blend_key_hash.
uint key_hash(uint x, uint y, uint z) {
	uint h = (x * 73856093u) ^ (y * 19349663u) ^ (z * 83492791u);
	h ^= h >> 16;
	h *= 0x7feb352du;
	h ^= h >> 15;
	h *= 0x846ca68bu;
	h ^= h >> 16;
	return h;
}

// Field f's first sample of brick b, or -1 when it holds no such brick.
int brick_base(uint f, int3 b) {
	if (abs(b.x) >= int(KEY_OFFSET) - 1 || abs(b.y) >= int(KEY_OFFSET) - 1 || abs(b.z) >= int(KEY_OFFSET) - 1) return -1;
	uint4 fd = fields[f];
	uint x = uint(b.x + int(KEY_OFFSET)) & KEY_MASK;
	uint y = uint(b.y + int(KEY_OFFSET)) & KEY_MASK;
	uint z = uint(b.z + int(KEY_OFFSET)) & KEY_MASK;
	uint lo = x | (y << 21u);
	uint hi = (y >> 11u) | (z << 10u);
	uint mask = fd.z & 0x7fffffffu;
	uint i = key_hash(x, y, z) & mask;
	for (uint n = 0u; n <= mask; n++) {
		uint4 e = brick_table[fd.y + i];
		if (e.x == lo && e.y == hi) return int((fd.w + e.z) * SAMPLES);
		if (e.x == 0xffffffffu && e.y == 0xffffffffu) return -1;
		i = (i + 1u) & mask;
	}
	return -1;
}

struct Cell {
	int base;  // the brick's first sample, -1 for none
	int3 l;    // the cell's lower corner in the brick
	float3 t;  // the point's place in the cell
};

Cell locate(uint f, float3 p) {
	Cell c;
	float h = asfloat(fields[f].x);
	float3 q = p / h;
	float3 cell = floor(q);
	int3 b = int3(floor(cell / float(BRICK)));
	c.base = brick_base(f, b);
	c.l = int3(cell) - b * int(BRICK);
	c.t = q - cell;
	return c;
}

uint sample_index(int3 at) { return uint((at.z * int(SIDE) + at.y) * int(SIDE) + at.x); }

float sample_at(int base, int3 l, uint k) {
	return brick_values[uint(base) + sample_index(l + int3(int(k & 1u), int((k >> 1u) & 1u), int((k >> 2u) & 1u)))];
}

float weight_at(int base, int3 l, uint k) {
	uint i = uint(base) + sample_index(l + int3(int(k & 1u), int((k >> 1u) & 1u), int((k >> 2u) & 1u)));
	return float((brick_weights[i >> 2u] >> (8u * (i & 3u))) & 255u);
}

// geom.blend_field_at: the distance, the trilinear's own gradient and the weight.
bool field_at(uint f, float3 p, out float d, out float3 g, out float w) {
	d = 0.0;
	g = float3(0.0);
	w = 0.0;
	Cell c = locate(f, p);
	if (c.base < 0) return false;
	float h = asfloat(fields[f].x);
	bool painted = (fields[f].z & 0x80000000u) != 0u;
	float v[8];
	float wc[8];
	for (uint k = 0u; k < 8u; k++) {
		v[k] = sample_at(c.base, c.l, k);
		wc[k] = painted ? weight_at(c.base, c.l, k) : 0.0;
	}
	float3 t = c.t;
	float x0 = mixf(v[0], v[1], t.x);
	float x1 = mixf(v[2], v[3], t.x);
	float x2 = mixf(v[4], v[5], t.x);
	float x3 = mixf(v[6], v[7], t.x);
	float y0 = mixf(x0, x1, t.y);
	float y1 = mixf(x2, x3, t.y);
	d = mixf(y0, y1, t.z);
	float gx = mixf(mixf(v[1] - v[0], v[3] - v[2], t.y), mixf(v[5] - v[4], v[7] - v[6], t.y), t.z);
	float gy = mixf(mixf(v[2] - v[0], v[3] - v[1], t.x), mixf(v[6] - v[4], v[7] - v[5], t.x), t.z);
	g = float3(gx, gy, y1 - y0) / h;
	float wx0 = mixf(wc[0], wc[1], t.x);
	float wx1 = mixf(wc[2], wc[3], t.x);
	float wx2 = mixf(wc[4], wc[5], t.x);
	float wx3 = mixf(wc[6], wc[7], t.x);
	w = 1.0 - mixf(mixf(wx0, wx1, t.y), mixf(wx2, wx3, t.y), t.z) / 255.0;
	return true;
}

// geom.blend_field_normal: the trilinear mix of the corners' central differences.
bool field_normal(uint f, float3 p, out float3 g) {
	g = float3(0.0);
	Cell c = locate(f, p);
	if (c.base < 0) return false;
	float h = asfloat(fields[f].x);
	float3 gc[8];
	for (uint k = 0u; k < 8u; k++) {
		int3 at = c.l + int3(int(k & 1u), int((k >> 1u) & 1u), int((k >> 2u) & 1u));
		for (uint a = 0u; a < 3u; a++) {
			int3 lo = at;
			int3 hi = at;
			if (lo[a] > 0) lo[a] -= 1;
			if (hi[a] < int(SIDE) - 1) hi[a] += 1;
			gc[k][a] = (brick_values[uint(c.base) + sample_index(hi)] - brick_values[uint(c.base) + sample_index(lo)]) / (float(hi[a] - lo[a]) * h);
		}
	}
	float3 t = c.t;
	float3 x0 = mix3(gc[0], gc[1], t.x);
	float3 x1 = mix3(gc[2], gc[3], t.x);
	float3 x2 = mix3(gc[4], gc[5], t.x);
	float3 x3 = mix3(gc[6], gc[7], t.x);
	g = mix3(mix3(x0, x1, t.y), mix3(x2, x3, t.y), t.z);
	return true;
}

// Term j's field at x of this instance's space, in this space's units.
bool term_at(uint j, float3 x, bool smooth, out float d, out float3 g, out float w) {
	float4 r0 = terms[4u * j];
	float4 r1 = terms[4u * j + 1u];
	float4 r2 = terms[4u * j + 2u];
	float4 info = terms[4u * j + 3u];
	uint f = asuint(info.w);
	float3 p = float3(dot(r0.xyz, x) + r0.w, dot(r1.xyz, x) + r1.w, dot(r2.xyz, x) + r2.w);
	if (!field_at(f, p, d, g, w)) return false;
	if (smooth) {
		float3 n;
		if (field_normal(f, p, n)) g = n;
	}
	d *= info.x;
	g = (r0.xyz * g.x + r1.xyz * g.y + r2.xyz * g.z) * info.x;
	return true;
}

// geom.blend_radius_at.
float radius_at(float radius, float c, float w) {
	float t = clamp((c - NONE_COS) / (FULL_COS - NONE_COS), 0.0, 1.0);
	return radius * w * t * t * (3.0 - 2.0 * t);
}

struct Eval {
	bool ok;
	float g;
	float3 grad;
	float amount;
	float own;
	uint rival;
	float rival_edge;
};

// geom's evaluate: the fold of every term that covers x, sorted by value (ties by id).
Eval evaluate(float3 x, bool smooth) {
	Eval e;
	e.ok = false;
	e.g = 0.0;
	e.grad = float3(0.0);
	e.amount = 0.0;
	e.own = 1.0;
	e.rival = 0xffffffffu;
	e.rival_edge = 0.0;
	float d[TERMS_MAX];
	float3 g[TERMS_MAX];
	float w[TERMS_MAX];
	uint id[TERMS_MAX];
	uint term[TERMS_MAX];
	for (uint z = 0u; z < TERMS_MAX; z++) {
		d[z] = 0.0;
		g[z] = float3(0.0);
		w[z] = 0.0;
		id[z] = 0u;
		term[z] = 0u;
	}
	uint count = 0u;
	float self_d = 0.0;
	float others = FAR;
	for (uint j = 0u; j < term_count; j++) {
		float td;
		float3 tg;
		float tw;
		if (!term_at(j, x, smooth, td, tg, tw)) {
			if (j == 0u) return e;
			continue;
		}
		uint tid = asuint(terms[4u * j + 3u].z);
		if (j == 0u) {
			self_d = td;
		} else if (td < others || (td == others && tid < e.rival)) {
			others = td;
			e.rival = tid;
			e.rival_edge = terms[4u * j + 3u].y;
		}
		// Insertion by value, ties by id: geom's sort gives the same order.
		uint at = count;
		while (at > 0u && (td < d[at - 1u] || (td == d[at - 1u] && tid < id[at - 1u]))) {
			d[at] = d[at - 1u];
			g[at] = g[at - 1u];
			w[at] = w[at - 1u];
			id[at] = id[at - 1u];
			term[at] = term[at - 1u];
			at--;
		}
		d[at] = td;
		g[at] = tg;
		w[at] = tw;
		id[at] = tid;
		term[at] = j;
		count++;
	}
	float acc = d[0];
	float3 grad = g[0];
	float amount = 0.0;
	for (uint j = 1u; j < count; j++) {
		float radius = 0.0;
		float strength = 0.0;
		float pw = 0.0;
		for (uint i = 0u; i < j; i++) {
			float2 p = term_pair(term[j], term[i]);
			if (p.x > radius) {
				radius = p.x;
				strength = p.y;
				pw = w[j] * w[i];
			}
		}
		float k = radius_at(radius, dot(normalize0(grad), normalize0(g[j])), pw);
		// geom.blend_union.
		float a = acc;
		float b = d[j];
		if (k <= 0.0) {
			if (a <= b) {
				acc = a;
			} else {
				acc = b;
				grad = g[j];
			}
		} else {
			float h = max(k - abs(a - b), 0.0) / k;
			acc = min(a, b) - strength * h * h * k * 0.25;
			if (a <= b) {
				grad = grad * (1.0 - strength * h * 0.5) + g[j] * (strength * h * 0.5);
			} else {
				grad = g[j] * (1.0 - strength * h * 0.5) + grad * (strength * h * 0.5);
			}
			amount = max(amount, strength * h);
		}
	}
	e.ok = true;
	e.g = acc;
	e.grad = grad;
	e.amount = amount;
	if (others < FAR) e.own = clamp((others - self_d) / reach, -1.0, 1.0);
	return e;
}

// render.blend_entry_pack.
uint4 entry(float3 offset, float3 normal, float amount, float own) {
	float3 n = normalize0(normal);
	float l = abs(n.x) + abs(n.y) + abs(n.z);
	float2 e = float2(0.0);
	if (l > 0.0) {
		e = n.xy / l;
		if (n.z < 0.0) {
			float sx = e.x >= 0.0 ? 1.0 : -1.0;
			float sy = e.y >= 0.0 ? 1.0 : -1.0;
			e = float2((1.0 - abs(e.y)) * sx, (1.0 - abs(e.x)) * sy);
		}
	}
	uint qx = uint(round(clamp(e.x * 0.5 + 0.5, 0.0, 1.0) * 4095.0));
	uint qy = uint(round(clamp(e.y * 0.5 + 0.5, 0.0, 1.0) * 4095.0));
	uint a = uint(round(clamp(amount, 0.0, 1.0) * 15.0));
	uint o = uint(round(clamp(own * 0.5 + 0.5, 0.0, 1.0) * 15.0));
	return uint4(asuint(offset.x), asuint(offset.y), asuint(offset.z), qx | (qy << 12u) | (a << 24u) | (o << 28u));
}

// geom's project_vertex, for vertex v: its entry, zero where it stays.
uint4 project(uint v) {
	uint4 none = uint4(0u);
	float3 x0 = float3(positions[3u * v], positions[3u * v + 1u], positions[3u * v + 2u]);
	float a0;
	float3 ga;
	float wa;
	if (!term_at(0u, x0, false, a0, ga, wa)) return none;
	bool near = false;
	for (uint j = 1u; j < term_count; j++) {
		float radius = term_pair(0u, j).x; // the pair of term j and the instance itself (term 0)
		if (radius <= 0.0) continue;
		float b;
		float3 gb;
		float wb;
		if (term_at(j, x0, false, b, gb, wb) && b > -HIDDEN_DEPTH * radius && b < radius) near = true;
	}
	if (!near) return none;
	Eval e0 = evaluate(x0, false);
	if (e0.amount <= 0.0 && e0.g < a0) return none;
	float target = a0 * (1.0 - e0.amount);
	float3 x = x0;
	float best = abs(e0.g - target);
	float3 best_x = x0;
	uint steps = 0u;
	bool converged = best < TOLERANCE * reach;
	while (!converged && steps < STEPS) {
		Eval e = evaluate(x, false);
		if (!e.ok) break;
		steps++;
		float r = e.g - target;
		if (abs(r) < best) {
			best = abs(r);
			best_x = x;
		}
		if (abs(r) < TOLERANCE * reach) {
			converged = true;
			break;
		}
		float gg = dot(e.grad, e.grad);
		if (gg < 1e-8) break;
		float3 step = e.grad * (r / gg);
		float l = length(step);
		if (l > STEP_MAX * reach) step *= STEP_MAX * reach / l;
		x -= step;
	}
	if (converged) {
		best_x = x;
	} else {
		Eval e = evaluate(x, false);
		if (e.ok && abs(e.g - target) < best) best_x = x;
	}
	if (all(best_x == x0)) return none;
	Eval f = evaluate(best_x, true);
	float3 n = normalize0(f.grad);
	float3 offset = best_x - x0;
	if (asuint(terms[3u].z) < f.rival) {
		if (f.own < -SEAM_CUT) return none;
		float edge = max(self_edge, f.rival_edge);
		float lift = max(SEAM_LIFT * reach, SEAM_SAG * edge * edge / reach);
		offset += n * (lift * clamp(1.0 - f.own / SEAM_BAND, 0.0, 1.0));
	}
	return entry(offset, n, f.amount, f.own);
}

[numthreads(256, 1, 1)]
void main(uint3 group_id : SV_GroupID, uint3 local_id : SV_GroupThreadID) {
	uint g = group_id.y * groups_x + group_id.x;
	uint slot = g >> 2u;
	if (slot >= slot_count) return;
	uint k = (g & 3u) * 256u + local_id.x;
	uint v = page_list[slot] * 1024u + k;
	uint4 result = uint4(0u);
	if (v < vertex_count) result = project(v);
	pages[slot * 1024u + k] = result;
}
