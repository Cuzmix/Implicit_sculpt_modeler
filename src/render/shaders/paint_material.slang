// Painted roughness and metal (sculpt.Material_Paint, render.Mesh_Buffers.paint_material):
// roughness, its coverage, metal and its coverage, a byte each, roughness lowest. An
// include of mesh_io.slang and render_trace.slang, never compiled alone.
float4 paint_material(uint word) {
	return unpackUnorm4x8ToFloat(word);
}

// The item's metal and roughness (`surf`: x metal, y roughness) under the paint's `m` (as
// paint_material gives it, mixed between the corners), each as far as its coverage
// reaches. Roughness keeps the physically based path's floor.
float2 paint_surface(float2 surf, float4 m) {
	return float2(lerp(surf.x, m.z, m.w), max(lerp(surf.y, m.x, m.y), 0.04));
}
