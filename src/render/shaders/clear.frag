#version 450
#extension GL_GOOGLE_include_directive : require
// The viewport's background: one colour, a gradient, or the image environment.
#include "display.glsl"
#include "panorama.glsl"

// SDL_GPU SPIR-V conventions: fragment samplers in set 2, uniform buffers in set 3.
// The prefiltered environment (render/environment.odin), a 1 x 1 black one when none.
layout(set = 2, binding = 0) uniform sampler2D environment_map;
layout(set = 3, binding = 0) uniform Clear_Uniforms {
	vec4 top;    // along the top edge
	vec4 bottom; // along the bottom edge; equal to top for one flat colour
	vec4 extent; // x: the target's height in pixels, y: its width
	// x: 1 to show the image environment, y: its strength as a factor, z: the prefiltered
	// level it shows (the Blur), w: the exposure in stops.
	vec4 env;
	// From clip space into the panorama's own axes: the inverse projection, then the
	// view's turn into the panorama's.
	mat4 clip_to_env;
};

layout(location = 0) out vec4 out_color;

// A 4x4 ordered dither: the same offset at the same pixel every frame, so a partial
// redraw matches the full one bit for bit.
const float BAYER[16] = float[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);

void main() {
	// Under half an 8-bit step either way, so a gentle gradient shows no bands.
	ivec2 p = ivec2(gl_FragCoord.xy) & 3;
	float dither = ((BAYER[p.y * 4 + p.x] + 0.5) / 16.0 - 0.5) / 255.0;
	if (env.x > 0.5) {
		// The pixel's ray from the near plane to the far one, which an orthographic view
		// points the same way everywhere (one colour), and its colour in the panorama.
		vec2 ndc = vec2(2.0 * gl_FragCoord.x / extent.y - 1.0, 1.0 - 2.0 * gl_FragCoord.y / extent.x);
		vec4 a = clip_to_env * vec4(ndc, 0.0, 1.0);
		vec4 b = clip_to_env * vec4(ndc, 1.0, 1.0);
		vec3 d = normalize(b.xyz / b.w - a.xyz / a.w);
		vec3 c = textureLod(environment_map, panorama_uv(d), env.z).rgb * env.y;
		out_color = vec4(display_color(c, env.w) + dither, 1.0);
		return;
	}
	if (top == bottom) {
		out_color = top;
		return;
	}
	// The pixel's row, from 0 at the top (SDL_GPU's framebuffer origin) to 1 at the bottom.
	float t = clamp(gl_FragCoord.y / extent.x, 0.0, 1.0);
	out_color = vec4(mix(top.rgb, bottom.rgb, t) + dither, mix(top.a, bottom.a, t));
}
