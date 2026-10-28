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
