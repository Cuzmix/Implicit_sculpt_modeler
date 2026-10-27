#version 450
// SDL_GPU SPIR-V conventions: fragment uniform buffers live in set 3.
layout(set = 3, binding = 0) uniform Clear_Uniforms {
	vec4 top;    // along the top edge
	vec4 bottom; // along the bottom edge; equal to top for one flat colour
	vec4 extent; // x: the target's height in pixels
};

layout(location = 0) out vec4 out_color;

// A 4x4 ordered dither: the same offset at the same pixel every frame, so a partial
// redraw matches the full one bit for bit.
const float BAYER[16] = float[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);

void main() {
	if (top == bottom) {
		out_color = top;
		return;
	}
	// The pixel's row, from 0 at the top (SDL_GPU's framebuffer origin) to 1 at the bottom.
	float t = clamp(gl_FragCoord.y / extent.x, 0.0, 1.0);
	// Under half an 8-bit step either way, so a gentle gradient shows no bands.
	ivec2 p = ivec2(gl_FragCoord.xy) & 3;
	float dither = ((BAYER[p.y * 4 + p.x] + 0.5) / 16.0 - 0.5) / 255.0;
	out_color = vec4(mix(top.rgb, bottom.rgb, t) + dither, mix(top.a, bottom.a, t));
}
