#version 450
// The studio render shown: the viewport image darkened by the ambient occlusion and the
// key light's shadow the gather samples have built up so far.
layout(set = 2, binding = 0) uniform sampler2D view_color;
layout(set = 2, binding = 1) uniform sampler2D accum;

layout(set = 3, binding = 0) uniform Composite_Uniforms {
	vec4 params; // x: ambient occlusion strength, y: shadow strength
};

layout(location = 0) out vec4 out_color;

void main() {
	ivec2 px = ivec2(gl_FragCoord.xy);
	vec4 color = texelFetch(view_color, px, 0);
	vec4 a = texelFetch(accum, px, 0);
	float ao = a.g > 0.0 ? a.r / a.g : 1.0;
	float lit = a.a > 0.0 ? a.b / a.a : 1.0;
	// Occlusion deepens toward crevices; a soft curve keeps open surfaces untouched.
	float shade = mix(1.0, ao * ao * (3.0 - 2.0 * ao), params.x) * mix(1.0, lit, params.y);
	out_color = vec4(color.rgb * shade, color.a);
}
