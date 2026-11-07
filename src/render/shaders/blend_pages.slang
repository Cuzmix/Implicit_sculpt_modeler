// Smooth blend's offset pages (render.Blend_Pages), read by the vertex stages that place a
// sculpt mesh: an include, never compiled alone. The includer defines
// BLEND_TABLE_BINDING and BLEND_PAGES_BINDING (set 0) and declares a uniform `uint4 blend`
// whose x is 1 while the item's pages are bound (dummies otherwise).
//
// The table holds, per 1024 vertices, the page with their moves; a word with its top bit
// set (BLEND_PAGE_NONE, or a candidate page the projection found no move in) holds none. A
// page holds 1024 entries: the offset in xyz (float bits), and in w the blended surface's
// normal (two 12-bit octahedral halves, low first), how much of the blend acts there
// (4 bits, 0 none to 15 all) and which side of the seam the vertex is on (4 bits).

[[vk::binding(BLEND_TABLE_BINDING, 0)]] StructuredBuffer<uint> blend_table;
[[vk::binding(BLEND_PAGES_BINDING, 0)]] StructuredBuffer<uint4> blend_pages;

static const uint BLEND_PAGE_NONE = 0xffffffffu;

// The vertex's entry: zero (no move) without pages or outside every page.
uint4 blend_entry(uint vertex) {
	if (blend.x == 0u) return uint4(0u);
	uint page = blend_table[vertex >> 10u];
	if (page >= 0x80000000u) return uint4(0u);
	return blend_pages[page * 1024u + (vertex & 1023u)];
}

#ifdef BLEND_NORMALS
// Moves the vertex by its entry and turns its normal toward the blended surface's by how
// much of the blend acts there, so a stroke's fresh detail still shades where the blend is
// partial. Needs oct_decode (mesh_io.slang).
void blend_apply(uint vertex, inout float3 position, inout float3 normal) {
	uint4 e = blend_entry(vertex);
	position += asfloat(e.xyz);
	float amount = float((e.w >> 24u) & 15u) / 15.0;
	if (amount <= 0.0) return;
	float2 oct = float2(float(e.w & 0xfffu), float((e.w >> 12u) & 0xfffu)) / 4095.0 * 2.0 - 1.0;
	normal = normalize(lerp(normal, oct_decode(oct), amount));
}
#endif
