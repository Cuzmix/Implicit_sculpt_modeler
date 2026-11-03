// Where a point of a triangle lies in its detail skin's grid (sculpt/skin.odin): an
// include, never compiled alone, shared by the viewport's skinned stages (mesh_io.slang) and
// render mode (render_trace.slang), so both read the same samples.

// The detail skin's sample at grid place (i, j) of a triangle, i toward its second corner
// and j toward its third in the mesh's order, whose corners' vertices are `v` and edges
// `e`. The layout is sculpt.skin_sample's.
uint skin_index(uint i, uint j, uint S, uint V, uint E, uint tri, uint3 v, uint3 e) {
	if (i == 0u && j == 0u) return v.x;
	if (i == S) return v.y;
	if (j == S) return v.z;
	uint ref, k;
	if (j == 0u) { ref = e.x; k = i; }
	else if (i + j == S) { ref = e.y; k = j; }
	else if (i == 0u) { ref = e.z; k = S - j; }
	else {
		uint row = (j - 1u) * (S - 2u) - (j - 1u) * (j - 2u) / 2u;
		return V + E * (S - 1u) + tri * ((S - 1u) * (S - 2u) / 2u) + row + (i - 1u);
	}
	uint along = (ref & 1u) == 0u ? k : S - k;
	return V + (ref >> 1u) * (S - 1u) + (along - 1u);
}

// The three samples of the small triangle of the skin's grid that the point at barycentric
// `gb` of triangle `tri` lies in, and their weights there, from the triangle's corners as
// drawn (`gv`, their vertices) and its record `rec` (edges, and in w's low bits which corner
// as drawn is its first in the mesh: polygroups start a triangle at its lead corner).
void skin_grid_corners(uint S, uint V, uint E, uint tri, uint4 rec, float3 gb, uint3 gv, out uint3 x, out float3 w) {
	// From the corners as drawn back to the mesh's order: drawn corner k is the mesh's
	// corner (k + lead) mod 3.
	uint lead = rec.w & 3u;
	float3 b;
	uint3 v;
	if (lead == 1u) { b = gb.zxy; v = gv.zxy; }
	else if (lead == 2u) { b = gb.yzx; v = gv.yzx; }
	else { b = gb; v = gv; }
	float fs = float(S);
	float u = clamp(b.y, 0.0, 1.0) * fs, t = clamp(b.z, 0.0, 1.0) * fs;
	uint i0 = min(uint(u), S - 1u), j0 = min(uint(t), S - 1u);
	if (i0 + j0 > S - 1u) {
		// Rounding past the triangle's far edge: back onto the last row of small triangles.
		if (u > t) i0 = S - 1u - j0; else j0 = S - 1u - i0;
	}
	float fu = u - float(i0), fw = t - float(j0);
	if (fu + fw <= 1.0 || i0 + j0 + 1u > S - 1u) {
		x = uint3(skin_index(i0, j0, S, V, E, tri, v, rec.xyz), skin_index(i0 + 1u, j0, S, V, E, tri, v, rec.xyz), skin_index(i0, j0 + 1u, S, V, E, tri, v, rec.xyz));
		w = float3(1.0 - fu - fw, fu, fw);
	} else {
		x = uint3(skin_index(i0 + 1u, j0 + 1u, S, V, E, tri, v, rec.xyz), skin_index(i0, j0 + 1u, S, V, E, tri, v, rec.xyz), skin_index(i0 + 1u, j0, S, V, E, tri, v, rec.xyz));
		w = float3(fu + fw - 1.0, 1.0 - fu, 1.0 - fw);
	}
}
