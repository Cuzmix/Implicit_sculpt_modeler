#version 450
// Glyphs and shapes take their coverage from the single-channel atlas (shapes sample its
// white corner); an image, such as the viewport, is drawn as it is, tinted by the colour.
// A filtered image drawn over a clear of nothing has its colour divided by its alpha:
// filtering averaged in the clear's black wherever it reached the edge.
layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(set = 2, binding = 0) uniform sampler2D tex;

layout(set = 3, binding = 0) uniform Ui_Fragment_Uniforms {
	vec4 params; // xy: what turns the coordinates into 0 to 1 (one over the atlas size, or 1); z: 1 for an image; w: 1 to take its colour out of its alpha
};

layout(location = 0) out vec4 out_color;

void main() {
	vec4 s = texture(tex, in_uv * params.xy);
	if (params.w > 0.5) s.rgb /= max(s.a, 1.0 / 255.0);
	out_color = params.z > 0.5 ? in_color * s : vec4(in_color.rgb, in_color.a * s.r);
}
