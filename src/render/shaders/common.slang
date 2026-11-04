// Small helpers several shaders share: an include, never compiled alone.

// GLSL's mod: the remainder that takes the sign of y, unlike fmod's.
float glsl_mod(float x, float y) {
	return x - y * floor(x / y);
}

// A texture's size in texels at its top level.
int2 texture_size(Sampler2D t) {
	uint w, h, levels;
	t.GetDimensions(0, w, h, levels);
	return int2(w, h);
}

// One texel of a texture at its top level, by its integer position. Every shader reads texels
// through this rather than Sampler2D.Load: slangc's own Metal Load, where it is handed a
// combined texture and sampler that the entry point split into two arguments, takes the
// sampler for the position (texture.read(sampler.xy, sampler.z)), which Metal refuses to
// compile. Its asm here counts the pair as the two operands it always is, so the position is
// operand 2. Vulkan and the web keep Load's own code.
[ForceInline]
float4 load_texel(Sampler2D t, int2 p) {
	__target_switch {
	case metal: __intrinsic_asm "$0.read(uint2($2))";
	default: return t.Load(int3(p, 0));
	}
}
